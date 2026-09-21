/**
 * When the app should *say* a route is risky — §8.0.
 *
 * The property that matters most here is the conservative one: this change
 * must never produce a warning where the old fixed threshold would not have.
 * It ships to people walking at night who cannot see the map, and a rule that
 * warns more often than the one it replaced would be a regression however
 * well-calibrated it looked on paper.
 */

const test = require("node:test");
const assert = require("node:assert");

const {
  WARN_PERCENTILE,
  ABSOLUTE_FLOOR,
  quantile,
  ambientScores,
  warnThresholdFor,
  zonesWorthMentioning,
  riskKindOf,
} = require("../lib/risk_threshold");
const {
  THANA_CRIME_SEED,
  densityToScore,
  isNotoriousHotspot,
} = require("../data/dhaka_thana_crime_seed");
const { temporalMultiplier } = require("../lib/temporal_weighting");

/** The seed shaped the way `crimeZones` documents actually look. */
function seedZones() {
  return THANA_CRIME_SEED.map((t) => ({
    thanaName: t.thanaName,
    baseCrimeScore: densityToScore(t.densityEstimate),
    categoryHint: t.categoryHint,
    dataSource: t.dataSource,
    notoriousHotspot: isNotoriousHotspot(t),
  }));
}

/** Ambient score of one zone at one hour — what a route through it starts at. */
function scoreAt(zone, hour, cityMultiplier = 1) {
  return zone.baseCrimeScore
    * temporalMultiplier(zone.categoryHint, hour, { isHotspot: zone.notoriousHotspot })
    * cityMultiplier;
}

function warnedAt(hour, cityMultiplier = 1) {
  const zones = seedZones();
  const threshold = warnThresholdFor(zones, hour, cityMultiplier);
  return zones.filter((z) => scoreAt(z, hour, cityMultiplier) > threshold);
}

function oldRuleAt(hour, cityMultiplier = 1) {
  return seedZones().filter((z) => scoreAt(z, hour, cityMultiplier) > 7);
}

test("quantile interpolates rather than jumping between samples", () => {
  // Nearest-rank on 41 thanas would let the cut hop by several points when a
  // single zone is added or removed.
  assert.strictEqual(quantile([1, 2, 3, 4, 5], 0.5), 3);
  assert.strictEqual(quantile([0, 10], 0.5), 5);
  assert.strictEqual(quantile([0, 10], 0.9), 9);
  assert.strictEqual(quantile([], 0.9), 0, "an empty distribution must not throw");
  assert.strictEqual(quantile([4], 0.9), 4);
});

test("THE load-bearing property: it can never warn where the old rule did not", () => {
  // The whole justification for shipping this to live testers. `warnThreshold`
  // is max(percentile, old threshold), so the warned set is always a subset.
  for (let hour = 0; hour < 24; hour++) {
    for (const mult of [0.7, 0.71, 1.0, 1.5]) {
      const now = new Set(warnedAt(hour, mult).map((z) => z.thanaName));
      const before = new Set(oldRuleAt(hour, mult).map((z) => z.thanaName));
      for (const name of now) {
        assert.ok(
          before.has(name),
          `${name} would newly warn at ${hour}:00 (multiplier ${mult}) — this rule must only ever warn less`,
        );
      }
    }
  }
});

test("the night flood is what actually gets cut", () => {
  // §6a's measurement: 13 of 41 thanas flagged at 11pm with no crime evidence
  // involved, essentially all of central Dhaka. That is the number this
  // exists to bring down.
  const before = oldRuleAt(23).length;
  const after = warnedAt(23).length;
  assert.strictEqual(before, 13, "the seed should still reproduce the documented 13");
  assert.ok(after <= 5, `expected at most 5 night warnings, got ${after}`);
  assert.ok(after >= 3, `${after} is too few — this should still name the genuinely worst areas`);
});

test("daytime is untouched, because daytime was never the problem", () => {
  // By day the fixed 7 already sat above the 95th percentile, so the floor
  // binds and nothing changes. A rule that quietened the day too would be
  // solving a problem that does not exist.
  const before = oldRuleAt(14).map((z) => z.thanaName).sort();
  const after = warnedAt(14).map((z) => z.thanaName).sort();
  assert.deepStrictEqual(after, before);
  assert.deepStrictEqual(after, ["Paltan"]);
});

test("Paltan still warns at every hour — the overshoot check", () => {
  // The one thana the source data genuinely supports as an outlier: 29.77
  // crimes/km2, ~3.1 sigma above the mean, nearly double the next highest. A
  // recalibration that silences it has gone too far, so this is the floor of
  // the whole exercise rather than an incidental assertion.
  for (const hour of [2, 9, 14, 19, 20, 23]) {
    const names = warnedAt(hour).map((z) => z.thanaName);
    assert.ok(names.includes("Paltan"), `Paltan must still warn at ${hour}:00`);
  }
});

test("the threshold is relative at night and the floor by day", () => {
  const zones = seedZones();
  assert.strictEqual(warnThresholdFor(zones, 14), ABSOLUTE_FLOOR, "day: the floor binds");
  assert.ok(
    warnThresholdFor(zones, 23) > ABSOLUTE_FLOOR,
    "night: the distribution binds, because the whole city steps up at 8pm",
  );
});

test("the citywide multiplier cancels out of the comparison", () => {
  // It scales every thana identically, so it cannot change *which* zones are
  // unusual for the hour — only the absolute floor should feel it. This is
  // why the live 0.71 bug never distorted the relative judgement.
  const at071 = warnedAt(23, 0.71).map((z) => z.thanaName).sort();
  const at100 = warnedAt(23, 1.0).map((z) => z.thanaName).sort();
  assert.deepStrictEqual(at071, at100);
});

test("an empty crimeZones collection falls back to the floor, not to zero", () => {
  // A quantile of nothing is 0, and a threshold of 0 would warn about every
  // route ever scored — the loudest possible failure of a seeding bug.
  assert.strictEqual(warnThresholdFor([], 23, 1), ABSOLUTE_FLOOR);
  assert.deepStrictEqual(ambientScores([], 23, 1), []);
});

test("malformed zone documents are skipped, not turned into NaN", () => {
  // One bad document must not poison the distribution and take the threshold
  // with it.
  const scores = ambientScores(
    [{ baseCrimeScore: 5, categoryHint: "residential" }, { categoryHint: "residential" }, {}],
    23,
    1,
  );
  assert.ok(scores.every((s) => Number.isFinite(s)), "no NaN may reach the quantile");
  assert.ok(warnThresholdFor([{}], 23, 1) >= ABSOLUTE_FLOOR);
});

test("ambient scores ignore advisories and learned evidence by construction", () => {
  // The reference is what the city *normally* looks like at this hour.
  // Folding current advisories into it would raise the bar on exactly the
  // nights when more places have genuinely deteriorated — quietening the app
  // when it should be speaking up.
  const zone = { baseCrimeScore: 5, categoryHint: "residential", notoriousHotspot: false };
  const withNoise = { ...zone, advisoryMultiplier: 2, learnedMultiplier: 1.6, evidenceMonths: 12 };
  assert.deepStrictEqual(ambientScores([zone], 23, 1), ambientScores([withNoise], 23, 1));
});

test("a live advisory is never buried by the night percentile", () => {
  // The case that forced the exception, found by simulating real routes:
  // Shahbagh at 11pm with a `high` advisory scores 11.0 against a night
  // threshold of 11.5, so the percentile alone silenced *current, sourced
  // reporting naming that neighbourhood* — the one signal a pedestrian can
  // act on tonight.
  const shahbagh = { thanaName: "Shahbagh", effectiveScore: 11.0, advisoryMultiplier: 1.5 };
  assert.deepStrictEqual(zonesWorthMentioning([shahbagh], 11.5), [shahbagh]);

  // Without the advisory the same score stays quiet — the percentile is
  // still doing its job on ambient risk.
  assert.deepStrictEqual(
    zonesWorthMentioning([{ ...shahbagh, advisoryMultiplier: 1 }], 11.5),
    [],
  );
});

test("the advisory exception still cannot breach the floor", () => {
  // Otherwise it would be a way to warn about something the old rule passed,
  // and the conservative property would stop holding.
  const quiet = { thanaName: "Demra", effectiveScore: 3, advisoryMultiplier: 2 };
  assert.deepStrictEqual(zonesWorthMentioning([quiet], 11.5), []);
  assert.deepStrictEqual(zonesWorthMentioning([{ ...quiet, effectiveScore: 7 }], 11.5), [],
    "exactly at the floor is not above it");
  assert.strictEqual(zonesWorthMentioning([{ ...quiet, effectiveScore: 7.1 }], 11.5).length, 1);
});

test("zonesWorthMentioning survives malformed zones", () => {
  assert.deepStrictEqual(zonesWorthMentioning(null, 11.5), []);
  assert.deepStrictEqual(zonesWorthMentioning([{}], 11.5), []);
});

test("chronic and acute are told apart, and a hazard is always acute", () => {
  // The distinction §6a says is being lost: a thana mid-ranking for twenty
  // years and one with a spree reported this week produce the same score and
  // deserve different words.
  assert.strictEqual(riskKindOf([], false), null, "nothing to warn about has no kind");
  assert.strictEqual(riskKindOf([{ advisoryMultiplier: 1 }], false), "chronic");
  assert.strictEqual(riskKindOf([{ advisoryMultiplier: 1.5 }], false), "acute");
  assert.strictEqual(
    riskKindOf([{ advisoryMultiplier: 1 }, { advisoryMultiplier: 2 }], false),
    "acute",
    "one current advisory among several zones is enough",
  );
  // Three independent people reporting one obstruction in 24 hours is a
  // current event whatever the neighbourhood's standing score says.
  assert.strictEqual(riskKindOf([], true), "acute");
  assert.strictEqual(riskKindOf([{ advisoryMultiplier: 1 }], true), "acute");
});

test("the tuning constants are what the doc says they are", () => {
  // Both are quoted in docs/module4_crime_safety.md §8.0 and in the module
  // comment. Changing either is a real decision about what gets spoken to a
  // blind user, not a tweak.
  assert.strictEqual(WARN_PERCENTILE, 0.9);
  assert.strictEqual(ABSOLUTE_FLOOR, 7);
});
