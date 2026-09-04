/**
 * Tests for Module 5's pure decision logic — clustering/anti-spam (Step 2),
 * data decay (Step 3) and temporal weighting (Step 4).
 *
 * Run with `npm test` in `functions/` (node's built-in test runner, no test
 * dependency added). These are the parts that decide whether a road gets
 * closed for every user of the app, so they are tested away from Firestore
 * rather than only exercised through a deployed function.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  haversineMeters,
  belongsToZone,
  evaluateZone,
  flagFor,
  hazardWeight,
  buildZones,
  CLUSTER_RADIUS_M,
  FLAG_NONE,
  FLAG_YELLOW,
  FLAG_RED,
} = require("../lib/hazard_clustering");
const { ttlMsFor, isExpired, PERMANENT, CRIME_TTL_MS, TEMPORARY_TTL_MS } = require("../lib/hazard_decay");
const { temporalMultiplier } = require("../lib/temporal_weighting");

const NOW = Date.UTC(2026, 8, 4, 12, 0, 0);
const HOUR = 60 * 60 * 1000;

// Somewhere in Dhanmondi, Dhaka.
const BASE = { lat: 23.7461, lng: 90.3742 };

/** A point `metres` due east of [BASE] — longitude shrinks with latitude. */
function eastOf(metres) {
  const degPerMetre = 1 / (111320 * Math.cos((BASE.lat * Math.PI) / 180));
  return { lat: BASE.lat, lng: BASE.lng + metres * degPerMetre };
}

function report(overrides = {}) {
  return {
    id: overrides.id || Math.random().toString(36).slice(2),
    reporterUid: "user-1",
    category: "roadHazard",
    subCategory: "pothole",
    lat: BASE.lat,
    lng: BASE.lng,
    createdAtMs: NOW,
    ...overrides,
  };
}

test("haversineMeters measures real ground distance", () => {
  assert.equal(Math.round(haversineMeters(BASE, BASE)), 0);
  assert.ok(Math.abs(haversineMeters(BASE, eastOf(10)) - 10) < 0.5);
  assert.ok(Math.abs(haversineMeters(BASE, eastOf(100)) - 100) < 2);
});

test("a 10m radius is a circle, not a lat/lng box", () => {
  // One degree of longitude is ~9km shorter than one of latitude at
  // Dhaka's latitude. A naive equal-delta check would treat these two
  // offsets as the same distance; they are not.
  const dLat = 0.00009; // ~10.0m north
  const dLng = 0.00009; // ~9.2m east
  const north = { lat: BASE.lat + dLat, lng: BASE.lng };
  const east = { lat: BASE.lat, lng: BASE.lng + dLng };
  assert.ok(haversineMeters(BASE, north) > haversineMeters(BASE, east));
});

test("belongsToZone requires the same hazard type, not just proximity", () => {
  const zone = { ...BASE, category: "roadHazard", subCategory: "pothole" };
  assert.ok(belongsToZone(report(), zone));
  assert.ok(belongsToZone(report(eastOf(CLUSTER_RADIUS_M - 1)), zone));
  assert.ok(!belongsToZone(report(eastOf(CLUSTER_RADIUS_M + 5)), zone));
  assert.ok(!belongsToZone(report({ subCategory: "flooding" }), zone));
  assert.ok(!belongsToZone(report({ category: "crime", subCategory: "pothole" }), zone));
});

test("one report is a Yellow Flag — a warning, never a reroute", () => {
  const result = evaluateZone([report()], NOW);
  assert.equal(result.flag, FLAG_YELLOW);
  assert.ok(hazardWeight(FLAG_YELLOW) < 7, "a Yellow Flag must stay under the reroute threshold");
});

test("three independent reporters inside 24h is a Red Flag", () => {
  const reports = [
    report({ reporterUid: "a" }),
    report({ reporterUid: "b", createdAtMs: NOW - 3 * HOUR }),
    report({ reporterUid: "c", createdAtMs: NOW - 20 * HOUR }),
  ];
  const result = evaluateZone(reports, NOW);
  assert.equal(result.flag, FLAG_RED);
  assert.equal(result.recentReporters, 3);
  assert.ok(hazardWeight(FLAG_RED) > 7, "a Red Flag must clear the reroute threshold");
});

test("one user reporting three times cannot manufacture a Red Flag", () => {
  const spam = [
    report({ reporterUid: "same-person", id: "1" }),
    report({ reporterUid: "same-person", id: "2" }),
    report({ reporterUid: "same-person", id: "3" }),
    report({ reporterUid: "same-person", id: "4" }),
  ];
  const result = evaluateZone(spam, NOW);
  assert.equal(result.flag, FLAG_YELLOW, "anti-spam counts distinct reporters, not documents");
  assert.equal(result.reportCount, 4);
  assert.equal(result.distinctReporters, 1);
});

test("reporters outside the 24h window do not count toward a Red Flag", () => {
  const stale = [
    report({ reporterUid: "a", createdAtMs: NOW - 30 * HOUR }),
    report({ reporterUid: "b", createdAtMs: NOW - 40 * HOUR }),
    report({ reporterUid: "c", createdAtMs: NOW }),
  ];
  const result = evaluateZone(stale, NOW);
  assert.equal(result.flag, FLAG_YELLOW);
  assert.equal(result.recentReporters, 1);
});

test("an empty zone carries no flag and no weight", () => {
  assert.equal(evaluateZone([], NOW).flag, FLAG_NONE);
  assert.equal(hazardWeight(FLAG_NONE), 0);
});

test("buildZones separates different hazards at the same spot", () => {
  const zones = buildZones(
    [
      report({ reporterUid: "a", category: "crime", subCategory: "mugging" }),
      report({ reporterUid: "b", category: "roadHazard", subCategory: "pothole" }),
      report({ reporterUid: "c", category: "roadHazard", subCategory: "pothole", ...eastOf(4) }),
    ],
    NOW,
  );
  assert.equal(zones.length, 2);
  const pothole = zones.find((z) => z.subCategory === "pothole");
  assert.equal(pothole.reportCount, 2);
  assert.equal(pothole.flag, FLAG_YELLOW);
});

test("buildZones skips reports with no coordinates", () => {
  const zones = buildZones([report({ lat: null, lng: null }), report()], NOW);
  assert.equal(zones.length, 1);
});

test("decay: TTL depends on what the report is about", () => {
  assert.equal(ttlMsFor("crime", "mugging"), CRIME_TTL_MS);
  assert.equal(ttlMsFor("roadHazard", "construction"), TEMPORARY_TTL_MS);
  assert.equal(ttlMsFor("roadHazard", "flooding"), TEMPORARY_TTL_MS);
  assert.equal(ttlMsFor("accessibilityBlock", "stairsOnly"), PERMANENT);
  assert.equal(ttlMsFor("accessibilityBlock", "noCurbCut"), PERMANENT);
  // A broken ramp gets fixed; stairs do not become a ramp.
  assert.equal(ttlMsFor("accessibilityBlock", "brokenRamp"), TEMPORARY_TTL_MS);
});

test("decay: crime spikes expire after 48h, temporary blocks after 7 days", () => {
  const mugging = report({ category: "crime", subCategory: "mugging", createdAtMs: NOW });
  assert.ok(!isExpired(mugging, NOW + 47 * HOUR));
  assert.ok(isExpired(mugging, NOW + 49 * HOUR));

  const works = report({ category: "roadHazard", subCategory: "construction", createdAtMs: NOW });
  assert.ok(!isExpired(works, NOW + 6 * 24 * HOUR));
  assert.ok(isExpired(works, NOW + 8 * 24 * HOUR));
});

test("decay: re-flagging a temporary block resets its clock", () => {
  const works = report({
    category: "roadHazard",
    subCategory: "construction",
    createdAtMs: NOW,
    lastSeenAtMs: NOW + 6 * 24 * HOUR,
  });
  assert.ok(!isExpired(works, NOW + 10 * 24 * HOUR), "re-flagged within the window should survive");
  assert.ok(isExpired(works, NOW + 14 * 24 * HOUR));
});

test("decay: a structural block never ages out, but can be resolved", () => {
  const stairs = report({ category: "accessibilityBlock", subCategory: "stairsOnly", createdAtMs: NOW });
  assert.ok(!isExpired(stairs, NOW + 365 * 24 * HOUR));
  assert.ok(isExpired({ ...stairs, resolvedAtMs: NOW + HOUR }, NOW + 2 * HOUR));
});

test("temporal weighting matches the module plan's worked examples", () => {
  // Motijheel-style commercial core: safe at 2 PM, 3x after 8 PM.
  assert.equal(temporalMultiplier("commercial_core", 14), 1.0);
  assert.equal(temporalMultiplier("commercial_core", 23), 3.0);
  assert.equal(temporalMultiplier("commercial_core", 3), 3.0);

  // Notorious hotspot: elevated from dusk, maxing at 5x. A separate axis
  // from the typology — Paltan is a commercial core AND an outlier.
  assert.equal(temporalMultiplier("commercial_core", 19, { isHotspot: true }), 3.0);
  assert.equal(temporalMultiplier("commercial_core", 23, { isHotspot: true }), 5.0);
  assert.ok(
    temporalMultiplier("commercial_core", 14, { isHotspot: true }) > 1.0,
    "high base risk applies all day",
  );
  // Not a hotspot unless explicitly flagged.
  assert.equal(temporalMultiplier("commercial_core", 23), 3.0);

  // Residential: relatively stable.
  assert.ok(temporalMultiplier("residential", 23) <= 1.3);

  // An unknown typology must never crash or spike.
  assert.equal(temporalMultiplier("something_new", 14), 1.0);
  assert.ok(temporalMultiplier("something_new", 23) <= 1.3);
});

test("temporal weighting actually changes a routing decision at night", () => {
  // The point of the whole mechanism: a mid-range commercial score has to
  // be able to cross the threshold at night and not during the day. The
  // previous 1.6x ceiling could not do this for any realistic base score.
  const THRESHOLD = 7;
  const baseScore = 3.0;
  assert.ok(baseScore * temporalMultiplier("commercial_core", 14) < THRESHOLD);
  assert.ok(baseScore * temporalMultiplier("commercial_core", 23) > THRESHOLD);
});

test("the incremental trigger and the hourly rebuild agree on every flag", () => {
  // `onHazardReportCreated` updates a zone from the stored per-reporter
  // timestamps; `decayHazardZones` rebuilds it from the reports themselves.
  // If those two ever disagree about what "confirmed" means, the anti-spam
  // threshold silently stops being one — a road could be closed by an
  // incremental path that a rebuild would immediately reopen, and back.
  const scenarios = [
    [report({ reporterUid: "a" })],
    [report({ reporterUid: "a" }), report({ reporterUid: "a" }), report({ reporterUid: "a" })],
    [report({ reporterUid: "a" }), report({ reporterUid: "b" }), report({ reporterUid: "c" })],
    [
      report({ reporterUid: "a", createdAtMs: NOW - 30 * HOUR }),
      report({ reporterUid: "b", createdAtMs: NOW - 26 * HOUR }),
      report({ reporterUid: "c", createdAtMs: NOW }),
    ],
  ];

  for (const reports of scenarios) {
    const rebuilt = evaluateZone(reports, NOW);
    // Replay the same reports through the incremental path.
    const incremental = {};
    for (const r of reports) {
      incremental[r.reporterUid] = Math.max(incremental[r.reporterUid] || 0, r.createdAtMs);
    }
    assert.equal(flagFor(incremental, NOW), rebuilt.flag);
  }
});

test("buildZones carries the reporter set the trigger needs", () => {
  const zones = buildZones(
    [report({ reporterUid: "a" }), report({ reporterUid: "b" }), report({ reporterUid: "a" })],
    NOW,
  );
  assert.deepEqual(zones[0].reporterUids.sort(), ["a", "b"]);
  assert.equal(zones[0].reportCount, 3);
  assert.equal(zones[0].distinctReporters, 2);
});

test("notorious hotspots are derived from the crime table, not hand-listed", () => {
  const {
    THANA_CRIME_SEED,
    isNotoriousHotspot,
    HOTSPOT_DENSITY_THRESHOLD,
  } = require("../data/dhaka_thana_crime_seed");

  const hotspots = THANA_CRIME_SEED.filter(isNotoriousHotspot);

  // Paltan is the source table's one genuine statistical outlier: 29.77
  // crimes/km2, ~3.1 sigma above the mean and nearly double the next thana.
  assert.deepEqual(hotspots.map((t) => t.thanaName), ["Paltan"]);

  // The module plan's own illustrative example is "specific alleys in
  // Mirpur" — the source data does not support it (4.64/km2, below the city
  // mean). Guarding against anyone quietly adding it back by hand.
  const mirpur = THANA_CRIME_SEED.find((t) => t.thanaName === "Mirpur");
  assert.ok(!isNotoriousHotspot(mirpur), "Mirpur is not an outlier in the source data");

  // Interpolated entries are neighbour guesses; a 5x multiplier on a guess
  // compounds it rather than flagging a fact.
  for (const entry of THANA_CRIME_SEED) {
    if (entry.dataSource !== "estimated_2009_academic") {
      assert.ok(!isNotoriousHotspot(entry), `${entry.thanaName} is interpolated and must not be a hotspot`);
    }
  }

  assert.ok(HOTSPOT_DENSITY_THRESHOLD > 20, "threshold should be well above the bulk of the distribution");
});

test("the stored-document hotspot rule agrees with the density rule exactly", () => {
  // `checkRouteSafety` reads zones from Firestore, where the raw density is
  // not kept — so it derives the flag from `baseCrimeScore` + `dataSource`.
  // That derivation is what lets the rule take effect on deploy with no
  // re-seed, and it is only safe while it selects the same thanas.
  const {
    THANA_CRIME_SEED,
    densityToScore,
    isNotoriousHotspot,
    isHotspotZone,
  } = require("../data/dhaka_thana_crime_seed");

  for (const entry of THANA_CRIME_SEED) {
    const storedDoc = {
      dataSource: entry.dataSource,
      baseCrimeScore: densityToScore(entry.densityEstimate),
    };
    assert.equal(
      isHotspotZone(storedDoc),
      isNotoriousHotspot(entry),
      `${entry.thanaName} is classified differently by the two rules`,
    );
  }
});

test("a zone document with an explicit flag is trusted over the derivation", () => {
  const { isHotspotZone } = require("../data/dhaka_thana_crime_seed");
  // A fresher seed may know something the score alone cannot express.
  assert.equal(isHotspotZone({ notoriousHotspot: true, dataSource: "x", baseCrimeScore: 1 }), true);
  assert.equal(isHotspotZone({ notoriousHotspot: false, dataSource: "estimated_2009_academic", baseCrimeScore: 10 }), false);
});

test("interpolated zones are never hotspots, however high their score", () => {
  const { isHotspotZone } = require("../data/dhaka_thana_crime_seed");
  assert.equal(
    isHotspotZone({ dataSource: "estimated_neighbor_interpolation", baseCrimeScore: 10 }),
    false,
    "a 5x multiplier applied to a neighbour guess compounds the guess",
  );
});

test("a malformed or missing zone does not crash the safety check", () => {
  const { isHotspotZone } = require("../data/dhaka_thana_crime_seed");
  assert.equal(isHotspotZone(null), false);
  assert.equal(isHotspotZone({}), false);
});
