/**
 * A slow, evidence-accumulating adjustment to a thana's static crime score.
 *
 * ## The gap this closes
 *
 * Everything else in the safety engine is either **permanently stale** or
 * **temporary**:
 *
 * - `dhaka_thana_crime_seed.js` is real, citable and from 2009. It can
 *   never be refreshed per-thana, because no current source publishes crime
 *   broken down by Dhaka thana.
 * - The citywide trend multiplier is current but uniform — it knows crime
 *   is up, not *where*.
 * - Advisories (`thana_advisory.js`) are current and per-thana, but they
 *   expire by design, and they should.
 *
 * So a neighbourhood that has genuinely deteriorated gets flagged while it
 * is in the news and then silently reverts to its 2009 score. Measured for
 * Mohammadpur: 38.0 at night with a severe advisory live, **6.1 once it
 * expires** — back under the threshold, as though nothing had ever been
 * reported. The engine could react to current data but could not *learn*
 * from it.
 *
 * This is that memory. Not a faster advisory — a much slower one.
 *
 * ## Why it is deliberately hard to move
 *
 * It counts **distinct months in which independent evidence existed** — not
 * incidents, not articles, not posts. One bad news cycle produces one
 * evidence month and moves the number not at all; a neighbourhood that
 * shows up month after month moves it a lot. That shape is the whole point:
 * a lasting label on a real place should require lasting evidence, and a
 * fast-moving baseline would reproduce exactly the harm this subsystem
 * exists to prevent, with a longer half-life.
 *
 * Three further constraints:
 *
 * - **Social signals never count here.** They can raise a temporary
 *   advisory; they cannot edit a neighbourhood's standing score.
 *   Corroborated chatter is enough to prefer another street today, nowhere
 *   near enough to change what the app believes about a place.
 * - **It is capped well below the other multipliers**, so the sourced 2009
 *   figure is still recognisable in the result. This corrects a stale
 *   baseline; it does not replace it.
 * - **It decays on its own.** Evidence ages out of the window, so a
 *   neighbourhood that improves recovers with no manual intervention. There
 *   is no permanent state here and nothing anyone has to remember to undo.
 */

/**
 * Months of history considered. Two years is long enough for a real trend
 * to accumulate, short enough that a place is not defined by what it was
 * like two years ago.
 */
const WINDOW_MONTHS = 24;

/**
 * Evidence months needed before the baseline moves at all.
 *
 * Three, matching every other corroboration threshold in this codebase
 * (Module 5's Red Flag, social corroboration). One or two months is a news
 * cycle; three separate months is a pattern.
 */
const MIN_EVIDENCE_MONTHS = 3;

/**
 * The most the learned adjustment can ever multiply a base score by.
 *
 * Far below what the temporal (up to 5x) and advisory (up to 2x)
 * multipliers can do, on purpose — this is a correction to a stale figure,
 * not a new source of truth.
 */
const MAX_ADJUSTMENT = 1.6;

/** Evidence months at which [MAX_ADJUSTMENT] is reached. */
const SATURATION_MONTHS = 12;

/** `YYYY-MM` for a timestamp, in Dhaka's fixed UTC+6 offset (no DST). */
function periodOf(ms) {
  return new Date(ms + 6 * 60 * 60 * 1000).toISOString().slice(0, 7);
}

/** Whether `period` (`YYYY-MM`) falls inside the rolling window ending now. */
function isWithinWindow(period, nowMs) {
  if (typeof period !== 'string' || !/^\d{4}-\d{2}$/.test(period)) return false;
  const [year, month] = period.split('-').map(Number);
  const [nowYear, nowMonth] = periodOf(nowMs).split('-').map(Number);
  const monthsAgo = (nowYear - year) * 12 + (nowMonth - month);
  return monthsAgo >= 0 && monthsAgo < WINDOW_MONTHS;
}

/**
 * The multiplier a thana's accumulated evidence months justify.
 *
 * Returns exactly 1.0 below the threshold — no effect whatsoever, rather
 * than a small one. Two months of evidence is not yet a finding, and a
 * neighbourhood with two should be treated identically to one with none.
 */
function learnedAdjustment(evidenceMonths, nowMs) {
  const live = [...new Set(evidenceMonths || [])].filter((p) => isWithinWindow(p, nowMs));
  if (live.length < MIN_EVIDENCE_MONTHS) return 1;

  const span = SATURATION_MONTHS - MIN_EVIDENCE_MONTHS;
  const progress = Math.min(1, (live.length - MIN_EVIDENCE_MONTHS) / span);
  return Math.round((1 + (MAX_ADJUSTMENT - 1) * progress) * 100) / 100;
}

/**
 * Marks the current month as an evidence month, if there is evidence.
 *
 * Returns the updated list, or null when nothing changed — callers use that
 * to skip a Firestore write, since this runs hourly and will have nothing
 * to say the overwhelming majority of the time.
 *
 * News advisories and confirmed crowdsourced crime reports are accepted as
 * independent lines of evidence, either sufficient on its own. They rarely
 * observe the same incidents — one is published reporting, the other is
 * three separate app users flagging a crime hazard at the same spot — so
 * requiring both would mostly mean requiring a coincidence.
 */
function recordEvidenceMonth(existing, { hasNewsAdvisory, hasConfirmedCrimeReports }, nowMs) {
  if (!hasNewsAdvisory && !hasConfirmedCrimeReports) return null;
  const period = periodOf(nowMs);
  const current = Array.isArray(existing) ? existing : [];
  if (current.includes(period)) return null;
  // Trimmed to the window on write, so a zone document cannot grow without
  // bound and old evidence cannot silently linger past its usefulness.
  return [...new Set([...current, period])].filter((p) => isWithinWindow(p, nowMs)).sort();
}

module.exports = {
  WINDOW_MONTHS,
  MIN_EVIDENCE_MONTHS,
  MAX_ADJUSTMENT,
  SATURATION_MONTHS,
  periodOf,
  isWithinWindow,
  learnedAdjustment,
  recordEvidenceMonth,
};
