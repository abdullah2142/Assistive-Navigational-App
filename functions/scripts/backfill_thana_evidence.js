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

const FIREBASE_WEB_API_KEY = "AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg";
const RECORD_FN_URL = "https://us-central1-ant-assistive-nav.cloudfunctions.net/recordThanaIncident";

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
