#!/usr/bin/env node
/**
 * Walks DMP's published archive and records every monthly citywide crime
 * table that has never been ingested.
 *
 *     GEMINI_API_KEY=... node scripts/backfill_city_trend.js --dry-run
 *     GEMINI_API_KEY=... node scripts/backfill_city_trend.js
 *
 * ## The gap this closes, and why it is not cosmetic
 *
 * `updateCityTrendMultiplier` takes the **four newest periods** in
 * `cityTrend` and divides the latest by the average of the prior three. It
 * has no concept of the months *between* them. So a hole in the series does
 * not produce a gap — it produces a confident comparison across the hole.
 *
 * Measured live on 2026-09-21: `cityTrend` held 66 months ending 2025-05,
 * plus a single 2026-07. The multiplier was therefore July 2026 (170
 * pedestrian-relevant) over the average of March–May **2025** (~239), giving
 * 0.71 — the clamp floor — and every route score in Dhaka had been
 * multiplied by 0.71 since 2026-09-03. Nothing was broken, nothing logged,
 * and the number was wrong by a year.
 *
 * `scrapeDmpCrimeReports` cannot fix that: it fires on the 12th and reads
 * exactly one month, the newest. Months published before it existed, and
 * months it missed while `dmp.gov.bd` was behind its bot wall, were never
 * going to be read by anything. This reads them.
 *
 * ## What it will and will not attempt
 *
 * Only months from `EARLIEST_CRIME_TABLE_PERIOD` (2024-01). Earlier pages
 * carry arms, stolen-vehicle and narcotics *recovery* tables and no crime
 * table at all — verified by eye, see that constant. Attempting them would
 * spend a Gemini call per month to be correctly refused.
 *
 * Months already in `cityTrend` are skipped, read over the Firestore REST
 * API with the same throwaway token used to write. That is the difference
 * between a re-run costing nothing and costing a model call per month.
 * `--force` re-reads them anyway, for when a prompt change should be applied
 * to history.
 *
 * ## Re-runnable on purpose
 *
 * `recordCityCrimeMonth` writes `cityTrend/{period}` with `set`, so a month
 * recorded twice is overwritten, not duplicated. Months are recorded oldest
 * first so that the last write — and therefore the last
 * `updateCityTrendMultiplier` recompute — is the newest month, which is the
 * one the multiplier is anchored on.
 *
 * ## Expect the multiplier to move, and expect it to move up
 *
 * Closing a hole that was suppressing the multiplier will raise it, and
 * every route score with it. That is the correction working, not a
 * regression — but it lands on whoever is holding the app at the time, so
 * the final line prints the before and after rather than leaving it to be
 * discovered.
 */

const {
  EARLIEST_CRIME_TABLE_PERIOD,
  listCrimeTableMonths,
  fetchAndExtractMonth,
} = require("../lib/crime_report_ingestion");

const FIREBASE_WEB_API_KEY = "AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg";
const PROJECT_ID = "ant-assistive-nav";
const RECORD_FN_URL = `https://us-central1-${PROJECT_ID}.cloudfunctions.net/recordCityCrimeMonth`;
const FIRESTORE_URL = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

/** Between months, so the archive does not see a burst. */
const SPACING_MS = 2000;

async function signInAnonymously() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_WEB_API_KEY}`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ returnSecureToken: true }) },
  );
  const json = await res.json();
  if (!json.idToken) throw new Error(`Anonymous sign-in failed: ${JSON.stringify(json)}`);
  return { idToken: json.idToken, localId: json.localId };
}

async function deleteAccount(idToken) {
  try {
    await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${FIREBASE_WEB_API_KEY}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ idToken }),
    });
  } catch {
    // A throwaway account left behind is untidy, not harmful — never let it
    // fail a run that has already recorded its months.
  }
}

/**
 * The periods `cityTrend` already holds.
 *
 * Paged, because the point of this script is that the collection should end
 * up with two years in it, and a single unpaged read would quietly stop at
 * whatever the default page size happens to be and re-ingest the rest.
 */
async function existingPeriods(idToken) {
  const periods = new Set();
  let pageToken = "";
  do {
    const url = `${FIRESTORE_URL}/cityTrend?pageSize=300${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ""}`;
    const res = await fetch(url, { headers: { Authorization: `Bearer ${idToken}` } });
    if (!res.ok) throw new Error(`Reading cityTrend returned HTTP ${res.status}`);
    const body = await res.json();
    for (const doc of body.documents || []) periods.add(doc.name.split("/").pop());
    pageToken = body.nextPageToken || "";
  } while (pageToken);
  return periods;
}

/** The live citywide multiplier, so the run can report what it changed. */
async function readMultiplier(idToken) {
  const res = await fetch(`${FIRESTORE_URL}/meta/cityTrendMultiplier`, {
    headers: { Authorization: `Bearer ${idToken}` },
  });
  if (!res.ok) return null;
  const f = (await res.json()).fields || {};
  const m = f.multiplier;
  if (!m) return null;
  return Number(m.doubleValue ?? m.integerValue);
}

async function recordMonth(idToken, row) {
  const res = await fetch(RECORD_FN_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${idToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ data: row }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.error) throw new Error(JSON.stringify(body.error || body).slice(0, 300));
  return body.result || body;
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");
  const force = process.argv.includes("--force");
  const geminiApiKey = process.env.GEMINI_API_KEY;
  if (!geminiApiKey && !dryRun) {
    console.error("GEMINI_API_KEY is not set. Reading a scan needs it; --dry-run does not.");
    process.exitCode = 1;
    return;
  }

  console.log(`Listing DMP months from ${EARLIEST_CRIME_TABLE_PERIOD} onwards...`);
  const months = await listCrimeTableMonths();
  console.log(`${months.length} month pages published: ${months.map((m) => m.period).join(", ")}\n`);

  const { idToken, localId } = await signInAnonymously();
  try {
    const already = await existingPeriods(idToken);
    const multiplierBefore = await readMultiplier(idToken);
    const sorted = [...already].sort();
    console.log(`cityTrend already holds ${already.size} month${already.size === 1 ? "" : "s"}`
      + `${already.size ? `, ${sorted[0]} to ${sorted[sorted.length - 1]}` : ""}`);
    console.log(`citywide multiplier is currently ${multiplierBefore ?? "unset"}`);

    // The hole is the whole problem, so name it rather than leaving it to be
    // inferred from a list of 66 periods.
    const missing = months.filter((m) => !already.has(m.period)).map((m) => m.period);
    console.log(`\n${missing.length} published month${missing.length === 1 ? "" : "s"} missing`
      + `${missing.length ? `: ${missing.join(", ")}` : ""}`);

    const todo = force ? months : months.filter((m) => !already.has(m.period));
    if (todo.length === 0) {
      console.log("\nNothing missing. The archive is fully ingested.");
      return;
    }

    if (dryRun) {
      console.log(`\n--dry-run: would read ${todo.length} scan(s) and record them. Nothing was read or written.`);
      console.log("Recording these will RAISE the citywide multiplier and therefore every route");
      console.log("score in Dhaka. That is the correction, but it lands on live testers.");
      return;
    }

    let recorded = 0;
    const refused = [];
    for (const month of todo) {
      try {
        const row = await fetchAndExtractMonth(month, geminiApiKey);
        const result = await recordMonth(idToken, row);
        const n = result.pedestrianRelevantIncidents ?? "?";
        console.log(`  ${month.period}  recorded — ${n} pedestrian-relevant, ${row.totalCasesDMP} total cases`);
        recorded++;
      } catch (e) {
        // Counted and continued: one unreadable month must not abandon two
        // years of archive. The message says which kind of failure it was —
        // a missing crime table reads differently from a misread column.
        console.warn(`  ${month.period}  skipped — ${e.message}`);
        refused.push(month.period);
      }
      await new Promise((r) => setTimeout(r, SPACING_MS));
    }

    console.log(`\nRecorded ${recorded} month${recorded === 1 ? "" : "s"}`
      + `${refused.length ? `, skipped ${refused.length}: ${refused.join(", ")}` : ""}.`);
    if (recorded > 0) {
      const multiplierAfter = await readMultiplier(idToken);
      console.log(`citywide multiplier ${multiplierBefore ?? "unset"} -> ${multiplierAfter ?? "unset"}`);
      if (multiplierBefore && multiplierAfter) {
        const pct = Math.round((multiplierAfter / multiplierBefore - 1) * 100);
        console.log(`every route score in Dhaka just moved by ${pct >= 0 ? "+" : ""}${pct}%.`);
      }
    }
  } finally {
    await deleteAccount(idToken);
    console.log(`Cleaned up throwaway auth account ${localId}.`);
  }
}

main().catch((err) => {
  console.error("backfill_city_trend failed:", err);
  process.exitCode = 1;
});
