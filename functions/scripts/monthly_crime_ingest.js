#!/usr/bin/env node
/**
 * Run monthly by `.github/workflows/monthly-crime-report.yml` — the
 * fetch-and-record half of Module 4's crime-trend pipeline, from a network
 * that (unlike Google Cloud Functions — confirmed live, `ECONNREFUSED` from
 * both `us-central1` and `asia-south1`) can actually reach `police.gov.bd`.
 *
 * Uses `../lib/crime_report_ingestion.js` — the exact same fetch+extract
 * code the (currently network-blocked) `ingestCrimeReport` Cloud Function
 * would use if it could reach the site, so there's one real implementation
 * of "how to read a report," not two that could drift apart. This script's
 * own job is just the parts that only make sense outside a Cloud Function:
 * getting a short-lived auth token and calling the already-deployed
 * `recordCityCrimeMonth` over HTTPS.
 *
 * Requires `GEMINI_API_KEY` in the environment (set as a GitHub Actions
 * repository secret — Settings -> Secrets and variables -> Actions -> New
 * repository secret, name `GEMINI_API_KEY`). Everything else here is
 * either public by design (the Firebase Web API key — Firestore/Functions
 * security rules are the real access control, not this key's secrecy,
 * same key already shipped inside the Flutter app itself) or derived at
 * runtime.
 */

const { fetchAndExtractLatestReport } = require("../lib/crime_report_ingestion");

const FIREBASE_WEB_API_KEY = "AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg";
const RECORD_FN_URL = "https://us-central1-ant-assistive-nav.cloudfunctions.net/recordCityCrimeMonth";

async function signInAnonymously() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_WEB_API_KEY}`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ returnSecureToken: true }) },
  );
  if (!res.ok) throw new Error(`Anonymous sign-in failed: HTTP ${res.status}`);
  const json = await res.json();
  return { idToken: json.idToken, localId: json.localId };
}

async function deleteAccount(idToken) {
  // Best-effort cleanup — a leftover throwaway anonymous account with zero
  // permissions beyond what every signed-in user already has isn't a real
  // problem if this step ever fails, so it's not allowed to fail the run.
  try {
    await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${FIREBASE_WEB_API_KEY}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ idToken }),
    });
  } catch (err) {
    console.warn("Cleanup: failed to delete the throwaway auth account (non-fatal):", err.message);
  }
}

async function main() {
  const geminiApiKey = process.env.GEMINI_API_KEY;
  if (!geminiApiKey) {
    console.error("GEMINI_API_KEY is not set — add it as a GitHub Actions repository secret.");
    process.exitCode = 1;
    return;
  }

  console.log("Fetching the newest crime statistics report...");
  const extracted = await fetchAndExtractLatestReport(geminiApiKey);
  const period = extracted.period || new Date().toISOString().slice(0, 7);
  console.log(`Extracted "${extracted.sourceTitle}" -> period ${period}:`, {
    dacoity: extracted.dacoity,
    robbery: extracted.robbery,
    burglary: extracted.burglary,
    theft: extracted.theft,
    kidnapping: extracted.kidnapping,
    totalCasesDMP: extracted.totalCasesDMP,
  });

  console.log("Signing in anonymously to call recordCityCrimeMonth...");
  const { idToken, localId } = await signInAnonymously();

  try {
    const res = await fetch(RECORD_FN_URL, {
      method: "POST",
      headers: { Authorization: `Bearer ${idToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ data: { ...extracted, period } }),
    });
    const body = await res.json();
    if (!res.ok || body.error) {
      throw new Error(`recordCityCrimeMonth failed: ${JSON.stringify(body)}`);
    }
    console.log("Recorded successfully:", body.result);
  } finally {
    await deleteAccount(idToken);
    console.log(`Cleaned up throwaway auth account ${localId}.`);
  }
}

main().catch((err) => {
  console.error("monthly_crime_ingest failed:", err);
  process.exitCode = 1;
});
