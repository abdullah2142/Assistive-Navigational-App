/**
 * The safety engine's long-term memory.
 *
 * Without this, a neighbourhood flagged by current reporting reverts to its
 * 2009 score the moment the advisory expires — measured for Mohammadpur at
 * 38.0 with an advisory live and 6.1 once gone, back under the threshold.
 *
 * These assert how *hard* it is to move as firmly as they assert that it
 * moves. A persistent label on a real place, delivered to a user who cannot
 * see the map, should require persistent evidence.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  learnedAdjustment,
  recordEvidenceMonth,
  periodOf,
  isWithinWindow,
  MIN_EVIDENCE_MONTHS,
  SATURATION_MONTHS,
  MAX_ADJUSTMENT,
  WINDOW_MONTHS,
} = require("../lib/learned_baseline");

const NOW = Date.UTC(2026, 8, 4, 12, 0, 0); // 2026-09-04, Dhaka
const MONTH = 31 * 24 * 60 * 60 * 1000;

/** `count` consecutive months ending with the current one. */
function months(count, endMs = NOW) {
  const out = [];
  for (let i = count - 1; i >= 0; i--) out.push(periodOf(endMs - i * MONTH));
  return out;
}

test("a month is a Dhaka-local YYYY-MM", () => {
  assert.equal(periodOf(NOW), "2026-09");
  // 23:30 UTC on the 31st is already the 1st in Dhaka (UTC+6).
  assert.equal(periodOf(Date.UTC(2026, 7, 31, 23, 30)), "2026-09");
});

test("below the threshold there is no effect at all, not a small one", () => {
  // Two months of evidence is not yet a finding, and should be treated
  // exactly like none.
  assert.equal(learnedAdjustment([], NOW), 1);
  assert.equal(learnedAdjustment(months(1), NOW), 1);
  assert.equal(learnedAdjustment(months(MIN_EVIDENCE_MONTHS - 1), NOW), 1);
});

test("one news cycle cannot move the baseline", () => {
  // A single month, however severe whatever happened in it was.
  assert.equal(learnedAdjustment(["2026-09"], NOW), 1);
});

test("sustained evidence moves it, and saturates at the cap", () => {
  assert.ok(learnedAdjustment(months(MIN_EVIDENCE_MONTHS), NOW) >= 1);
  const half = learnedAdjustment(months(7), NOW);
  const full = learnedAdjustment(months(SATURATION_MONTHS), NOW);
  assert.ok(half > 1 && half < full, `expected a middle value, got ${half} vs ${full}`);
  assert.equal(full, MAX_ADJUSTMENT);
  // And it cannot be pushed past the cap by piling on more.
  assert.equal(learnedAdjustment(months(SATURATION_MONTHS + 24), NOW), MAX_ADJUSTMENT);
});

test("it is capped well below the temporal and advisory multipliers", () => {
  // This corrects a stale figure; it does not become a new source of truth.
  assert.ok(MAX_ADJUSTMENT < 2.0, "must not rival the advisory multiplier");
  assert.ok(MAX_ADJUSTMENT < 5.0, "must not rival the hotspot multiplier");
});

test("evidence ages out, so a neighbourhood can recover on its own", () => {
  const old = months(SATURATION_MONTHS, NOW - (WINDOW_MONTHS + 2) * MONTH);
  assert.equal(learnedAdjustment(old, NOW), 1, "no manual intervention should be needed to undo this");
  assert.ok(!isWithinWindow("2020-01", NOW));
  assert.ok(isWithinWindow(periodOf(NOW), NOW));
});

test("duplicate and malformed months are ignored rather than counted", () => {
  assert.equal(learnedAdjustment(["2026-09", "2026-09", "2026-09", "2026-09"], NOW), 1);
  assert.equal(learnedAdjustment([null, "", "nonsense", "2026-13"], NOW), 1);
  assert.equal(learnedAdjustment(undefined, NOW), 1);
});

test("recording is idempotent within a month", () => {
  const evidence = { hasNewsAdvisory: true, hasConfirmedCrimeReports: false };
  const first = recordEvidenceMonth([], evidence, NOW);
  assert.deepEqual(first, ["2026-09"]);
  // The sweep runs hourly; it must not add the same month 700 times.
  assert.equal(recordEvidenceMonth(first, evidence, NOW), null);
});

test("no evidence records nothing", () => {
  assert.equal(
    recordEvidenceMonth([], { hasNewsAdvisory: false, hasConfirmedCrimeReports: false }, NOW),
    null,
  );
});

test("either line of evidence is sufficient on its own", () => {
  // Published reporting and three app users flagging the same corner rarely
  // observe the same incidents; requiring both would mostly require a
  // coincidence.
  assert.ok(recordEvidenceMonth([], { hasNewsAdvisory: true, hasConfirmedCrimeReports: false }, NOW));
  assert.ok(recordEvidenceMonth([], { hasNewsAdvisory: false, hasConfirmedCrimeReports: true }, NOW));
});

test("stored evidence is trimmed to the window on write", () => {
  const ancient = ["2019-01", "2020-05"];
  const updated = recordEvidenceMonth(ancient, { hasNewsAdvisory: true }, NOW);
  assert.deepEqual(updated, ["2026-09"], "a zone document must not grow without bound");
});

test("Mohammadpur: the engine now remembers", () => {
  const { densityToScore } = require("../data/dhaka_thana_crime_seed");
  const { temporalMultiplier } = require("../lib/temporal_weighting");

  const base = densityToScore(9.35);
  const nightNoMemory = base * temporalMultiplier("mixed", 23);
  assert.ok(nightNoMemory < 7, `was ${nightNoMemory} — the measured pre-fix reversion`);

  // After a year of recurring evidence, the same night score with no
  // advisory live at all.
  const learned = learnedAdjustment(months(SATURATION_MONTHS), NOW);
  const nightWithMemory = nightNoMemory * learned;
  assert.ok(
    nightWithMemory > nightNoMemory,
    "sustained evidence must survive the advisory that produced it",
  );

  // But memory alone stays a correction, not a verdict — it does not by
  // itself declare the area dangerous. Crossing the line still needs the
  // current signal.
  assert.ok(learned <= MAX_ADJUSTMENT);
});
