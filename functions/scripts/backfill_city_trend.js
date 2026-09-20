#!/usr/bin/env node
/**
 * Walks DMP's published archive and records every monthly citywide crime
 * table that has never been ingested.
 *
 *     GEMINI_API_KEY=... node scripts/backfill_city_trend.js --dry-run
 *     GEMINI_API_KEY=... node scripts/backfill_city_trend.js
 *
 * ## Why the trend was thin
 *
 * `scrapeDmpCrimeReports` fires on the 12th and reads exactly one month: the
 * newest. That is right for staying current and useless for history — every
 * month published before the scraper existed, and every month it missed
 * while `dmp.gov.bd` was behind its bot wall, was simply never read. The
 * citywide multiplier is computed from the last four months
 * (`updateCityTrendMultiplier`), so a thin collection means a multiplier
 * derived from almost nothing.
 *
 * The archive is still up. This reads it.
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
    console.log(`cityTrend already holds ${already.size} month${already.size === 1 ? "" : "s"}`
      + `${already.size ? `: ${[...already].sort().join(", ")}` : ""}\n`);

    const todo = force ? months : months.filter((m) => !already.has(m.period));
    if (todo.length === 0) {
      console.log("Nothing missing. The archive is fully ingested.");
      return;
    }
    console.log(`${todo.length} month${todo.length === 1 ? "" : "s"} to read: ${todo.map((m) => m.period).join(", ")}`);

    if (dryRun) {
      console.log("\n--dry-run: no scan was read and nothing was recorded.");
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
      console.log("cityTrendMultiplier was recomputed on the last write, from the four newest months.");
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
