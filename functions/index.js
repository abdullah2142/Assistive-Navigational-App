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
const { learnedAdjustment, recordEvidenceMonth, isWithinWindow } = require("./lib/learned_baseline");
const {
  incidentId,
  validateIncident,
  isStale: isIncidentStale,
  evidenceMonthsFromIncidents,
  mergeEvidenceMonths,
} = require("./lib/thana_incident");
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
const { collectAdvisories } = require("./lib/news_ingestion");
const { warnThresholdFor, zonesWorthMentioning, riskKindOf } = require("./lib/risk_threshold");

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
 * Budget kill-switch: stops the paid APIs before the bill grows.
 *
 * ## What it kills, and what it deliberately does not
 *
 * The previous version detached the billing account, which is Google's own
 * reference pattern and far too blunt here. Against a $2 budget it would
 * take Firestore and Cloud Functions down with the paid APIs — bricking the
 * app for testers, requiring a manual re-link in the Console, and killing
 * this very function in the process.
 *
 * So it disables [KILL_SERVICES] instead. Every one of them has a free
 * fallback the app already uses when they fail:
 *
 *   speech            -> on-device recognizer (SttService falls through on a
 *                        stream error; see cloud_stt_service_native.dart)
 *   texttospeech      -> flutter_tts, the device voice
 *   geocoding/routes/places -> Nominatim, OSRM, Overpass (RoutingConfig)
 *
 * The result is an app that gets worse rather than one that stops. Firestore,
 * Auth and Functions keep running, so onboarding, the emergency contacts and
 * the guardian side are untouched.
 *
 * `maps-android-backend` is left enabled on purpose: map loads are free and
 * unlimited, so disabling it would blank the map for no saving at all.
 *
 * ## Why it fires at 90%, not 100%
 *
 * Cloud Billing cost data lags — typically hours, sometimes most of a day.
 * By the time a 100% alert arrives the real spend is already past the
 * budget. Firing at [KILL_AT_RATIO] leaves headroom for whatever was spent
 * but not yet reported. This still cannot guarantee a hard ceiling; the
 * per-API quotas are what bound the *rate*, and this bounds the tail.
 *
 * ## Re-enabling
 *
 * Nothing here ever re-enables a service. That is deliberate — an automatic
 * reset would let a runaway loop rediscover the same spend every month. To
 * bring them back after fixing the cause:
 *
 *   gcloud services enable speech.googleapis.com texttospeech.googleapis.com \
 *     geocoding-backend.googleapis.com routes.googleapis.com \
 *     places.googleapis.com --project=ant-assistive-nav
 *
 * ## Setup this depends on
 *
 *   1. The $2 budget must publish to `projects/ant-assistive-nav/topics/
 *      budget-alerts` (verified connected 2026-09-08, thresholds 50/90/100%).
 *   2. The runtime service account
 *      `514133180208-compute@developer.gserviceaccount.com` needs
 *      `roles/serviceusage.serviceUsageAdmin` **on the project**. Without it
 *      this runs on a breach and silently fails to disable anything — check
 *      Cloud Logging if that ever needs confirming.
 *
 * Note the budget covers this project only. The Gemini key is an AI Studio
 * key billing to a different project, so assistant usage is NOT capped by
 * this and needs its own budget there.
 */

/** Paid APIs to switch off. Each has a free fallback the app already uses. */
const KILL_SERVICES = [
  "speech.googleapis.com",
  "texttospeech.googleapis.com",
  "geocoding-backend.googleapis.com",
  "routes.googleapis.com",
  "places.googleapis.com",
];

/** Act at 90% of budget, to absorb the lag in reported cost. */
const KILL_AT_RATIO = 0.9;

exports.disableBillingOnBudgetExceeded = onMessagePublished(
  { topic: "budget-alerts" },
  async (event) => {
    const alert = event.data.message.json;
    if (!alert || typeof alert.costAmount !== "number" || typeof alert.budgetAmount !== "number") {
      console.log("Budget alert payload missing cost/budget amounts — ignoring.", alert);
      return;
    }

    const { costAmount, budgetAmount, currencyCode = "" } = alert;
    // A zero budget would make this ratio infinite or NaN; treat a missing or
    // zero budget as "act", since it cannot mean "spend freely".
    const ratio = budgetAmount > 0 ? costAmount / budgetAmount : 1;
    console.log(
      `Budget check: spent ${costAmount} of ${budgetAmount} ${currencyCode} ` +
      `(${Math.round(ratio * 100)}%)`,
    );

    if (ratio < KILL_AT_RATIO) {
      console.log(`Under ${Math.round(KILL_AT_RATIO * 100)}% — no action taken.`);
      return;
    }

    const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT;
    const auth = new google.auth.GoogleAuth({
      scopes: ["https://www.googleapis.com/auth/cloud-platform"],
    });
    const serviceusage = google.serviceusage({ version: "v1", auth: await auth.getClient() });

    const disabled = [];
    const failed = {};
    for (const service of KILL_SERVICES) {
      try {
        await serviceusage.services.disable({
          name: `projects/${projectId}/services/${service}`,
        });
        disabled.push(service);
      } catch (e) {
        // Keep going. Disabling four of five APIs is far better than
        // abandoning the whole attempt because one was already off.
        failed[service] = e && e.message ? e.message : String(e);
      }
    }

    console.log(
      `ACTION TAKEN at ${Math.round(ratio * 100)}% of ${budgetAmount} ${currencyCode}. ` +
      `Disabled: ${disabled.join(", ") || "none"}. ` +
      `Failed: ${JSON.stringify(failed)}`,
    );
    console.log(
      "The app now runs on its free fallbacks (on-device speech, device TTS, " +
      "OpenStreetMap routing). Re-enable with `gcloud services enable ...` " +
      "once the cause is understood.",
    );
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

  // Whether to *say* something, which is a different question from whether
  // to route around something — see `lib/risk_threshold.js`. The fixed
  // threshold above sits between the median and p75 of the night
  // distribution, so it calls a quarter of Dhaka dangerous after 8pm and
  // teaches users to ignore the warning. This is compared against the
  // city's own spread at this hour instead, with the old threshold kept as
  // a floor so the set of routes that warn is always a subset of the set
  // that warns today.
  //
  // `zones` rather than `hitZones`: the reference distribution is the whole
  // city, not the handful of thanas this particular route happens to cross.
  const warnThreshold = warnThresholdFor(zones, dhakaHour, cityTrendMultiplier);
  const warnZones = zonesWorthMentioning(evaluatedZones, warnThreshold);
  // A confirmed hazard always warrants saying something, whatever the
  // ambient crime distribution looks like: it is three independent people
  // reporting one specific obstruction, not a property of the
  // neighbourhood, and `hazardWeight` is on a 1-10 scale that a night-time
  // percentile would swallow whole.
  const shouldWarn = warnZones.length > 0 || blockingHazards.length > 0;

  return {
    safe: dangerousZones.length === 0 && blockingHazards.length === 0,
    riskScore,
    threshold,
    // Speech-facing, and deliberately separate from `safe`/`threshold`,
    // which still mean what they always did so route *selection* is
    // untouched by this.
    shouldWarn,
    warnThreshold,
    warnZones,
    riskKind: riskKindOf(warnZones, blockingHazards.length > 0),
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
/**
 * Records one confirmed crime incident attributed to a Dhaka thana.
 *
 * Deliberately cheap and deliberately unopinionated. The Worker's matcher
 * has already established the only two facts this stores — the story is
 * about crime, and it names exactly one Dhaka thana with no competing
 * location — and neither required a model call. Judging whether a
 * neighbourhood has *deteriorated* stays where it was, in
 * `recordThanaAdvisory`.
 *
 * Nothing here can move a score on its own. Incidents become evidence only
 * in bulk, via `thana_incident.js`'s monthly threshold, and evidence
 * reaches the score only through the learned baseline's slow, capped,
 * self-decaying adjustment.
 *
 * Idempotent by source URL, because every run re-reads the last three weeks
 * of articles and the same story appears in several feeds. Without that,
 * re-reading one mugging would manufacture an evidence month by itself.
 */
exports.recordThanaIncident = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  const nowMs = Date.now();
  let incident;
  try {
    incident = validateIncident(request.data || {}, nowMs);
  } catch (err) {
    throw new HttpsError("invalid-argument", err.message);
  }

  const db = getFirestore();
  const zone = await db.collection("crimeZones").doc(incident.thanaSlug).get();
  if (!zone.exists) {
    throw new HttpsError("invalid-argument", `Unknown thana: ${incident.thanaSlug}`);
  }

  const id = incidentId(incident.sourceUrl);
  const ref = db.collection("thanaIncidents").doc(id);
  const existing = await ref.get();
  if (existing.exists) {
    return { recorded: false, reason: "already recorded", id };
  }
  await ref.set(incident);
  return { recorded: true, id, period: incident.period };
});

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

    // Incidents outlive advisories by design — they are the long memory —
    // but not forever; anything past the baseline's own window can never be
    // counted again and is only taking up space.
    const incidentsSnap = await db.collection("thanaIncidents").get();
    const staleIncidents = incidentsSnap.docs.filter((doc) => isIncidentStale(doc.data(), nowMs));
    if (staleIncidents.length > 0) {
      const incidentBatch = db.batch();
      staleIncidents.forEach((doc) => incidentBatch.delete(doc.ref));
      await incidentBatch.commit();
    }

    const evidenceUpdates = await recordEvidenceMonths(db, rebuilt, nowMs);

    cachedHazardZones = null;
    cachedZones = null;
    console.log(
      `decayHazardZones: ${live.length} live reports -> ${rebuilt.length} zones; ` +
        `deleted ${expiredRefs.length} expired reports, ${staleAdvisories.length} expired advisories, ` +
        `${staleSignals.length} stale social signals, ${staleIncidents.length} aged-out incidents; ` +
        `${evidenceUpdates} thanas gained an evidence month.`,
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
  const [zonesSnap, advisoriesSnap, incidentsSnap] = await Promise.all([
    db.collection("crimeZones").get(),
    db.collection("thanaAdvisories").get(),
    db.collection("thanaIncidents").get(),
  ]);

  // Incidents grouped by thana, so a month that crossed the threshold can
  // be counted from when those articles were *published* rather than from
  // the day the third one happened to arrive.
  const incidentsByThana = new Map();
  for (const doc of incidentsSnap.docs) {
    const incident = doc.data();
    if (isIncidentStale(incident, nowMs)) continue;
    if (!incidentsByThana.has(incident.thanaSlug)) incidentsByThana.set(incident.thanaSlug, []);
    incidentsByThana.get(incident.thanaSlug).push(incident);
  }

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
    const stored = doc.data().evidenceMonths;

    // The original path: an advisory or a confirmed crowdsourced crime
    // hazard marks *this* month, the month we observed it.
    const fromToday = recordEvidenceMonth(
      stored,
      {
        hasNewsAdvisory: newsAdvisoryThanas.has(doc.id),
        hasConfirmedCrimeReports: crimeThanas.has(doc.id),
      },
      nowMs,
    );

    // The ledger path: months in which enough separate incidents were
    // reported. This is the half that actually has data — advisories
    // require a model to see a pattern in one article, which measured at
    // zero over the entire life of the collector.
    const fromIncidents = evidenceMonthsFromIncidents(incidentsByThana.get(doc.id), nowMs);

    const merged = mergeEvidenceMonths(fromToday || stored, fromIncidents, isWithinWindow, nowMs);
    const next = merged || fromToday;
    if (!next) continue;
    batch.update(doc.ref, { evidenceMonths: next });
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
 * the rolling multiplier.
 *
 * Split out from `ingestCrimeReport` when Cloud Functions could not reach the
 * source at all, so the fetch could run from a network that could while the
 * *recording* stayed a reliable callable endpoint. **That constraint is gone:**
 * re-probed from inside a deployed function on 2026-09-16, `dmp.gov.bd`
 * answers in ~260ms and `police.gov.bd` still times out, so ingestion moved
 * back to DMP and runs end to end on the schedule again (see
 * `lib/crime_report_ingestion.js`).
 *
 * This stays split anyway. The wall was real once and the site can put one
 * back; keeping a callable write path means a month can always be recorded by
 * hand from wherever has access, without redeploying anything.
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
  // The 12th, because DMP publishes the previous month partway through this
  // one — August 2026 appeared on 9 September. Running on the 1st would
  // reliably find nothing new and record the month before it.
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
      // Left as a log rather than a retry or an alert: the multiplier keeps
      // its last successful value, every route still scores, and the next
      // month's run tries again. A failure here degrades currency, not safety.
      console.error("scrapeDmpCrimeReports: ingestion failed — DMP's page structure or upload naming may have " +
        "changed, the extraction may have been refused by its own validation, or the site may be walled off " +
        "again. cityTrend keeps its last successful value.", err);
    }
  },
);

/**
 * Reads Bangladeshi news for crime reporting that names a Dhaka thana, and
 * records what it finds as advisories.
 *
 * This is the caller `recordThanaAdvisory` never had. The advisory and
 * learned-baseline layers were built, deployed, and then fed nothing — the
 * hourly decay job has been reporting "0 thanas gained an evidence month"
 * since the day it shipped. It is also the only per-neighbourhood signal
 * available at all: DMP's monthly table is citywide totals, and no public
 * source publishes crime by Dhaka thana.
 *
 * Six-hourly rather than hourly. These outlets publish a handful of relevant
 * stories a day between them, an advisory lives 60 days, and the thing this
 * feeds counts *months* with evidence — nothing downstream can tell the
 * difference between polling four times a day and twenty-four, so the quieter
 * schedule is free.
 *
 * Writes through the same validation every other path uses rather than
 * touching Firestore directly: `validateAdvisory` enforces provenance, and an
 * advisory naming a thana with no `crimeZones` document is refused outright.
 * A pipeline that could bypass those checks would be the one place in this
 * system where an unaudited claim about a real neighbourhood could get in.
 */
exports.ingestCrimeNews = onSchedule(
  { schedule: "every 6 hours", timeZone: "Asia/Dhaka", timeoutSeconds: 300 },
  async () => {
    const { advisories, errors } = await collectAdvisories();
    for (const error of errors) {
      // Logged, never thrown: one outlet going down or putting up a bot wall
      // must not stop the others being read.
      console.warn(`ingestCrimeNews: source unavailable — ${error}`);
    }
    if (advisories.length === 0) {
      console.log(`ingestCrimeNews: nothing admissible this run (${errors.length} source errors).`);
      return;
    }

    const db = getFirestore();
    let recorded = 0;
    let skipped = 0;
    for (const advisory of advisories) {
      const problem = validateAdvisory(advisory);
      if (problem) {
        console.warn(`ingestCrimeNews: refused an advisory — ${problem}`);
        skipped++;
        continue;
      }
      const zone = await db.collection("crimeZones").doc(advisory.thanaSlug).get();
      if (!zone.exists) {
        console.warn(`ingestCrimeNews: no crimeZones document for "${advisory.thanaSlug}" — skipping.`);
        skipped++;
        continue;
      }
      // Keyed on the source URL, so the same story seen in two runs is one
      // advisory that gets its expiry refreshed, not two pieces of evidence.
      const id = Buffer.from(advisory.sourceUrl).toString("base64url").slice(0, 200);
      await db.collection("thanaAdvisories").doc(id).set({
        thanaSlug: advisory.thanaSlug,
        severity: advisory.severity,
        sourceTier: advisory.sourceTier,
        sourceUrl: advisory.sourceUrl,
        sourceTitle: advisory.sourceTitle,
        publishedAt: advisory.publishedAt,
        // An ISO string, matching `recordThanaAdvisory` exactly — the decay
        // job reads this field and a server timestamp is a different type.
        // Two write paths into one collection have to agree on the shape.
        recordedAt: new Date().toISOString(),
      }, { merge: true });
      recorded++;
    }
    console.log(`ingestCrimeNews: ${recorded} advisories recorded, ${skipped} skipped, ` +
      `${errors.length} source errors.`);
  },
);
