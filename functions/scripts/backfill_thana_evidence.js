/**
 * Rebuilds the per-thana crime baseline from dated, citable news reporting.
 *
 *     node scripts/backfill_thana_evidence.js --dry-run
 *     node scripts/backfill_thana_evidence.js
 *
 * ## Why this is a script and not a Cloud Function
 *
 * Google News RSS returns **HTTP 503 to Cloud Functions** — probed from a
 * deployed function in `us-central1` on 2026-09-16, consistently, across three
 * thanas. It answers an ordinary connection perfectly. Same shape as
 * `police.gov.bd` and `dmp.gov.bd`'s earlier bot wall: a datacenter-IP block,
 * not a bug to route around.
 *
 * So the fetching runs from wherever has access — a laptop, or GitHub Actions
 * — and the *recording* goes through `recordThanaIncident`, which validates
 * provenance and refuses a thana with no `crimeZones` document. Nothing here
 * writes to Firestore directly; there is no path in this system by which an
 * unaudited claim about a real neighbourhood can get in.
 *
 * ## Re-runnable on purpose
 *
 * `recordThanaIncident` keys on the source URL, and this picks the earliest
 * article of each month, so running it twice records the same set rather than
 * accumulating duplicates. Run it again whenever the corpus should be
 * refreshed; it is not a one-shot migration.
 */

const { collectBackfill } = require("../lib/news_backfill");
const { THANA_CRIME_SEED, densityToScore, isNotoriousHotspot } = require("../data/dhaka_thana_crime_seed");
const { temporalMultiplier } = require("../lib/temporal_weighting");
const { learnedAdjustment } = require("../lib/learned_baseline");

const FIREBASE_WEB_API_KEY = "AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg";
const PROJECT_ID = "ant-assistive-nav";
const RECORD_FN_URL = `https://us-central1-${PROJECT_ID}.cloudfunctions.net/recordThanaIncident`;
const FIRESTORE_URL = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

/** `checkRouteSafety`'s own threshold: above this, a route is passed over. */
const UNSAFE_ABOVE = 7;

/** Representative hours — mid-afternoon, and after the 8pm night threshold. */
const DAY_HOUR = 14;
const NIGHT_HOUR = 23;

/**
 * The live citywide multiplier, without which this projection is fiction.
 *
 * Read rather than assumed to be 1.0, and this is not a detail: measured on
 * 2026-09-21 it was **0.71**, because `cityTrend` had a 13-month hole and
 * `updateCityTrendMultiplier` compared across it. At 0.71 nothing this
 * backfill records crosses the threshold at all; at 1.0 three thanas do.
 * A projection that quietly assumed 1.0 would have reported a routing change
 * that would not happen, and a projection that assumed 0.71 would hide one
 * that happens the moment the trend is repaired.
 */
async function liveCityMultiplier() {
  let idToken = null;
  try {
    ({ idToken } = await signInAnonymously());
    const res = await fetch(`${FIRESTORE_URL}/meta/cityTrendMultiplier`, {
      headers: { Authorization: `Bearer ${idToken}` },
    });
    if (!res.ok) return null;
    const m = ((await res.json()).fields || {}).multiplier;
    return m ? Number(m.doubleValue ?? m.integerValue) : null;
  } catch {
    // Never fatal: the projection falls back to a stated 1.0 assumption, and
    // a failed read must not cost a dry run its forty-one queries.
    return null;
  } finally {
    if (idToken) await deleteAccount(idToken);
  }
}

/**
 * What recording this evidence would do to the scores that decide routing.
 *
 * ## Why the dry run does not stop at counting months
 *
 * "Mohammadpur has 11 evidence months" is not a decision anyone can make.
 * `learnedAdjustment` is capped at 1.6x deliberately — it corrects a stale
 * baseline rather than replacing it — so a thana with a low 2009 score can
 * accumulate a full year of evidence and still not cross the threshold that
 * actually changes a route. Whether that cap is right is a judgement about
 * this specific data, and it cannot be made without seeing the arithmetic.
 *
 * So this prints the before and after, at both hours that matter, and marks
 * the rows that cross [UNSAFE_ABOVE] — the only ones a walking user would
 * ever notice.
 *
 * Advisories are left out: they expire, and this is about what the baseline
 * believes once they have.
 */
function projectImpact(results, cityMultiplier) {
  const seedByName = new Map(THANA_CRIME_SEED.map((t) => [t.thanaName, t]));
  const nowMs = Date.now();
  const rows = [];

  for (const r of results) {
    const seed = seedByName.get(r.thana.name);
    if (!seed) continue;
    const base = densityToScore(seed.densityEstimate);
    const hotspot = isNotoriousHotspot(seed);
    const learned = learnedAdjustment(r.incidents.map((i) => i.period), nowMs);

    const at = (hour, factor) =>
      base * temporalMultiplier(seed.categoryHint, hour, { isHotspot: hotspot }) * cityMultiplier * factor;
    rows.push({
      name: r.thana.name,
      months: r.incidents.length,
      learned,
      dayBefore: at(DAY_HOUR, 1), dayAfter: at(DAY_HOUR, learned),
      nightBefore: at(NIGHT_HOUR, 1), nightAfter: at(NIGHT_HOUR, learned),
    });
  }
  return rows.sort((a, b) => b.months - a.months || b.nightAfter - a.nightAfter);
}

function printImpact(results, cityMultiplier, multiplierIsLive) {
  const rows = projectImpact(results, cityMultiplier).filter((r) => r.months > 0);
  const f = (n) => n.toFixed(1).padStart(5);
  const crossings = [];

  console.log("\nWhat recording this would do to route scoring");
  console.log(`(base x time-of-day x citywide ${cityMultiplier}${multiplierIsLive ? " (live)" : " (assumed)"} x learned;`
    + ` a route is passed over above ${UNSAFE_ABOVE})\n`);
  console.log(`  ${"thana".padEnd(20)} ${"mo".padStart(3)} ${"x".padStart(5)}  ${"day".padStart(11)}   ${"11pm".padStart(11)}`);
  for (const r of rows) {
    const crosses = r.nightBefore <= UNSAFE_ABOVE && r.nightAfter > UNSAFE_ABOVE;
    const alsoDay = r.dayBefore <= UNSAFE_ABOVE && r.dayAfter > UNSAFE_ABOVE;
    if (crosses || alsoDay) crossings.push(r.name);
    console.log(
      `  ${r.name.padEnd(20)} ${String(r.months).padStart(3)} ${r.learned.toFixed(2).padStart(5)}`
      + `  ${f(r.dayBefore)}->${f(r.dayAfter)}   ${f(r.nightBefore)}->${f(r.nightAfter)}`
      + `${crosses || alsoDay ? "   <-- newly passed over" : ""}`,
    );
  }

  // The honest headline. If nothing crosses, this backfill changes numbers
  // nobody walking will experience, and saying so plainly is more useful
  // than a table that looks like progress.
  console.log("");
  if (crossings.length === 0) {
    console.log(`No thana crosses ${UNSAFE_ABOVE} from this evidence, at either hour, `
      + `with the citywide multiplier at ${cityMultiplier}.`);
    console.log("Recording it is safe to do now; it changes stored scores, not routes.");
    if (cityMultiplier < 0.95) {
      console.log("");
      console.log(`NOTE: ${cityMultiplier} is well below neutral. Check cityTrend for a gap`);
      console.log("(scripts/check_data_health.js will say so) — repairing it raises every");
      console.log("score here, and some of these rows are close to the threshold.");
    }
  } else {
    console.log(`${crossings.length} thana(s) would newly be passed over: ${crossings.join(", ")}.`);
  }
}

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
    // fail a run that has already written its evidence.
  }
}

async function main() {
  const dryRun = process.argv.includes("--dry-run");

  console.log(`Searching ${41} thanas for crime reporting in the last 24 months...\n`);
  const { results, errors } = await collectBackfill({
    onProgress: (thana, count, error) => {
      const label = error ? `error: ${error}` : `${count} evidence month${count === 1 ? "" : "s"}`;
      console.log(`  ${thana.name.padEnd(20)} ${label}`);
    },
  });

  const incidents = results.flatMap((r) => r.incidents);
  const withEvidence = results.filter((r) => r.incidents.length > 0);

  console.log(`\n${incidents.length} incidents across ${withEvidence.length} thanas.`);
  if (errors.length) console.log(`${errors.length} thanas could not be searched: ${errors.join("; ")}`);

  // The three-month threshold is what `learned_baseline` needs before it moves
  // a score at all, so it is the number worth seeing before writing anything.
  const movable = results.filter((r) => r.incidents.length >= 3);
  console.log(`${movable.length} thanas have the 3+ months the learned baseline needs:`);
  for (const r of movable.sort((a, b) => b.incidents.length - a.incidents.length)) {
    console.log(`  ${r.thana.name.padEnd(20)} ${r.incidents.length}`);
  }

  const live = await liveCityMultiplier();
  printImpact(results, live ?? 1.0, live !== null);

  if (dryRun) {
    console.log("\n--dry-run: nothing was recorded.");
    return;
  }
  if (incidents.length === 0) {
    console.log("\nNothing to record.");
    return;
  }

  console.log(`\nSigning in anonymously to call recordThanaIncident...`);
  const { idToken, localId } = await signInAnonymously();
  let recorded = 0;
  let refused = 0;
  try {
    for (const incident of incidents) {
      const res = await fetch(RECORD_FN_URL, {
        method: "POST",
        headers: { Authorization: `Bearer ${idToken}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          data: {
            thanaSlug: incident.thanaSlug,
            sourceUrl: incident.sourceUrl,
            publishedAt: incident.publishedAt,
            headline: incident.headline,
          },
        }),
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok || body.error) {
        // Logged and counted rather than thrown: one refused incident must not
        // abandon a run that has forty thanas' worth of evidence behind it.
        console.warn(`  refused ${incident.thanaSlug} ${incident.period}: ${JSON.stringify(body.error || body)}`);
        refused++;
        continue;
      }
      recorded++;
    }
  } finally {
    await deleteAccount(idToken);
    console.log(`Cleaned up throwaway auth account ${localId}.`);
  }
  console.log(`\nRecorded ${recorded} incidents, ${refused} refused.`);
}

main().catch((err) => {
  console.error("backfill_thana_evidence failed:", err);
  process.exitCode = 1;
});
