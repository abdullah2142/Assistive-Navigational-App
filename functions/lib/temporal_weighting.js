/**
 * Temporal Crime Weighting (Module 4, Step 3 / `project_master_plan.md`'s
 * "Static Crime & Temporal Weighting" guardrail): a Thana's static
 * `baseCrimeScore` gets multiplied based on time-of-day and the zone's
 * character, since e.g. a commercial district that's safe and crowded at
 * 2pm can be dark and deserted — and genuinely riskier — at 11pm.
 */

const NIGHT_START_HOUR = 20; // 8 PM
const NIGHT_END_HOUR = 5; // 5 AM

function isNightHour(hour) {
  return hour >= NIGHT_START_HOUR || hour < NIGHT_END_HOUR;
}

/**
 * Multiplier applied to a zone's `baseCrimeScore` for a given local hour
 * (0-23) and its `categoryHint`. Commercial/institutional/transit zones —
 * busy and self-policing by daytime footfall — spike the most once that
 * footfall disappears at night. Purely residential zones see a much
 * smaller bump (people are still home). Industrial zones, largely deserted
 * either way, land in between.
 */
function temporalMultiplier(categoryHint, hour) {
  if (!isNightHour(hour)) return 1.0;

  switch (categoryHint) {
    case 'commercial_core':
    case 'transit_hub':
      return 1.6;
    case 'institutional':
    case 'industrial':
      return 1.3;
    case 'mixed':
      return 1.25;
    case 'residential':
    default:
      return 1.1;
  }
}

module.exports = { temporalMultiplier, isNightHour, NIGHT_START_HOUR, NIGHT_END_HOUR };
