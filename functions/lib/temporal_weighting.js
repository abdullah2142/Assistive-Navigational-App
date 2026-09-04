/**
 * Temporal Crime Weighting — Step 4 of `05_module_plan_crowdsourcing.md`
 * (and the "Static Crime & Temporal Weighting" guardrail in
 * `project_master_plan.md`).
 *
 * $w_1(t) = \text{Base Score} \times \text{Temporal Multiplier}$.
 *
 * Crowdsourcing alone is reactive — it can only tell you about a place
 * *after* something has already happened to somebody there. Temporal
 * weighting is the proactive half: a commercial district like Motijheel is
 * busy, overlooked and genuinely safe at 2 PM, and dark, emptied-out and
 * genuinely not at 11 PM, with the same static crime score either way. The
 * multiplier is what lets one base score describe both.
 *
 * The practical outcome, per the module plan: a user requesting a route at
 * 11:30 PM is pushed onto lit arterial roads, because every quiet
 * commercial shortcut has mathematically priced itself out.
 */

const NIGHT_START_HOUR = 20; // 8 PM
const NIGHT_END_HOUR = 5; // 5 AM

/** Dusk is earlier than the "night" threshold — Dhaka sunset is ~5:15-6:45 PM. */
const DUSK_START_HOUR = 18; // 6 PM

function isNightHour(hour) {
  return hour >= NIGHT_START_HOUR || hour < NIGHT_END_HOUR;
}

function isDuskOrLater(hour) {
  return hour >= DUSK_START_HOUR || hour < NIGHT_END_HOUR;
}

/**
 * Multiplier applied to a zone's `baseCrimeScore` for a given local hour
 * (0-23) and its `categoryHint`.
 *
 * The module plan's own worked examples set the calibration:
 * - Commercial/office (Motijheel): "spikes $w_1$ by 3x after 8 PM".
 * - Notorious hotspots: "high base score always, but multiplier maxes out
 *   at 5x after dusk" — note *dusk*, not 8 PM, and note that this is the
 *   one typology whose multiplier starts climbing before full night.
 * - Residential: "relatively stable".
 *
 * An earlier version of this file capped everything at 1.6x, which is far
 * too flat to produce the behaviour the plan describes: against a 1-10 base
 * score and a threshold of 7, a 1.6x night multiplier could not lift a
 * typical mid-range commercial score over the line at all, so "avoid empty
 * commercial districts at midnight" never actually happened. Routing
 * degrades to the lowest-risk candidate rather than failing when nothing
 * clears the threshold (see `RoutePlanningService`), so a genuinely sharp
 * multiplier changes *which* route is picked without ever leaving a user
 * with no route.
 */
function temporalMultiplier(categoryHint, hour, { isHotspot = false } = {}) {
  // A notorious hotspot is a separate axis from the zone's character, not a
  // replacement for it — Paltan is a commercial core *and* a statistical
  // outlier, and collapsing the two would discard the daytime-footfall
  // signal the rest of this function runs on. See `isNotoriousHotspot` in
  // `data/dhaka_thana_crime_seed.js` for how a zone earns this flag (it is
  // derived from the crime table, never hand-listed).
  //
  // Hotspots are also the one case that reacts to *dusk* rather than to the
  // later night threshold, and they ramp toward their ceiling instead of
  // jumping to it — 5x is the maximum the module plan allows, held for the
  // genuinely dead hours.
  if (isHotspot) {
    if (isNightHour(hour)) return 5.0;
    if (isDuskOrLater(hour)) return 3.0;
    return 1.2; // "high base score always" — the base score carries the daytime risk.
  }

  if (!isNightHour(hour)) return 1.0;

  switch (categoryHint) {
    // Busy and self-policing purely because of daytime footfall; the risk
    // is precisely that the footfall leaves.
    case "commercial_core":
    case "transit_hub":
      return 3.0;
    case "institutional":
      return 2.2;
    // Largely deserted at every hour, so night changes less about them.
    case "industrial":
      return 1.8;
    case "mixed":
      return 1.6;
    // People are still home, windows are still lit, streets keep some life.
    case "residential":
    default:
      return 1.2;
  }
}

module.exports = {
  temporalMultiplier,
  isNightHour,
  isDuskOrLater,
  NIGHT_START_HOUR,
  NIGHT_END_HOUR,
  DUSK_START_HOUR,
};
