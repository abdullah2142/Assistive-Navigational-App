/**
 * Crowdsourced hazard clustering and anti-spam flagging — Step 2 of
 * `05_module_plan_crowdsourcing.md`.
 *
 * Raw user reports land in the flat `hazardReports` collection (written by
 * the app's Crowdsource Reporting Hub). They are never consumed directly by
 * routing: one person's word is not enough to close a road for everybody,
 * and it is not enough to be *ignored* either. This module is the layer in
 * between — it groups reports that are plainly about the same thing and
 * decides how much the routing engine should believe them:
 *
 * - **Yellow Flag** — one report. The next user walking toward it is warned
 *   ("a user reported a broken road ahead") but is NOT rerouted.
 * - **Red Flag** — three *independent* reporters, same hazard type, within
 *   10 metres, inside a 24-hour window. Now it is treated as real: the
 *   $w_2$ score spikes and routing actively avoids the path.
 *
 * "Independent" is doing real work in that definition: the count is over
 * distinct reporter UIDs, not documents. One person tapping submit three
 * times — by accident, by impatience, or deliberately — must never be able
 * to close a road on their own, which is the entire point of an anti-spam
 * threshold.
 */

const CLUSTER_RADIUS_M = 10;
const RED_FLAG_MIN_REPORTERS = 3;
const RED_FLAG_WINDOW_MS = 24 * 60 * 60 * 1000;

const FLAG_NONE = "none";
const FLAG_YELLOW = "yellow";
const FLAG_RED = "red";

const EARTH_RADIUS_M = 6371008.8;

const toRadians = (deg) => (deg * Math.PI) / 180;

/**
 * Great-circle distance in metres. Used rather than a flat lat/lng delta
 * because the threshold here is 10 metres — at Dhaka's latitude one degree
 * of longitude is ~102 km against a degree of latitude's ~111 km, so
 * treating the two as interchangeable would skew a 10 m radius into a
 * lopsided ellipse.
 */
function haversineMeters(a, b) {
  const dLat = toRadians(b.lat - a.lat);
  const dLng = toRadians(b.lng - a.lng);
  const lat1 = toRadians(a.lat);
  const lat2 = toRadians(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 + Math.sin(dLng / 2) ** 2 * Math.cos(lat1) * Math.cos(lat2);
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * Whether [report] belongs to [zone]: same hazard *type* and within the
 * cluster radius of the zone's centre.
 *
 * The type check is deliberately on `category` **and** `subCategory` — a
 * mugging and a pothole reported on the same corner are two different
 * hazards that decay on completely different schedules (48 hours vs. 7
 * days) and mean different things to a router. Merging them because they
 * share coordinates would let three unrelated single reports masquerade as
 * one confirmed Red Flag.
 */
function belongsToZone(report, zone) {
  if (report.category !== zone.category) return false;
  if (report.subCategory !== zone.subCategory) return false;
  return haversineMeters(report, zone) <= CLUSTER_RADIUS_M;
}

/**
 * The flag level a set of reports earns, and the evidence behind it.
 *
 * [reports] must already be the live (non-expired) members of one zone —
 * expiry is `hazard_decay.js`'s job, kept separate so a zone's decay rules
 * and its confirmation rules can be reasoned about (and tested) apart from
 * each other.
 */
function evaluateZone(reports, nowMs) {
  const live = reports.filter((r) => typeof r.createdAtMs === "number");
  if (live.length === 0) {
    return {
      flag: FLAG_NONE,
      reportCount: 0,
      distinctReporters: 0,
      recentReporters: 0,
      reporterLastSeenMs: {},
    };
  }

  // When each distinct reporter last flagged this hazard. Stored on the
  // zone document so the incremental create-trigger can apply the exact
  // same windowed rule as the hourly rebuild without re-reading every
  // report — the two disagreeing about what counts as confirmed is how an
  // anti-spam threshold quietly stops being one.
  const reporterLastSeenMs = {};
  for (const r of live) {
    const previous = reporterLastSeenMs[r.reporterUid] || 0;
    if (r.createdAtMs > previous) reporterLastSeenMs[r.reporterUid] = r.createdAtMs;
  }

  return {
    flag: flagFor(reporterLastSeenMs, nowMs),
    reportCount: live.length,
    distinctReporters: Object.keys(reporterLastSeenMs).length,
    recentReporters: recentReporterCount(reporterLastSeenMs, nowMs),
    reporterLastSeenMs,
  };
}

/**
 * Distinct reporters who flagged this hazard inside the Red Flag window.
 * Counts *reporters*, not reports — see this file's doc comment on why one
 * determined user must not be able to manufacture a Red Flag alone.
 */
function recentReporterCount(reporterLastSeenMs, nowMs) {
  return Object.values(reporterLastSeenMs).filter((at) => nowMs - at <= RED_FLAG_WINDOW_MS).length;
}

/** The single definition of "is this hazard confirmed?" in the codebase. */
function flagFor(reporterLastSeenMs, nowMs) {
  const total = Object.keys(reporterLastSeenMs).length;
  if (total === 0) return FLAG_NONE;
  return recentReporterCount(reporterLastSeenMs, nowMs) >= RED_FLAG_MIN_REPORTERS ? FLAG_RED : FLAG_YELLOW;
}

/**
 * The $w_2$ terrain/hazard weight a zone contributes to a route crossing
 * it, on the same 1-10 scale as $w_1$'s `baseCrimeScore` so the two can be
 * compared against one shared threshold in `checkRouteSafety`.
 *
 * A Yellow Flag deliberately lands *below* that threshold: it must produce
 * a spoken warning without silently rerouting anyone, because a single
 * unconfirmed report is exactly as likely to be a mistake as a real
 * blockage, and needlessly rerouting a user with a mobility impairment
 * costs them real distance and effort. A Red Flag lands above it.
 */
function hazardWeight(flag) {
  switch (flag) {
    case FLAG_RED:
      return 9;
    case FLAG_YELLOW:
      return 4;
    default:
      return 0;
  }
}

/**
 * Rebuilds every zone from scratch out of a flat list of live reports.
 *
 * Greedy single-pass clustering: each report joins the first existing zone
 * it is close enough to, or starts its own. With a 10 m radius and reports
 * arriving one at a time this is stable enough in practice, and it has the
 * property that matters most here — it is deterministic and cheap enough to
 * re-run over a whole collection during the decay sweep, so a zone can
 * never drift out of sync with the reports underneath it.
 */
function buildZones(reports, nowMs) {
  const zones = [];
  for (const report of reports) {
    if (typeof report.lat !== "number" || typeof report.lng !== "number") continue;
    const existing = zones.find((z) => belongsToZone(report, z));
    if (existing) {
      existing.reports.push(report);
      continue;
    }
    zones.push({
      lat: report.lat,
      lng: report.lng,
      category: report.category,
      subCategory: report.subCategory,
      reports: [report],
    });
  }

  return zones.map((zone) => {
    const evaluation = evaluateZone(zone.reports, nowMs);
    return {
      lat: zone.lat,
      lng: zone.lng,
      category: zone.category,
      subCategory: zone.subCategory,
      ...evaluation,
      hazardWeight: hazardWeight(evaluation.flag),
      reportIds: zone.reports.map((r) => r.id).filter(Boolean),
      reporterUids: Object.keys(evaluation.reporterLastSeenMs),
      lastReportedAtMs: Math.max(...zone.reports.map((r) => r.createdAtMs || 0)),
    };
  });
}

module.exports = {
  CLUSTER_RADIUS_M,
  RED_FLAG_MIN_REPORTERS,
  RED_FLAG_WINDOW_MS,
  FLAG_NONE,
  FLAG_YELLOW,
  FLAG_RED,
  haversineMeters,
  belongsToZone,
  evaluateZone,
  flagFor,
  recentReporterCount,
  hazardWeight,
  buildZones,
};
