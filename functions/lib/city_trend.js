/**
 * Turning a month-over-month change in *recorded* citywide crime into a
 * number that scales every route score in Dhaka.
 *
 * ## Why this is one-directional
 *
 * The figure being compared is recorded crime, which is real crime
 * multiplied by the police's capacity and willingness to write it down.
 * Those two come apart, and they come apart in exactly the conditions where
 * a pedestrian most needs the warning to be right.
 *
 * August 2024, from this project's own `cityTrend` collection:
 *
 *     period   pedestrian-relevant   total cases
 *     2024-06          293               1612
 *     2024-07          185               1425
 *     2024-08           77                566     <-- every category at once
 *     2024-09          149               1008
 *
 * A 65% collapse across *all* categories simultaneously, during the weeks
 * around the July–August 2024 uprising when police stations were attacked
 * and the force largely stopped functioning. Kidnapping moved the other way
 * over the same months — 1, then 11, then 22 — because those are the cases
 * families escalate hard enough to get filed regardless. That is the shape
 * of recording stopping, not of crime stopping.
 *
 * The old rule read it as a 30% improvement and pinned the multiplier to
 * its 0.70 floor: make every route in Dhaka look safer, in what was
 * plausibly the least safe month in the series.
 *
 * So the asymmetry here is in the evidence, not in our caution:
 *
 * - A **rise** in recorded crime is unambiguous. More got written down
 *   despite the friction of writing it down.
 * - A **fall** is ambiguous. Less crime, or less recording, and the number
 *   cannot distinguish them.
 *
 * A rise is acted on; a fall returns to neutral. `thana_advisory.js` makes
 * the same trade for the same reason — advisories can only ever raise risk.
 *
 * ## This is a real dial, which is why its direction matters
 *
 * Replayed over 62 months of contiguous history: median 1.02, sd 0.185,
 * only 47% of months within ±10% of neutral, and month-to-month
 * autocorrelation of just 0.33. It moves scores by more than 10% in most
 * months on a signal that barely predicts itself — tolerable when it can
 * only ever make the app more cautious, not when it can talk the app out of
 * looking for a safer route.
 *
 * ## What it still cannot do
 *
 * It is uniform across all 41 thanas, so it says *how much*, never *where*.
 * It cannot change which of several candidate routes ranks safest — only
 * how readily the app goes looking for an alternative at all.
 */

/**
 * Hard ceiling on the adjustment.
 *
 * One anomalous month — a data-entry error, a one-off crackdown — must not
 * swing every route in the city.
 */
const MAX_MULTIPLIER = 1.5;

/**
 * The floor, and the whole point: **neutral, not 0.7**.
 *
 * See the module comment. A drop in recorded crime is not evidence that
 * walking got safer.
 */
const MIN_MULTIPLIER = 1.0;

/** `YYYY-MM` as a comparable month index. */
function monthIndex(period) {
  if (typeof period !== "string" || !/^\d{4}-\d{2}$/.test(period)) return null;
  const [y, m] = period.split("-").map(Number);
  return y * 12 + (m - 1);
}

/**
 * Whether a set of `YYYY-MM` periods are consecutive calendar months.
 *
 * Order-independent, because callers hold them newest-first. A ratio across
 * a gap is not a trend, and — worse — nothing about the resulting number
 * looks wrong: a 13-month hole in `cityTrend` had `updateCityTrendMultiplier`
 * comparing July 2026 against spring 2025 and reporting 0.71 with no error
 * for 18 days.
 */
function areConsecutive(periods) {
  const idx = (periods || []).map(monthIndex);
  if (idx.length === 0 || idx.some((i) => i === null)) return false;
  const sorted = [...idx].sort((a, b) => a - b);
  if (new Set(sorted).size !== sorted.length) return false;
  return sorted[sorted.length - 1] - sorted[0] === sorted.length - 1;
}

/**
 * The multiplier a raw ratio justifies.
 *
 * Anything at or below neutral becomes exactly 1.0 — not a softened version
 * of the fall, and not a small discount. Either the fall is real and we
 * cannot prove it, or it is a recording artefact and acting on it is
 * actively harmful; both cases argue for the same answer.
 */
function cityTrendMultiplierFrom(rawRatio) {
  if (!Number.isFinite(rawRatio) || rawRatio <= 0) return MIN_MULTIPLIER;
  const rounded = Math.round(rawRatio * 100) / 100;
  return Math.max(MIN_MULTIPLIER, Math.min(MAX_MULTIPLIER, rounded));
}

module.exports = {
  MIN_MULTIPLIER,
  MAX_MULTIPLIER,
  monthIndex,
  areConsecutive,
  cityTrendMultiplierFrom,
};
