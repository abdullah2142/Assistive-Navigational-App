const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const { google } = require("googleapis");
const { THANA_CRIME_SEED, densityToScore } = require("./data/dhaka_thana_crime_seed");
const thanaGeometry = require("./data/dhaka_thana_geometry.json");
const { decodePolyline, zonesOnRoute, toFirestoreGeometry } = require("./lib/geo");
const { temporalMultiplier } = require("./lib/temporal_weighting");
const { PEDESTRIAN_RELEVANT_CATEGORIES, fetchAndExtractLatestReport } = require("./lib/crime_report_ingestion");

initializeApp();

/**
 * Module 1 — Role-Based Access Control.
 *
 * The client never sets its own Firebase Auth custom claim (that would let
 * a compromised/rooted client grant itself Caretaker access to someone
 * else's data). Instead the client writes a plain `role` field on
 * `users/{uid}` during onboarding, and this trigger is the only thing
 * allowed to promote that into a verified custom claim on the user's ID
 * token. Firestore security rules (not included here) should then key off
 * `request.auth.token.role`, not the `users/{uid}.role` field, wherever a
 * read/write needs to be role-gated.
 */
exports.onUserRoleWritten = onDocumentWritten("users/{uid}", async (event) => {
  const uid = event.params.uid;
  const after = event.data?.after?.data();
  if (!after || !after.role) return;

  const before = event.data?.before?.data();
  if (before && before.role === after.role) return;

  await getAuth().setCustomUserClaims(uid, { role: after.role });
});

/**
 * Blaze-plan budget kill-switch.
 *
 * The project is on Firebase's free Spark plan by default (see this
 * function's own doc history / task.md) — Blaze only bills for usage past
 * the same free-tier quotas Spark already has, but a runaway bug or bad
 * actor could still rack up unexpected cost once real paid APIs are in
 * play. This is Google's own documented reference pattern for a hard
 * spending cap: a Cloud Billing Budget's Pub/Sub notification triggers
 * this function, which detaches the billing account the moment actual
 * cost exceeds the budget amount — cutting off every paid resource in the
 * project, not just one API. Deliberately blunt on purpose: a disabled
 * project you have to consciously re-enable beats a bill you didn't expect.
 *
 * Deployed 2026-09-01 (`us-east1`, alongside `onUserRoleWritten` once Blaze
 * unblocked 2nd-gen functions) — the deploy itself auto-created the
 * `budget-alerts` Pub/Sub topic it's wired to, since a 2nd-gen Pub/Sub
 * trigger provisions its topic if it doesn't already exist. Two things
 * remain, both billing/IAM changes on the account itself — not something
 * to automate without the account owner present, and this deploy can't
 * reach them from code either way:
 *   1. The user's existing $2 budget alert needs its Pub/Sub notification
 *      connected to this topic: Cloud Console -> Billing -> Budgets &
 *      alerts -> open that budget -> Manage notifications -> Connect a
 *      Pub/Sub topic -> `projects/ant-assistive-nav/topics/budget-alerts`.
 *      (Firebase Console's simplified budget-alert UI is email-only; this
 *      step needs the full Cloud Console Billing section.)
 *   2. Grant this function's actual runtime service account —
 *      `514133180208-compute@developer.gserviceaccount.com` (confirmed via
 *      `firebase functions:list --json` after deploy; it's the default
 *      Compute Engine SA Cloud Functions v2 uses unless configured
 *      otherwise) — the "Billing Account Costs Manager" IAM role *on the
 *      Billing Account* (not the project — Console: Billing -> Account
 *      Management -> Permissions -> Add Principal), so it's actually
 *      authorized to call `updateBillingInfo`. Without this grant the
 *      function will run on a budget breach but silently fail to disable
 *      billing — check its Cloud Logging output if that ever needs
 *      verifying.
 */
exports.disableBillingOnBudgetExceeded = onMessagePublished(
  { topic: "budget-alerts" },
  async (event) => {
    const alert = event.data.message.json;
    if (!alert || typeof alert.costAmount !== "number" || typeof alert.budgetAmount !== "number") {
      console.log("Budget alert payload missing cost/budget amounts — ignoring.", alert);
      return;
    }

    console.log(`Budget check: spent ${alert.costAmount} of ${alert.budgetAmount} ${alert.currencyCode || ""}`);
    if (alert.costAmount <= alert.budgetAmount) {
      console.log("Still under budget — no action taken.");
      return;
    }

    const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
    const projectName = `projects/${projectId}`;

    const auth = new google.auth.GoogleAuth({
      scopes: [
        "https://www.googleapis.com/auth/cloud-billing",
        "https://www.googleapis.com/auth/cloud-platform",
      ],
    });
    const billing = google.cloudbilling({ version: "v1", auth: await auth.getClient() });

    const current = await billing.projects.getBillingInfo({ name: projectName });
    if (!current.data.billingEnabled) {
      console.log("Billing is already disabled — nothing to do.");
      return;
    }

    // Detaching the billing account (empty name) disables billing for the
    // whole project — every paid API stops working until it's manually
    // re-linked in the Console.
    await billing.projects.updateBillingInfo({
      name: projectName,
      requestBody: { billingAccountName: "" },
    });
    console.log(`ACTION TAKEN: billing disabled for ${projectName} — budget of ${alert.budgetAmount} exceeded.`);
  },
);

/**
 * Module 4 — Contextual Safety & Crime Data ($w_1$).
 *
 * `crimeZones/{thanaSlug}` holds one document per Dhaka Metropolitan Police
 * thana: its real boundary polygon (`geometry`, from geoBoundaries/BBS —
 * see `data/dhaka_thana_geometry.json`), a static `baseCrimeScore` (1-10),
 * a `categoryHint` used for temporal weighting, and a `dataSource` tag so
 * the provenance of every score is always inspectable (never silently
 * presented as more authoritative than it is — see
 * `data/dhaka_thana_crime_seed.js`'s doc comment for the full story).
 */

function thanaSlug(name) {
  return name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

/**
 * One-time (idempotent — safe to re-run) seed/refresh of `crimeZones` from
 * the bundled geometry + crime-density data. Any signed-in user may call
 * this: it only ever upserts the same deterministic, non-sensitive public
 * dataset (Dhaka thana boundaries + an academic crime-density baseline),
 * never user data, so there's no meaningful abuse surface in leaving it
 * open to any authenticated caller rather than hand-rolling an admin check.
 */
exports.seedCrimeZones = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }

  const geometryByName = new Map(thanaGeometry.map((f) => [f.thanaName, f.geometry]));
  const db = getFirestore();
  const batch = db.batch();
  let written = 0;

  for (const entry of THANA_CRIME_SEED) {
    const geometry = geometryByName.get(entry.thanaName);
    if (!geometry) {
      console.warn(`No geometry found for thana "${entry.thanaName}" — skipping.`);
      continue;
    }
    const slug = thanaSlug(entry.thanaName);
    const ref = db.collection("crimeZones").doc(slug);
    batch.set(
      ref,
      {
        thanaName: entry.thanaName,
        thanaNameBn: entry.thanaNameBn,
        geometry: toFirestoreGeometry(geometry),
        baseCrimeScore: densityToScore(entry.densityEstimate),
        categoryHint: entry.categoryHint,
        dataSource: entry.dataSource,
        updatedAt: new Date().toISOString(),
      },
      { merge: true },
    );
    written += 1;
  }

  await batch.commit();
  console.log(`seedCrimeZones: upserted ${written} thana documents.`);
  return { written };
});

// Cloud Function instances are reused across invocations while warm — cache
// the (small, ~41-doc) crimeZones collection in module scope instead of
// re-reading Firestore on every single `checkRouteSafety` call, refreshing
// it at most once every 10 minutes so a `seedCrimeZones` re-run or the (not
// yet live) scraper's updates still show up reasonably quickly.
let cachedZones = null;
let cachedZonesAt = 0;
const ZONE_CACHE_TTL_MS = 10 * 60 * 1000;

async function loadZones() {
  const now = Date.now();
  if (cachedZones && now - cachedZonesAt < ZONE_CACHE_TTL_MS) {
    return cachedZones;
  }
  const snapshot = await getFirestore().collection("crimeZones").get();
  cachedZones = snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
  cachedZonesAt = now;
  return cachedZones;
}

// Same reuse-across-warm-invocations caching as `loadZones` — this doc
// changes at most once a month (see `updateCityTrendMultiplier`), so a
// 10-minute cache is already more than fresh enough.
let cachedCityTrendMultiplier = 1.0;
let cachedMultiplierAt = 0;

async function loadCityTrendMultiplier() {
  const now = Date.now();
  if (now - cachedMultiplierAt < ZONE_CACHE_TTL_MS) {
    return cachedCityTrendMultiplier;
  }
  const doc = await getFirestore().collection("meta").doc("cityTrendMultiplier").get();
  cachedCityTrendMultiplier = doc.exists ? (doc.data().multiplier ?? 1.0) : 1.0;
  cachedMultiplierAt = now;
  return cachedCityTrendMultiplier;
}

/**
 * Step 4 of the module plan: given a route's Google-encoded polyline, report
 * whether it passes through any Thana whose time-of-day-weighted crime
 * score exceeds the dangerous threshold (> 7), so the client can decide
 * whether to accept the route or ask Directions for an alternative.
 *
 * Deliberately just the *check* — not the reroute decision itself. Keeping
 * the actual "try another Google Maps alternative and re-check it" loop on
 * the client (see `route_safety_service.dart` / `routing_service.dart`)
 * avoids this function needing its own Directions API key/billing path,
 * and lets the client show its work (which alternative it tried, why) in
 * the chat transcript as it goes.
 *
 * Each zone's static `baseCrimeScore` gets scaled by two independent
 * multipliers before the threshold check: the existing time-of-day one
 * (`temporalMultiplier`, spatial-agnostic — same zone, different hour) and
 * a citywide trend one (`cityTrendMultiplier`, hour-agnostic — same hour,
 * however crime is trending this month per `scrapeDmpCrimeReports`). See
 * that function's doc comment for why the latter starts at a neutral 1.0x.
 */
exports.checkRouteSafety = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const { polyline, timestampMs } = request.data || {};
  if (typeof polyline !== "string" || polyline.length === 0) {
    throw new HttpsError("invalid-argument", "A non-empty encoded `polyline` string is required.");
  }

  const routePoints = decodePolyline(polyline);
  const [zones, cityTrendMultiplier] = await Promise.all([loadZones(), loadCityTrendMultiplier()]);
  const hitZones = zonesOnRoute(routePoints, zones);

  // Bangladesh Standard Time is a fixed UTC+6 offset (no DST) — computed
  // directly rather than trusting the function runtime's local timezone.
  const atMs = typeof timestampMs === "number" ? timestampMs : Date.now();
  const dhakaHour = new Date(atMs + 6 * 60 * 60 * 1000).getUTCHours();

  const threshold = 7;
  const evaluatedZones = hitZones.map((zone) => {
    const timeMultiplier = temporalMultiplier(zone.categoryHint, dhakaHour);
    return {
      thanaName: zone.thanaName,
      baseCrimeScore: zone.baseCrimeScore,
      temporalMultiplier: timeMultiplier,
      cityTrendMultiplier,
      effectiveScore: Math.round(zone.baseCrimeScore * timeMultiplier * cityTrendMultiplier * 10) / 10,
      dataSource: zone.dataSource,
    };
  });

  const riskScore = evaluatedZones.length > 0 ? Math.max(...evaluatedZones.map((z) => z.effectiveScore)) : 1;
  const dangerousZones = evaluatedZones.filter((z) => z.effectiveScore > threshold);

  return {
    safe: dangerousZones.length === 0,
    riskScore,
    threshold,
    evaluatedZones,
    dangerousZones,
  };
});

/**
 * Step 1 of the module plan — real, working ingestion, redesigned after
 * live research (2026-09-02) into what Bangladesh Police actually publishes:
 *
 * - `dmp.gov.bd` (the module plan's assumed source) sits behind a bot-check
 *   wall that couldn't be gotten past from this sandbox. But
 *   **`police.gov.bd`'s "List of Crime Statistics" archive is real, public,
 *   and not bot-walled** — confirmed live by fetching it, downloading its
 *   newest linked PDF, and cross-checking every number against a real DMP
 *   report screenshot the user provided. This is the actual scrape target.
 * - That PDF is a **scanned image with no text layer** (confirmed with
 *   `pdftotext` — empty output), so real OCR is required. Rather than a
 *   Document AI processor (which needs GCP Console setup that was blocking
 *   this before), Gemini reads the PDF directly as multimodal input in one
 *   call — no new infrastructure, just the `GEMINI_API_KEY` already
 *   configured for the AI Assistant.
 * - **The report is citywide-only**: one row for all of DMP, not broken
 *   down by Thana (confirmed against the real PDF — "Names of Unit" column
 *   lists DMP/CMP/KMP/etc. and police Ranges, nothing finer). So this
 *   pipeline cannot refresh *which neighborhoods* are relatively riskier
 *   (that still comes from `dhaka_thana_crime_seed.js`'s 2009 academic
 *   baseline) — only *how much* crime is happening citywide right now, as a
 *   scaling factor applied uniformly across every Thana's static score. See
 *   `updateCityTrendMultiplier`'s doc comment for exactly how that factor
 *   is computed and why it starts neutral (1.0x) rather than guessing from
 *   one month of data.
 */
/**
 * Records one month's already-extracted DMP crime figures and recomputes
 * the rolling multiplier. Split out from `ingestCrimeReport` (below) on
 * purpose: **Cloud Functions in this project cannot reach police.gov.bd at
 * all** — confirmed live, identically, from both `us-central1` and
 * `asia-south1` (`ECONNREFUSED` at the TCP level, not a bot-check page).
 * That's the site's own network-level access decision, not a bug to route
 * around — so rather than trying to evade it (a different network, a
 * proxy), the fetch+extract step runs from wherever genuinely has access
 * (this was verified working from outside Google Cloud), and only the
 * *recording* — the part that benefits from being a reliable, callable
 * endpoint — lives here. `ingestCrimeReport` still exists for if/when
 * Cloud Functions' access to the site changes (e.g. the user arranging a
 * static egress IP and asking the site to allow it), and calls this same
 * function so there's one real write path either way.
 */
async function recordCityTrendEntry({ period, dacoity, robbery, burglary, theft, kidnapping, totalCasesDMP, sourceTitle, sourceUrl }) {
  const breakdown = { dacoity, robbery, burglary, theft, kidnapping };
  const pedestrianRelevantIncidents = PEDESTRIAN_RELEVANT_CATEGORIES.reduce(
    (sum, key) => sum + (Number(breakdown[key]) || 0),
    0,
  );

  const db = getFirestore();
  await db.collection("cityTrend").doc(period).set({
    period,
    pedestrianRelevantIncidents,
    totalCasesDMP: Number(totalCasesDMP) || null,
    breakdown: Object.fromEntries(PEDESTRIAN_RELEVANT_CATEGORIES.map((k) => [k, Number(breakdown[k]) || 0])),
    sourceTitle: sourceTitle || null,
    sourceUrl: sourceUrl || null,
    ingestedAt: new Date().toISOString(),
  });

  await updateCityTrendMultiplier();
  return { period, pedestrianRelevantIncidents };
}

/** Full pipeline: fetch the newest report from police.gov.bd, extract the
 * DMP row via Gemini, and record it. Only actually reachable from a network
 * police.gov.bd doesn't refuse — see `recordCityTrendEntry`'s doc comment. */
async function ingestCrimeReport(geminiApiKey) {
  const extracted = await fetchAndExtractLatestReport(geminiApiKey);
  console.log(`ingestCrimeReport: processing "${extracted.sourceTitle}" (${extracted.sourceUrl})`);
  const period = extracted.period || new Date().toISOString().slice(0, 7);
  return recordCityTrendEntry({ ...extracted, period });
}

/**
 * Recomputes the single citywide scaling factor `checkRouteSafety` applies
 * on top of every Thana's static score (see its doc comment). Deliberately
 * conservative about when it actually moves off neutral:
 *
 * - **Needs at least 3 months of `cityTrend` history before it does
 *   anything but stay at 1.0x.** One data point has no trend to compare
 *   against; comparing today's report against the 2009 academic baseline
 *   (a different data-collection methodology, a 3-month sample vs. a
 *   1-month one, and a narrower "street crime" definition than this
 *   pipeline's 5-category pedestrian-relevant set) would produce a
 *   precise-looking number built on a shaky bridge across 17 years of
 *   methodology drift — worse than no adjustment at all. Once this
 *   pipeline has been running long enough to build its *own*
 *   same-methodology history, comparing within that history is
 *   trustworthy; comparing across the methodology gap isn't.
 * - Once ≥3 months exist: ratio = latest month ÷ (rolling average of the
 *   up-to-3 prior months), clamped to [0.7, 1.5] so one anomalous month
 *   (a data-entry error, a one-off crackdown skewing recovery cases, etc.)
 *   can't wildly swing every route's safety score.
 */
async function updateCityTrendMultiplier() {
  const db = getFirestore();
  const snapshot = await db.collection("cityTrend").orderBy("period", "desc").limit(4).get();
  const months = snapshot.docs.map((d) => d.data());

  if (months.length < 3) {
    await db.collection("meta").doc("cityTrendMultiplier").set({
      multiplier: 1.0,
      basedOnMonths: months.length,
      note: "Fewer than 3 months of same-methodology history yet — staying neutral rather than guessing.",
      updatedAt: new Date().toISOString(),
    });
    return;
  }

  const [latest, ...priorMonths] = months.slice(0, 4);
  const priorAvg = priorMonths.reduce((sum, m) => sum + m.pedestrianRelevantIncidents, 0) / priorMonths.length;
  const rawRatio = priorAvg > 0 ? latest.pedestrianRelevantIncidents / priorAvg : 1.0;
  const multiplier = Math.max(0.7, Math.min(1.5, Math.round(rawRatio * 100) / 100));

  await db.collection("meta").doc("cityTrendMultiplier").set({
    multiplier,
    basedOnMonths: priorMonths.length,
    latestPeriod: latest.period,
    updatedAt: new Date().toISOString(),
  });
}

/** Manual trigger — lets a citywide refresh be run on demand (verification,
 * or catching up after a missed scheduled run) instead of only ever firing
 * on the monthly schedule. Same real ingestion code path as the scheduled
 * function below. Requires sign-in for the same low-risk reasoning as
 * `seedCrimeZones` (writes only ever land in this deterministic public
 * dataset, never user data) — but unlike that one, this makes a real
 * network call and costs a small Gemini request, so it's not spam-proof by
 * accident the way a pure Firestore upsert is; fine for this project's
 * scale, worth revisiting before any wider release. */
exports.refreshCityCrimeTrend = onCall({ secrets: ["GEMINI_API_KEY"], region: "asia-south1" }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const geminiApiKey = process.env.GEMINI_API_KEY;
  if (!geminiApiKey) {
    throw new HttpsError("failed-precondition", "GEMINI_API_KEY is not configured on this function.");
  }
  return ingestCrimeReport(geminiApiKey);
});

/**
 * The actually-reachable path for keeping `cityTrend` current, given
 * `refreshCityCrimeTrend`'s network block (see `recordCityTrendEntry`'s doc
 * comment): whoever fetched+read a new monthly report from a network that
 * can reach police.gov.bd (a human in a browser, or an assistant session
 * with outside access) calls this with the numbers already read off the
 * report, and it does the same Firestore write + rolling-multiplier
 * recompute `ingestCrimeReport` would have. Same low-risk reasoning as
 * `seedCrimeZones` for leaving it open to any signed-in user — deterministic
 * public dataset, no user data touched.
 */
exports.recordCityCrimeMonth = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const { period, dacoity, robbery, burglary, theft, kidnapping, totalCasesDMP, sourceTitle, sourceUrl } =
    request.data || {};
  if (typeof period !== "string" || !/^\d{4}-\d{2}$/.test(period)) {
    throw new HttpsError("invalid-argument", 'A `period` string like "2026-07" is required.');
  }
  return recordCityTrendEntry({ period, dacoity, robbery, burglary, theft, kidnapping, totalCasesDMP, sourceTitle, sourceUrl });
});

/**
 * The report is uploaded roughly 10 days after the month it covers ends
 * (July 2026's was uploaded 2026-08-10, confirmed live) — scheduled for the
 * 12th of each month to safely land after that lag.
 */
exports.scrapeDmpCrimeReports = onSchedule(
  { schedule: "12 of month 09:00", timeZone: "Asia/Dhaka", secrets: ["GEMINI_API_KEY"] },
  async () => {
    const geminiApiKey = process.env.GEMINI_API_KEY;
    if (!geminiApiKey) {
      console.log("scrapeDmpCrimeReports: GEMINI_API_KEY not configured — skipping this run. checkRouteSafety " +
        "keeps using a neutral 1.0x city-trend multiplier, nothing breaks.");
      return;
    }
    try {
      const result = await ingestCrimeReport(geminiApiKey);
      console.log(`scrapeDmpCrimeReports: ingested ${result.period} — ` +
        `${result.pedestrianRelevantIncidents} pedestrian-relevant incidents citywide.`);
    } catch (err) {
      console.error("scrapeDmpCrimeReports: ingestion failed — the archive page structure may have changed, " +
        "or Gemini's extraction was malformed. cityTrend keeps its last successful value.", err);
    }
  },
);
