/**
 * The citywide trend multiplier — the one number that scales every route
 * score in Dhaka at once.
 *
 * Both rules here were written against a specific failure that reached
 * production, and the tests are named for them rather than for the code.
 */

const test = require("node:test");
const assert = require("node:assert");

const {
  MIN_MULTIPLIER,
  MAX_MULTIPLIER,
  monthIndex,
  areConsecutive,
  cityTrendMultiplierFrom,
} = require("../lib/city_trend");

test("a rise in recorded crime is acted on", () => {
  // The unambiguous direction: more got written down despite the friction
  // of writing it down.
  assert.strictEqual(cityTrendMultiplierFrom(1.2), 1.2);
  assert.strictEqual(cityTrendMultiplierFrom(1.43), 1.43);
});

test("a fall in recorded crime returns to neutral, never below", () => {
  // August 2024: recorded cases fell from ~1600/month to 566, every
  // category at once, during weeks when police stations were attacked and
  // the force largely stopped functioning. The old rule read that as a 30%
  // improvement and made every route in Dhaka look safer in what was
  // plausibly the least safe month in the series.
  //
  // A fall cannot distinguish "less crime" from "less recording", so it
  // buys no adjustment at all.
  assert.strictEqual(cityTrendMultiplierFrom(0.31), 1.0, "the real Aug-2024 ratio");
  assert.strictEqual(cityTrendMultiplierFrom(0.7), 1.0);
  assert.strictEqual(cityTrendMultiplierFrom(0.99), 1.0);
  assert.strictEqual(cityTrendMultiplierFrom(1.0), 1.0);
});

test("one anomalous month cannot swing the whole city", () => {
  assert.strictEqual(cityTrendMultiplierFrom(4.0), MAX_MULTIPLIER);
  assert.strictEqual(cityTrendMultiplierFrom(1.5), 1.5);
  assert.strictEqual(cityTrendMultiplierFrom(1.51), 1.5);
});

test("the multiplier can never make a route look safer than its baseline", () => {
  // The load-bearing property. Whatever the input, this may only ever raise
  // risk or leave it alone — so a bad month of police record-keeping can no
  // longer talk the app out of looking for a safer route.
  for (const r of [-5, 0, 0.001, 0.31, 0.7, 0.999, 1, 1.0001, 2, 1e9]) {
    assert.ok(
      cityTrendMultiplierFrom(r) >= MIN_MULTIPLIER,
      `ratio ${r} produced ${cityTrendMultiplierFrom(r)}, below neutral`,
    );
  }
  assert.strictEqual(MIN_MULTIPLIER, 1.0);
});

test("garbage in holds at neutral rather than poisoning every route", () => {
  // A NaN reaching the multiplier would make every effectiveScore NaN, and
  // every comparison against a threshold false — an app that silently stops
  // flagging anything at all.
  for (const bad of [NaN, Infinity, -Infinity, null, undefined, "1.2"]) {
    assert.strictEqual(cityTrendMultiplierFrom(bad), 1.0, `${String(bad)} must hold neutral`);
  }
});

test("consecutive months are recognised regardless of order", () => {
  // Callers hold them newest-first.
  assert.ok(areConsecutive(["2026-08", "2026-07", "2026-06", "2026-05"]));
  assert.ok(areConsecutive(["2026-05", "2026-06", "2026-07", "2026-08"]));
  assert.ok(areConsecutive(["2025-01", "2024-12", "2024-11"]), "must cross a year boundary");
  assert.ok(areConsecutive(["2026-08"]));
});

test("THE bug: a gap in the series holds at neutral instead of comparing across it", () => {
  // cityTrend held 66 months ending 2025-05 plus a lone 2026-07, so the
  // rule compared July 2026 against spring 2025, produced 0.71, and scaled
  // every route in Dhaka for 18 days. Nothing errored and nothing logged —
  // which is exactly why this has to be checked rather than assumed.
  assert.ok(!areConsecutive(["2026-07", "2025-05", "2025-04", "2025-03"]));
  assert.ok(!areConsecutive(["2026-08", "2026-07", "2026-05"]), "a one-month hole still counts");
});

test("duplicate or malformed periods are not consecutive", () => {
  assert.ok(!areConsecutive(["2026-08", "2026-08", "2026-07"]));
  assert.ok(!areConsecutive(["2026-08", "not-a-month"]));
  assert.ok(!areConsecutive([]));
  assert.ok(!areConsecutive(null));
  assert.strictEqual(monthIndex("nope"), null);
  assert.strictEqual(monthIndex("2026-8"), null, "a one-digit month is not YYYY-MM");
  // Consecutive-ness is all `areConsecutive` promises; whether a period is
  // a *real* month is `validateExtraction`'s job, upstream of here.
  assert.strictEqual(monthIndex("2026-08") - monthIndex("2026-07"), 1);
  assert.strictEqual(monthIndex("2025-01") - monthIndex("2024-12"), 1);
});
