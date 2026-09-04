const { onDocumentWritten } = require("firebase-functions/v2/firestore");
const { onMessagePublished } = require("firebase-functions/v2/pubsub");
const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore } = require("firebase-admin/firestore");
const { google } = require("googleapis");
const {
  THANA_CRIME_SEED,
  densityToScore,
  isNotoriousHotspot,
  isHotspotZone,
} = require("./data/dhaka_thana_crime_seed");
const thanaGeometry = require("./data/dhaka_thana_geometry.json");
const { decodePolyline, zonesOnRoute, toFirestoreGeometry } = require("./lib/geo");
const { temporalMultiplier } = require("./lib/temporal_weighting");
const {
  validateAdvisory,
  advisoryMultiplier,
  advisoryImpliesHotspot,
  strongestAdvisory,
  DEFAULT_TTL_MS,
} = require("./lib/thana_advisory");
const {
  validateSignal,
  deriveAdvisory,
  CORROBORATION_WINDOW_MS,
} = require("./lib/social_signal");
const { learnedAdjustment, recordEvidenceMonth } = require("./lib/learned_baseline");
const {
  buildZones,
  belongsToZone,
  evaluateZone,
  flagFor,
  hazardWeight,
  haversineMeters,
  FLAG_YELLOW,
  FLAG_RED,
} = require("./lib/hazard_clustering");
const { isExpired, ttlMsFor } = require("./lib/hazard_decay");
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
        // Derived, not hand-listed — see `isNotoriousHotspot`. Kept
        // alongside `categoryHint` rather than replacing it: Paltan is a
        // commercial core *and* an outlier, and collapsing the two would
        // throw away the daytime-footfall signal the temporal multiplier
        // needs.
        notoriousHotspot: isNotoriousHotspot(entry),
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
  const [zones, cityTrendMultiplier, hazardZones, advisories] = await Promise.all([
    loadZones(),
    loadCityTrendMultiplier(),
    loadHazardZones(),
    loadThanaAdvisories(),
  ]);
  const hitZones = zonesOnRoute(routePoints, zones);

  // Bangladesh Standard Time is a fixed UTC+6 offset (no DST) — computed
  // directly rather than trusting the function runtime's local timezone.
  const atMs = typeof timestampMs === "number" ? timestampMs : Date.now();
  const dhakaHour = new Date(atMs + 6 * 60 * 60 * 1000).getUTCHours();

  const threshold = 7;
  const evaluatedZones = hitZones.map((zone) => {
    // Derived from the stored document, not from a persisted flag — so
    // this works against zones seeded before the hotspot rule existed,
    // with no re-seed required. See `isHotspotZone`.
    //
    // A current, sourced advisory can also promote a thana to hotspot
    // behaviour: that is how a neighbourhood which has genuinely
    // deteriorated since 2009 (Mohammadpur being the standing example)
    // becomes visible to routing at all, given the base table cannot know.
    const advisory = strongestAdvisory(advisories[zone.id] || [], atMs);
    const advisoryFactor = advisoryMultiplier(advisory, atMs);
    // The slow half: months in which this thana had independent evidence,
    // accumulated by the hourly sweep. This is what stops a neighbourhood
    // reverting to its 2009 score the moment a news advisory expires.
    const learnedFactor = learnedAdjustment(zone.evidenceMonths, atMs);
    const hotspot = isHotspotZone(zone) || advisoryImpliesHotspot(advisory, atMs);
    const timeMultiplier = temporalMultiplier(zone.categoryHint, dhakaHour, { isHotspot: hotspot });
    return {
      thanaName: zone.thanaName,
      baseCrimeScore: zone.baseCrimeScore,
      notoriousHotspot: hotspot,
      temporalMultiplier: timeMultiplier,
      cityTrendMultiplier,
      advisoryMultiplier: advisoryFactor,
      learnedMultiplier: learnedFactor,
      evidenceMonths: (zone.evidenceMonths || []).length,
      // Returned so the provenance of any elevated score is inspectable
      // from the client, not just from the server logs — an advisory that
      // cannot be traced back to its source should not be able to change
      // what the app tells a user about a real neighbourhood.
      advisory: advisory
        ? {
            severity: advisory.severity,
            sourceTitle: advisory.sourceTitle,
            sourceUrl: advisory.sourceUrl,
            publishedAt: advisory.publishedAt,
          }
        : null,
      effectiveScore:
        Math.round(
          zone.baseCrimeScore * timeMultiplier * cityTrendMultiplier * advisoryFactor * learnedFactor * 10,
        ) / 10,
      dataSource: zone.dataSource,
    };
  });

  // $w_2$ — crowdsourced terrain/hazard pins the route actually passes.
  // Scored on the same 1-10 scale as $w_1$ against the same threshold, so
  // one comparison covers both: a confirmed (Red Flag) hazard is enough on
  // its own to make a route unsafe, an unconfirmed (Yellow Flag) one is
  // returned as a warning the client speaks without rerouting anybody.
  const hitHazards = hazardsOnRoute(routePoints, hazardZones);
  const blockingHazards = hitHazards.filter((h) => h.hazardWeight > threshold);
  const hazardWarnings = hitHazards.filter((h) => h.hazardWeight <= threshold);

  const crimeRisk = evaluatedZones.length > 0 ? Math.max(...evaluatedZones.map((z) => z.effectiveScore)) : 1;
  const hazardRisk = hitHazards.length > 0 ? Math.max(...hitHazards.map((h) => h.hazardWeight)) : 0;
  const riskScore = Math.max(crimeRisk, hazardRisk);
  const dangerousZones = evaluatedZones.filter((z) => z.effectiveScore > threshold);

  return {
    safe: dangerousZones.length === 0 && blockingHazards.length === 0,
    riskScore,
    threshold,
    evaluatedZones,
    dangerousZones,
    // Module 5 additions. Named separately from `dangerousZones` rather
    // than merged into it: the client says different things about a
    // *neighbourhood* being risky at this hour and about a specific
    // reported obstruction 20 metres ahead, and only the latter can be
    // marked resolved by the user.
    blockingHazards,
    hazardWarnings,
  };
});

/**
 * Current, sourced per-thana advisories — see `lib/thana_advisory.js` for
 * why these exist, why they require a citable source, and why they expire.
 *
 * Cached for a minute like hazard zones rather than ten like crime zones:
 * these change on a news cycle, not on a decade.
 */
let cachedAdvisories = null;
let cachedAdvisoriesAt = 0;

async function loadThanaAdvisories() {
  const now = Date.now();
  if (cachedAdvisories && now - cachedAdvisoriesAt < HAZARD_CACHE_TTL_MS) {
    return cachedAdvisories;
  }
  const snapshot = await getFirestore().collection("thanaAdvisories").get();
  const byThana = {};
  for (const doc of snapshot.docs) {
    const advisory = doc.data();
    (byThana[advisory.thanaSlug] ||= []).push(advisory);
  }
  cachedAdvisories = byThana;
  cachedAdvisoriesAt = now;
  return cachedAdvisories;
}

/**
 * Records one advisory, from a named news source.
 *
 * A callable rather than a scraper for the same reason `recordCityCrimeMonth`
 * is: **Cloud Functions in this project cannot reach Bangladeshi news
 * domains** — confirmed the hard way with police.gov.bd from two regions,
 * which is why the monthly ingest runs on a Cloudflare Worker and posts its
 * findings in. The extraction side belongs in that same Worker; this is the
 * contract it writes through.
 *
 * `validateAdvisory` is the gate, and it is deliberately strict: no source
 * URL, no publication date, no advisory. Nothing gets to raise a real
 * neighbourhood's danger score anonymously.
 */
exports.recordThanaAdvisory = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const advisory = request.data || {};
  const problem = validateAdvisory(advisory);
  if (problem) {
    throw new HttpsError("invalid-argument", problem);
  }

  const db = getFirestore();
  const zone = await db.collection("crimeZones").doc(advisory.thanaSlug).get();
  if (!zone.exists) {
    // Refusing an unknown thana rather than storing it: an advisory that
    // matches no zone silently does nothing forever, which looks exactly
    // like a working pipeline.
    throw new HttpsError("not-found", `No crimeZones document for "${advisory.thanaSlug}".`);
  }

  // Keyed by source URL so re-ingesting the same article refreshes it
  // instead of stacking duplicates that would each count separately.
  const id = Buffer.from(advisory.sourceUrl).toString("base64url").slice(0, 200);
  await db.collection("thanaAdvisories").doc(id).set(
    {
      thanaSlug: advisory.thanaSlug,
      severity: advisory.severity,
      summary: (advisory.summary || "").slice(0, 500),
      sourceUrl: advisory.sourceUrl,
      sourceTitle: advisory.sourceTitle,
      publishedAt: advisory.publishedAt,
      ttlMs: typeof advisory.ttlMs === "number" ? advisory.ttlMs : DEFAULT_TTL_MS,
      recordedAt: new Date().toISOString(),
      recordedBy: request.auth.uid,
    },
    { merge: true },
  );

  cachedAdvisories = null;
  console.log(`recordThanaAdvisory: ${advisory.severity} for ${advisory.thanaSlug} (${advisory.sourceUrl})`);
  return { ok: true, thanaSlug: advisory.thanaSlug, severity: advisory.severity };
});

/**
 * Records one scraped social-media post about a thana.
 *
 * A post on its own does **nothing** — it is stored as a signal and only
 * becomes an advisory once enough separate accounts have said something
 * about the same thana inside the corroboration window. See
 * `lib/social_signal.js` for why the threshold is counted in distinct
 * accounts rather than posts, and `lib/thana_advisory.js` for why the
 * resulting advisory is capped and short-lived.
 *
 * Like `recordThanaAdvisory` and `recordCityCrimeMonth`, this is a
 * callable rather than a scraper: Cloud Functions in this project cannot
 * reach the sites in question, so collection runs on the Cloudflare Worker
 * and posts its findings in through this contract.
 */
exports.recordSocialSignal = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const signal = request.data || {};
  const problem = validateSignal(signal);
  if (problem) {
    throw new HttpsError("invalid-argument", problem);
  }

  const db = getFirestore();
  const zone = await db.collection("crimeZones").doc(signal.thanaSlug).get();
  if (!zone.exists) {
    throw new HttpsError("not-found", `No crimeZones document for "${signal.thanaSlug}".`);
  }

  // Keyed by post URL, so re-scraping the same post cannot inflate the
  // count — the corroboration threshold is only meaningful if one post
  // counts once.
  const id = Buffer.from(signal.postUrl).toString("base64url").slice(0, 200);
  await db.collection("socialSignals").doc(id).set(
    {
      thanaSlug: signal.thanaSlug,
      authorHandle: signal.authorHandle,
      postUrl: signal.postUrl,
      postedAt: signal.postedAt,
      excerpt: (signal.excerpt || "").slice(0, 300),
      platform: signal.platform || "unknown",
      recordedAt: new Date().toISOString(),
    },
    { merge: true },
  );

  // Re-derive this thana's social advisory from everything currently live.
  const signalsSnap = await db
    .collection("socialSignals")
    .where("thanaSlug", "==", signal.thanaSlug)
    .get();
  const nowMs = Date.now();
  const derived = deriveAdvisory(signal.thanaSlug, signalsSnap.docs.map((d) => d.data()), nowMs);

  const advisoryRef = db.collection("thanaAdvisories").doc(`social-${signal.thanaSlug}`);
  if (derived) {
    await advisoryRef.set({ ...derived, recordedAt: new Date().toISOString() }, { merge: true });
  } else {
    // Below the threshold — make sure any previously derived advisory is
    // withdrawn rather than left standing on evidence that has since aged
    // out. A neighbourhood must be able to stop being flagged.
    await advisoryRef.delete().catch(() => {});
  }

  cachedAdvisories = null;
  return {
    ok: true,
    corroborated: derived != null,
    corroboratingAuthors: derived?.corroboratingAuthors ?? 0,
  };
});

/**
 * Module 5 — Community Crowdsourcing & Temporal Safety ($w_2$).
 *
 * `hazardReports/{id}` holds the raw pins users drop (written by the app's
 * Crowdsource Reporting Hub). `hazardZones/{id}` holds the aggregated view
 * routing actually reads: reports about the same hazard type within 10
 * metres of each other, collapsed into one document carrying a flag level
 * (see `lib/hazard_clustering.js`) and a $w_2$ weight.
 *
 * Routing never reads `hazardReports` directly — see that module's doc
 * comment for why one person's word must not be able to close a road.
 */

let cachedHazardZones = null;
let cachedHazardZonesAt = 0;
// Deliberately much shorter than `ZONE_CACHE_TTL_MS`. Crime zones are a
// static dataset refreshed monthly at most; hazard zones change the moment
// any user reports anything, and a report about the road someone is walking
// down right now is worth very little if it takes ten minutes to become
// visible.
const HAZARD_CACHE_TTL_MS = 60 * 1000;

async function loadHazardZones() {
  const now = Date.now();
  if (cachedHazardZones && now - cachedHazardZonesAt < HAZARD_CACHE_TTL_MS) {
    return cachedHazardZones;
  }
  const snapshot = await getFirestore().collection("hazardZones").where("flag", "in", [FLAG_YELLOW, FLAG_RED]).get();
  cachedHazardZones = snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
  cachedHazardZonesAt = now;
  return cachedHazardZones;
}

/**
 * How close a route has to pass to a hazard pin to count as hitting it.
 *
 * Wider than the 10 m clustering radius on purpose, and for a different
 * reason: clustering asks "are these two reports about the same thing?",
 * which wants to be tight, while this asks "will the person walking this
 * line encounter this?", which has to absorb GPS error on both the
 * reporter's phone and the route geometry. 25 m is roughly a Dhaka street
 * width plus consumer-GPS error, and errs toward warning about something
 * the user then walks safely past — the opposite error walks a blind user
 * into an open manhole.
 */
const HAZARD_ROUTE_RADIUS_M = 25;

function hazardsOnRoute(routePoints, hazardZones) {
  return hazardZones.filter((hazard) =>
    routePoints.some(
      (point) =>
        haversineMeters({ lat: point.lat, lng: point.lng }, { lat: hazard.lat, lng: hazard.lng }) <=
        HAZARD_ROUTE_RADIUS_M,
    ),
  );
}

/**
 * Folds one newly-submitted report into its zone, creating the zone if this
 * is the first report of its kind there.
 *
 * A create trigger rather than a scheduled recompute because the latency
 * matters: the user who just reported an open manhole is standing next to
 * it, and so is whoever the app routes past it in the next few minutes.
 * The hourly sweep (`decayHazardZones`) still re-derives everything from
 * scratch, so a trigger that misfires self-heals within the hour rather
 * than corrupting the aggregate permanently.
 */
exports.onHazardReportCreated = onDocumentCreated("hazardReports/{reportId}", async (event) => {
  const snap = event.data;
  if (!snap) return;
  const report = { id: snap.id, ...snap.data() };
  const createdAtMs = report.createdAt?.toMillis?.() ?? Date.now();
  if (typeof report.lat !== "number" || typeof report.lng !== "number") {
    console.log(`onHazardReportCreated: report ${snap.id} has no coordinates — nothing to cluster.`);
    return;
  }

  const db = getFirestore();
  // Only same-type zones can possibly match, and there are few of them —
  // filtering server-side keeps this from scanning the whole collection as
  // the city fills up with pins.
  const candidates = await db
    .collection("hazardZones")
    .where("category", "==", report.category)
    .where("subCategory", "==", report.subCategory)
    .get();

  const existing = candidates.docs.find((doc) => belongsToZone(report, doc.data()));
  const nowMs = Date.now();

  if (!existing) {
    const evaluation = evaluateZone([{ ...report, createdAtMs }], nowMs);
    await db.collection("hazardZones").add({
      lat: report.lat,
      lng: report.lng,
      category: report.category,
      subCategory: report.subCategory,
      reporterLastSeenMs: evaluation.reporterLastSeenMs,
      reporterUids: [report.reporterUid],
      reportCount: 1,
      flag: evaluation.flag,
      hazardWeight: hazardWeight(evaluation.flag),
      firstReportedAt: new Date(createdAtMs).toISOString(),
      lastReportedAt: new Date(createdAtMs).toISOString(),
      // Null for a structural block that never ages out — see
      // `lib/hazard_decay.js`.
      ttlMs: ttlMsFor(report.category, report.subCategory),
      resolvedAt: null,
    });
    return;
  }

  const zone = existing.data();
  // Rebuild the flag from the reporter set rather than incrementing a
  // counter: distinct *reporters inside the 24h window* is the anti-spam
  // rule, and a stored count that drifts from the actual set is exactly how
  // that rule gets quietly defeated. `flagFor` is the same function the
  // hourly rebuild uses, so the incremental and authoritative paths cannot
  // disagree about what "confirmed" means.
  const reporterLastSeenMs = { ...(zone.reporterLastSeenMs || {}) };
  reporterLastSeenMs[report.reporterUid] = Math.max(
    reporterLastSeenMs[report.reporterUid] || 0,
    createdAtMs,
  );
  const flag = flagFor(reporterLastSeenMs, nowMs);
  await existing.ref.update({
    reporterLastSeenMs,
    reporterUids: Object.keys(reporterLastSeenMs),
    reportCount: (zone.reportCount || 0) + 1,
    flag,
    hazardWeight: hazardWeight(flag),
    // Re-flagging refreshes a temporary block's clock — the module plan's
    // "decays after 7 days *unless re-flagged*".
    lastReportedAt: new Date(createdAtMs).toISOString(),
    // A zone someone has just reported again is, self-evidently, not
    // resolved any more.
    resolvedAt: null,
  });
});

/**
 * Step 3 — the hourly scrub. Re-derives every zone from the reports still
 * alive underneath it, so expired reports stop influencing routing and
 * zones with nothing left behind them disappear entirely.
 *
 * Rebuilding rather than patching in place is the point: it is the one
 * operation that can repair any drift the incremental trigger above
 * introduced, so the aggregate can be wrong for at most an hour rather
 * than indefinitely.
 */
exports.decayHazardZones = onSchedule(
  { schedule: "every 1 hours", timeZone: "Asia/Dhaka" },
  async () => {
    const db = getFirestore();
    const nowMs = Date.now();

    const reportsSnap = await db.collection("hazardReports").get();
    const live = [];
    const expiredRefs = [];
    for (const doc of reportsSnap.docs) {
      const data = doc.data();
      const report = {
        id: doc.id,
        ...data,
        createdAtMs: data.createdAt?.toMillis?.() ?? null,
        lastSeenAtMs: data.lastSeenAt?.toMillis?.() ?? null,
        resolvedAtMs: data.resolvedAt ? Date.parse(data.resolvedAt) : null,
      };
      if (isExpired(report, nowMs)) {
        expiredRefs.push(doc.ref);
      } else {
        live.push(report);
      }
    }

    const rebuilt = buildZones(live, nowMs);
    const zonesSnap = await db.collection("hazardZones").get();

    const batch = db.batch();
    // Zones are fully replaced, not diffed — there are few of them, and a
    // rebuild whose whole job is to be authoritative should not be trying
    // to preserve state it just recomputed.
    zonesSnap.docs.forEach((doc) => batch.delete(doc.ref));
    for (const zone of rebuilt) {
      batch.set(db.collection("hazardZones").doc(), {
        lat: zone.lat,
        lng: zone.lng,
        category: zone.category,
        subCategory: zone.subCategory,
        reporterLastSeenMs: zone.reporterLastSeenMs,
        reporterUids: zone.reporterUids,
        reportCount: zone.reportCount,
        flag: zone.flag,
        hazardWeight: zone.hazardWeight,
        lastReportedAt: new Date(zone.lastReportedAtMs).toISOString(),
        ttlMs: ttlMsFor(zone.category, zone.subCategory),
        resolvedAt: null,
      });
    }
    // Expired reports are deleted, not just ignored — otherwise the sweep
    // re-reads them forever and the collection grows without bound.
    expiredRefs.forEach((ref) => batch.delete(ref));
    await batch.commit();

    // Expired advisories go out on the same sweep — a stale "dangerous"
    // label on a real neighbourhood is the exact harm `thana_advisory.js`
    // is structured to avoid, so it should not depend on anyone noticing.
    const advisorySnap = await db.collection("thanaAdvisories").get();
    const staleAdvisories = advisorySnap.docs.filter((doc) => advisoryMultiplier(doc.data(), nowMs) <= 1);
    if (staleAdvisories.length > 0) {
      const advisoryBatch = db.batch();
      staleAdvisories.forEach((doc) => advisoryBatch.delete(doc.ref));
      await advisoryBatch.commit();
      cachedAdvisories = null;
    }

    // Social signals past the corroboration window can never contribute
    // again, so they are storage with no purpose.
    const signalsSnap = await db.collection("socialSignals").get();
    const staleSignals = signalsSnap.docs.filter((doc) => {
      const posted = Date.parse(doc.data().postedAt);
      return Number.isNaN(posted) || nowMs - posted > CORROBORATION_WINDOW_MS;
    });
    if (staleSignals.length > 0) {
      const signalBatch = db.batch();
      staleSignals.forEach((doc) => signalBatch.delete(doc.ref));
      await signalBatch.commit();
    }

    const evidenceUpdates = await recordEvidenceMonths(db, rebuilt, nowMs);

    cachedHazardZones = null;
    cachedZones = null;
    console.log(
      `decayHazardZones: ${live.length} live reports -> ${rebuilt.length} zones; ` +
        `deleted ${expiredRefs.length} expired reports, ${staleAdvisories.length} expired advisories, ` +
        `${staleSignals.length} stale social signals; ${evidenceUpdates} thanas gained an evidence month.`,
    );
  },
);

/**
 * Marks the current month as an evidence month for any thana that has one.
 *
 * Runs on the hourly sweep rather than on ingestion because the question is
 * "was there evidence *this month*", which is a property of the month, not
 * of any single article or report — and asking it repeatedly is harmless,
 * since a month is only ever recorded once.
 *
 * Deliberately reads only **news-tier** advisories and **confirmed** (Red
 * Flag) crowdsourced crime zones. Social chatter and single unconfirmed
 * reports can raise a temporary advisory; neither may edit a
 * neighbourhood's standing score.
 */
async function recordEvidenceMonths(db, hazardZones, nowMs) {
  const [zonesSnap, advisoriesSnap] = await Promise.all([
    db.collection("crimeZones").get(),
    db.collection("thanaAdvisories").get(),
  ]);

  const newsAdvisoryThanas = new Set(
    advisoriesSnap.docs
      .map((doc) => doc.data())
      .filter((a) => (a.sourceTier || "news") === "news" && advisoryMultiplier(a, nowMs) > 1)
      .map((a) => a.thanaSlug),
  );

  // Confirmed crime hazards, located inside whichever thana polygon
  // contains them. Only `category === "crime"` counts — a Red Flag pothole
  // says nothing about a neighbourhood's crime score.
  const confirmedCrime = hazardZones.filter((z) => z.flag === FLAG_RED && z.category === "crime");
  const zones = zonesSnap.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
  const crimeThanas = new Set();
  for (const hazard of confirmedCrime) {
    const hit = zonesOnRoute([{ lat: hazard.lat, lng: hazard.lng }], zones)[0];
    if (hit) crimeThanas.add(hit.id);
  }

  const batch = db.batch();
  let updates = 0;
  for (const doc of zonesSnap.docs) {
    const updated = recordEvidenceMonth(
      doc.data().evidenceMonths,
      {
        hasNewsAdvisory: newsAdvisoryThanas.has(doc.id),
        hasConfirmedCrimeReports: crimeThanas.has(doc.id),
      },
      nowMs,
    );
    if (!updated) continue;
    batch.update(doc.ref, { evidenceMonths: updated });
    updates += 1;
  }
  if (updates > 0) await batch.commit();
  return updates;
}

/**
 * Step 3's escape hatch: the only way a permanent structural block ever
 * leaves the map.
 *
 * Marks every report behind a zone resolved so the next sweep clears it.
 * Any signed-in user may resolve — the people who know a ramp has been
 * rebuilt are the people walking past it, and requiring the *original*
 * reporter would leave stale blocks standing forever once that person moves
 * away or stops using the app. A wrongly-resolved hazard is re-reported by
 * the next user who hits it and is back at Yellow immediately.
 */
exports.resolveHazardZone = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const { zoneId } = request.data || {};
  if (typeof zoneId !== "string" || zoneId.length === 0) {
    throw new HttpsError("invalid-argument", "A `zoneId` string is required.");
  }

  const db = getFirestore();
  const zoneRef = db.collection("hazardZones").doc(zoneId);
  const zoneSnap = await zoneRef.get();
  if (!zoneSnap.exists) {
    throw new HttpsError("not-found", "No such hazard zone.");
  }
  const zone = zoneSnap.data();

  const reportsSnap = await db
    .collection("hazardReports")
    .where("category", "==", zone.category)
    .where("subCategory", "==", zone.subCategory)
    .get();

  const resolvedAt = new Date().toISOString();
  const batch = db.batch();
  let resolved = 0;
  for (const doc of reportsSnap.docs) {
    if (!belongsToZone(doc.data(), zone)) continue;
    batch.update(doc.ref, { resolvedAt, resolvedBy: request.auth.uid });
    resolved += 1;
  }
  batch.update(zoneRef, { flag: "none", hazardWeight: 0, resolvedAt, resolvedBy: request.auth.uid });
  await batch.commit();

  cachedHazardZones = null;
  console.log(`resolveHazardZone: ${zoneId} resolved by ${request.auth.uid} (${resolved} reports).`);
  return { resolved };
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
