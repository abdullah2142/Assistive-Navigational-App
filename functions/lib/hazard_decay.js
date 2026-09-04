/**
 * Time-to-Live for crowdsourced hazard reports — Step 3 of
 * `05_module_plan_crowdsourcing.md`.
 *
 * Hazards are not permanent, and a city where every report lives forever
 * ends up entirely red-zoned and therefore useless: if everything is
 * dangerous, nothing is. Three lifetimes, keyed off what the report is
 * actually about rather than a single global TTL:
 *
 * 1. **Crime spikes** (a mugging, harassment) — 48 hours. A mugging on
 *    Tuesday says something real about Tuesday night and very little about
 *    next month.
 * 2. **Temporary blocks** (construction, waterlogging, a fallen tree) —
 *    7 days, refreshed whenever someone re-flags it. Dhaka's waterlogging
 *    and roadworks genuinely do clear.
 * 3. **Structural blocks** (stairs with no ramp, no curb cut, no tactile
 *    paving) — permanent. A staircase does not decay. These only ever leave
 *    when a user explicitly reports them resolved, which is why
 *    `resolveHazardZone` exists as a separate, deliberate action rather
 *    than these quietly ageing out and stranding a wheelchair user at the
 *    bottom of the same steps six months later.
 */

const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

const CRIME_TTL_MS = 48 * HOUR_MS;
const TEMPORARY_TTL_MS = 7 * DAY_MS;

/** Never expires on a timer — see this file's doc comment. */
const PERMANENT = null;

/**
 * Sub-categories that describe the built environment itself rather than
 * something that happened to it. Keys mirror
 * `Dashboard.hazardSubCategoryKeys` in the app — they are the stable
 * English identity stored on each report, never a localized label.
 *
 * Everything *not* listed here inside `accessibilityBlock` is treated as
 * temporary, which is the safe direction to be wrong in: a structural
 * problem wrongly aged out gets re-reported by the next person who hits it,
 * whereas a cleared obstruction wrongly kept forever permanently detours
 * every future user around a path that is actually fine.
 */
const STRUCTURAL_SUB_CATEGORIES = new Set([
  "noCurbCut",
  "stairsOnly",
  "narrowPassage",
  "noTactilePaving",
  "noSidewalk",
]);

/**
 * Milliseconds a report of this type stays live, or [PERMANENT].
 */
function ttlMsFor(category, subCategory) {
  if (category === "crime") return CRIME_TTL_MS;
  if (category === "accessibilityBlock" && STRUCTURAL_SUB_CATEGORIES.has(subCategory)) {
    return PERMANENT;
  }
  return TEMPORARY_TTL_MS;
}

/**
 * A report is expired once its TTL has elapsed since it was last
 * *reaffirmed* — `lastSeenAtMs` if a later reporter re-flagged the same
 * hazard, otherwise its original `createdAtMs`. That is what "unless
 * re-flagged" in the module plan means for the 7-day tier: an obstruction
 * people keep reporting keeps its clock reset, instead of vanishing on a
 * fixed schedule while it is demonstrably still there.
 *
 * Resolved reports are expired immediately regardless of type — that is the
 * only way a permanent structural block ever leaves.
 */
function isExpired(report, nowMs) {
  if (report.resolvedAtMs) return true;
  const ttl = ttlMsFor(report.category, report.subCategory);
  if (ttl === PERMANENT) return false;
  const since = report.lastSeenAtMs || report.createdAtMs;
  if (typeof since !== "number") return false;
  return nowMs - since > ttl;
}

module.exports = {
  CRIME_TTL_MS,
  TEMPORARY_TTL_MS,
  PERMANENT,
  STRUCTURAL_SUB_CATEGORIES,
  ttlMsFor,
  isExpired,
};
