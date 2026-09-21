/**
 * When a route's risk score is worth *saying something about*, as distinct
 * from when it is worth routing around.
 *
 * ## The problem this exists to fix
 *
 * `checkRouteSafety` compares an effective score against a fixed 7. That
 * number was never an absolute claim about danger and cannot be one:
 * `baseCrimeScore` is a min-max normalisation anchored on Demra (Dhaka's
 * quietest thana in 2009) and Paltan (its noisiest), so 7 means "70% of the
 * way up Dhaka's internal 2009 spread" and nothing else.
 *
 * Laid against the actual distribution of `baseCrimeScore ×
 * temporalMultiplier` over all 41 thanas, a fixed 7 lands in a different
 * place at every hour:
 *
 *     hour    median   p75    p90    over 7
 *     09-17      3.5    4.8    5.6    1 of 41
 *     20-05      6.1    9.9   16.2   13 of 41
 *
 * By day it sits above the 95th percentile — strict. At night it sits
 * between the median and p75, so **a "dangerous" route at 11pm is one that
 * is merely above average**, and 13 of 41 thanas qualify before a single
 * piece of crime evidence is involved. Essentially all of central Dhaka.
 *
 * That is backwards from any constant meaning, and the consequence is not
 * misrouting — the planner still picks the lowest-risk alternative either
 * way — it is that the spoken warning fires on a quarter of the city every
 * night. A warning that frequent is one users learn to talk over, and for
 * someone who cannot see the map to disagree, the warning *is* the
 * information.
 *
 * ## What replaces it
 *
 * A route earns a warning by being **unusual for this hour**: above the
 * [WARN_PERCENTILE] of the ambient distribution across all thanas at that
 * hour. Self-calibrating — the 8pm cliff stops mattering because the whole
 * distribution steps up with it, and the claim becomes "unusually risky for
 * a Dhaka night" rather than "risky compared with Demra at 2pm in 2009".
 *
 * Under that sits [ABSOLUTE_FLOOR]: below it, say nothing whatever the rank.
 * A purely relative rule always finds a top decile, so on a genuinely quiet
 * night it would invent a warning out of ranking alone.
 *
 * And beside it, one exception — a zone carrying a **live advisory** needs
 * only to clear the floor, never the percentile. See
 * [zonesWorthMentioning] for the case that forced that.
 *
 * ## Why this can only ever warn less
 *
 * [ABSOLUTE_FLOOR] is the old fixed threshold, and the rule takes the
 * *maximum* of the two conditions. So the set of routes that warn is always
 * a subset of the set that warns today — **this change cannot newly alarm
 * anybody**, at any hour, for any route. That property is worth more than a
 * cleverer rule would be, given this ships to people walking tonight.
 *
 * Measured against the seed: daytime warnings stay at 1 of 41 (Paltan, the
 * one genuinely evidence-backed outlier at 3.1 sigma). Night warnings fall
 * from 13 to 4 — Dhanmondi, Kotwali, Motijheel, Paltan.
 *
 * ## What this deliberately does not touch
 *
 * **Route selection.** `safe`, `threshold` and `dangerousZones` keep their
 * old meanings, so `RoutePlanningService`'s "take the first safe route,
 * else the lowest-risk one" loop behaves exactly as before. Relative scores
 * are the right tool for ranking alternatives and that half was never
 * broken; only the absolute reading of them was.
 */

const { temporalMultiplier } = require("./temporal_weighting");
const { isHotspotZone } = require("../data/dhaka_thana_crime_seed");

/**
 * How far up the hour's own distribution a route must sit.
 *
 * The top decile. Chosen against the real distribution rather than by
 * taste: on 41 thanas it selects four at both day and night, and the same
 * four are a defensible list at either hour. Tightening to p95 would select
 * two and drop Kotwali and Motijheel — two of the densest, busiest old-city
 * cores, which is the wrong pair to go quiet about.
 */
const WARN_PERCENTILE = 0.9;

/**
 * Below this, say nothing however high the rank.
 *
 * Deliberately the *old* fixed threshold. Keeping the two numbers equal is
 * what makes this change provably conservative — see the module comment.
 * Lowering it later is a real decision with real consequences and should be
 * made on its own evidence, not slipped in here.
 */
const ABSOLUTE_FLOOR = 7;

/**
 * Linear-interpolated quantile of an ascending array.
 *
 * Interpolated rather than nearest-rank because 41 thanas is a small
 * sample: nearest-rank makes the cut jump between two adjacent thanas'
 * scores, so adding or removing one zone could move the warning threshold
 * by several points.
 */
function quantile(ascending, q) {
  if (ascending.length === 0) return 0;
  if (ascending.length === 1) return ascending[0];
  const i = (ascending.length - 1) * Math.max(0, Math.min(1, q));
  const lo = Math.floor(i);
  const hi = Math.ceil(i);
  return ascending[lo] + (ascending[hi] - ascending[lo]) * (i - lo);
}

/**
 * What the city as a whole looks like at this hour.
 *
 * Deliberately `baseCrimeScore × temporalMultiplier × cityTrendMultiplier`
 * — the *ambient* risk of each thana — and deliberately **not** advisories
 * or learned evidence. Those are per-thana and current, and including them
 * in the reference would raise the bar on exactly the nights when more
 * places have genuinely deteriorated, which is when the app should be
 * saying more rather than less.
 *
 * The citywide multiplier is uniform, so it cancels out of the comparison
 * entirely and is included only to keep the returned threshold on the same
 * scale as `riskScore`, where a human reading the response can compare
 * them. A hotspot's *ambient* flag is used, never one an advisory promoted,
 * for the same reason: this is the baseline a route is being judged
 * against.
 */
function ambientScores(zones, hour, cityTrendMultiplier = 1) {
  return zones
    .map((zone) => (zone.baseCrimeScore ?? 0)
      * temporalMultiplier(zone.categoryHint, hour, { isHotspot: isHotspotZone(zone) })
      * cityTrendMultiplier)
    .filter((n) => Number.isFinite(n))
    .sort((a, b) => a - b);
}

/**
 * The score a route must exceed before the app says anything about it.
 *
 * Falls back to [ABSOLUTE_FLOOR] when there are no zones to build a
 * distribution from — an empty `crimeZones` collection must not produce a
 * threshold of 0 and warn about everything.
 */
function warnThresholdFor(zones, hour, cityTrendMultiplier = 1) {
  const ambient = ambientScores(zones, hour, cityTrendMultiplier);
  if (ambient.length === 0) return ABSOLUTE_FLOOR;
  return Math.max(ABSOLUTE_FLOOR, Math.round(quantile(ambient, WARN_PERCENTILE) * 10) / 10);
}

/**
 * The zones on a route worth saying something about.
 *
 * Two ways in, and the second one exists because the first swallowed
 * something it should not have. A route through Shahbagh at 11pm with a
 * live `high` advisory scores 11.0 against a night percentile of 11.5 — so
 * a purely percentile rule stayed silent about *current, sourced reporting
 * naming that neighbourhood*. That is the one signal a pedestrian can
 * actually act on tonight, and it is exactly backwards to let the ambient
 * distribution bury it.
 *
 * So the percentile filters *ambient* risk — what a thana is like on an
 * ordinary night — while anything with a live advisory needs only to clear
 * [ABSOLUTE_FLOOR]. Note that the floor is the old fixed threshold, so this
 * second route in cannot warn about anything the old rule would have passed
 * either: the conservative property still holds.
 */
function zonesWorthMentioning(evaluatedZones, warnThreshold) {
  return (evaluatedZones || []).filter((z) => {
    const score = z.effectiveScore ?? 0;
    if (score > warnThreshold) return true;
    return (z.advisoryMultiplier ?? 1) > 1 && score > ABSOLUTE_FLOOR;
  });
}

/**
 * Whether an elevated score is a *standing* property of the neighbourhood
 * or something that happened recently.
 *
 * Collapsing these into one number is what makes the app say the same
 * sentence about a thana that has been mid-ranking for twenty years and one
 * where a mugging spree was reported this week. They are different facts
 * and a pedestrian wants different words for them — so the factors stay
 * separable in the response instead of being multiplied away.
 *
 * A confirmed hazard counts as acute whatever the crime scores say: three
 * independent people reported a specific obstruction in the last 24 hours.
 */
function riskKindOf(warnZones, hasBlockingHazard) {
  if (hasBlockingHazard) return "acute";
  if (warnZones.length === 0) return null;
  const recent = warnZones.some((z) => (z.advisoryMultiplier ?? 1) > 1);
  return recent ? "acute" : "chronic";
}

module.exports = {
  WARN_PERCENTILE,
  ABSOLUTE_FLOOR,
  quantile,
  ambientScores,
  warnThresholdFor,
  zonesWorthMentioning,
  riskKindOf,
};
