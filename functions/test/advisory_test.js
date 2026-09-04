/**
 * Current-risk advisories (news + social) — the layer that lets a
 * neighbourhood which deteriorated since 2009 become visible to routing.
 *
 * These assert the *limits* as hard as the behaviour. This code converts
 * claims about real Dhaka neighbourhoods into "the app will not walk you
 * through there", for a user who cannot see the map and cannot check.
 */

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  validateAdvisory,
  advisoryMultiplier,
  advisoryImpliesHotspot,
  strongestAdvisory,
  SOURCE_SOCIAL,
  SOURCE_NEWS,
  DEFAULT_TTL_MS,
  SOCIAL_TTL_MS,
} = require("../lib/thana_advisory");
const {
  validateSignal,
  deriveAdvisory,
  MIN_DISTINCT_AUTHORS,
  HIGH_SEVERITY_AUTHORS,
  CORROBORATION_WINDOW_MS,
} = require("../lib/social_signal");

const NOW = Date.UTC(2026, 8, 4, 12, 0, 0);
const DAY = 24 * 60 * 60 * 1000;

function advisory(over = {}) {
  return {
    thanaSlug: "mohammadpur",
    severity: "high",
    sourceTier: SOURCE_NEWS,
    sourceUrl: "https://www.thedailystar.net/example",
    sourceTitle: "Snatchings rise in Mohammadpur",
    publishedAt: new Date(NOW).toISOString(),
    ...over,
  };
}

function signal(over = {}) {
  return {
    thanaSlug: "mohammadpur",
    authorHandle: "@someone",
    postUrl: "https://example.com/post/1",
    postedAt: new Date(NOW).toISOString(),
    ...over,
  };
}

test("provenance is mandatory, not merely expected", () => {
  assert.equal(validateAdvisory(advisory()), null);
  assert.match(validateAdvisory(advisory({ sourceUrl: "" })), /sourceUrl/);
  assert.match(validateAdvisory(advisory({ sourceUrl: "not a url" })), /sourceUrl/);
  assert.match(validateAdvisory(advisory({ sourceTitle: "  " })), /sourceTitle/);
  assert.match(validateAdvisory(advisory({ publishedAt: "sometime" })), /publishedAt/);
  assert.match(validateAdvisory(advisory({ thanaSlug: "" })), /thanaSlug/);
  assert.match(validateAdvisory(advisory({ severity: "catastrophic" })), /severity/);
});

test("an advisory can only ever raise risk, never lower it", () => {
  for (const severity of ["elevated", "high", "severe"]) {
    assert.ok(advisoryMultiplier(advisory({ severity }), NOW) >= 1);
  }
  // Expired, malformed and missing all resolve to neutral rather than to
  // anything that could talk the safety engine down.
  assert.equal(advisoryMultiplier(null, NOW), 1);
  assert.equal(advisoryMultiplier(advisory({ publishedAt: "nonsense" }), NOW), 1);
  assert.equal(advisoryMultiplier(advisory(), NOW + DEFAULT_TTL_MS + DAY), 1);
});

test("effect is capped — a news cycle cannot redraw the safety map", () => {
  assert.equal(advisoryMultiplier(advisory({ severity: "severe" }), NOW), 2.0);
  assert.ok(advisoryMultiplier(advisory({ severity: "severe" }), NOW) <= 2.0);
});

test("advisories taper out instead of expiring off a cliff", () => {
  const a = advisory({ severity: "severe" });
  const full = advisoryMultiplier(a, NOW + 10 * DAY);
  const fading = advisoryMultiplier(a, NOW + 52 * DAY);
  const gone = advisoryMultiplier(a, NOW + 61 * DAY);
  assert.equal(full, 2.0);
  assert.ok(fading > 1 && fading < 2.0, `expected a partial multiplier, got ${fading}`);
  assert.equal(gone, 1);
});

test("the strongest live advisory wins, not the newest", () => {
  // A severe advisory from six weeks ago says more about a place than a
  // mild one from yesterday.
  const chosen = strongestAdvisory(
    [
      advisory({ severity: "elevated", publishedAt: new Date(NOW - DAY).toISOString() }),
      advisory({ severity: "severe", publishedAt: new Date(NOW - 40 * DAY).toISOString() }),
    ],
    NOW,
  );
  assert.equal(chosen.severity, "severe");
});

test("only a news source can promote a thana to hotspot behaviour", () => {
  // The heaviest lever in the safety engine (a 5x night multiplier on a
  // real neighbourhood) must not be reachable from social chatter.
  assert.equal(advisoryImpliesHotspot(advisory({ severity: "severe" }), NOW), true);
  assert.equal(
    advisoryImpliesHotspot(advisory({ severity: "severe", sourceTier: SOURCE_SOCIAL }), NOW),
    false,
  );
  assert.equal(advisoryImpliesHotspot(advisory({ severity: "high" }), NOW), false);
});

test("social advisories are capped below the hotspot severity outright", () => {
  assert.match(
    validateAdvisory(advisory({ sourceTier: SOURCE_SOCIAL, severity: "severe" })),
    /social-tier/,
  );
  assert.equal(validateAdvisory(advisory({ sourceTier: SOURCE_SOCIAL, severity: "high" })), null);
});

test("social advisories expire far sooner than news ones", () => {
  const social = advisory({ sourceTier: SOURCE_SOCIAL, severity: "high" });
  assert.equal(advisoryMultiplier(social, NOW + SOCIAL_TTL_MS + DAY), 1);
  // A news advisory of the same age is still live.
  assert.ok(advisoryMultiplier(advisory(), NOW + SOCIAL_TTL_MS + DAY) > 1);
});

test("a social signal needs provenance too", () => {
  assert.equal(validateSignal(signal()), null);
  assert.match(validateSignal(signal({ authorHandle: "" })), /authorHandle/);
  assert.match(validateSignal(signal({ postUrl: "nope" })), /postUrl/);
  assert.match(validateSignal(signal({ postedAt: "whenever" })), /postedAt/);
});

test("one account posting repeatedly corroborates nothing", () => {
  // The exact rule Module 5's Red Flag uses, for the same reason: a single
  // actor must not be able to flag a whole neighbourhood.
  const spam = Array.from({ length: 20 }, (_, i) =>
    signal({ postUrl: `https://example.com/post/${i}` }),
  );
  assert.equal(deriveAdvisory("mohammadpur", spam, NOW), null);
});

test("distinct accounts within the window do corroborate", () => {
  const posts = Array.from({ length: MIN_DISTINCT_AUTHORS }, (_, i) =>
    signal({ authorHandle: `@person${i}`, postUrl: `https://example.com/post/${i}` }),
  );
  const derived = deriveAdvisory("mohammadpur", posts, NOW);
  assert.ok(derived);
  assert.equal(derived.sourceTier, "social");
  assert.equal(derived.severity, "elevated");
  assert.equal(derived.corroboratingAuthors, MIN_DISTINCT_AUTHORS);
  // And whatever it produces must itself be admissible.
  assert.equal(validateAdvisory(derived), null);
});

test("more accounts raise severity, but never past the social cap", () => {
  const posts = Array.from({ length: HIGH_SEVERITY_AUTHORS + 10 }, (_, i) =>
    signal({ authorHandle: `@person${i}`, postUrl: `https://example.com/post/${i}` }),
  );
  const derived = deriveAdvisory("mohammadpur", posts, NOW);
  assert.equal(derived.severity, "high", "a thousand posts is still a thousand posts");
  assert.equal(advisoryImpliesHotspot(derived, NOW), false);
});

test("signals outside the window stop counting", () => {
  const old = Array.from({ length: 5 }, (_, i) =>
    signal({
      authorHandle: `@person${i}`,
      postUrl: `https://example.com/post/${i}`,
      postedAt: new Date(NOW - CORROBORATION_WINDOW_MS - DAY).toISOString(),
    }),
  );
  assert.equal(deriveAdvisory("mohammadpur", old, NOW), null, "a neighbourhood must be able to stop being flagged");
});

test("case and whitespace in a handle do not create a fake second account", () => {
  const posts = [
    signal({ authorHandle: "@Someone", postUrl: "https://example.com/a" }),
    signal({ authorHandle: "@someone ", postUrl: "https://example.com/b" }),
    signal({ authorHandle: "@SOMEONE", postUrl: "https://example.com/c" }),
  ];
  assert.equal(deriveAdvisory("mohammadpur", posts, NOW), null);
});

test("Mohammadpur: the worked case, end to end", () => {
  const { densityToScore, isHotspotZone } = require("../data/dhaka_thana_crime_seed");
  const { temporalMultiplier } = require("../lib/temporal_weighting");

  const zone = {
    thanaName: "Mohammadpur",
    categoryHint: "mixed",
    dataSource: "estimated_2009_academic",
    baseCrimeScore: densityToScore(9.35),
  };
  // The 2009 table alone: not a hotspot, and comfortably "safe" at night.
  assert.equal(isHotspotZone(zone), false);
  const baselineNight = zone.baseCrimeScore * temporalMultiplier(zone.categoryHint, 23);
  assert.ok(baselineNight < 7, `baseline night score ${baselineNight} should be under threshold`);

  // With a severe, sourced news advisory it clears the threshold and
  // adopts hotspot temporal behaviour — which is the whole point.
  const current = advisory({ severity: "severe" });
  const hotspot = isHotspotZone(zone) || advisoryImpliesHotspot(current, NOW);
  assert.equal(hotspot, true);
  const elevated =
    zone.baseCrimeScore *
    temporalMultiplier(zone.categoryHint, 23, { isHotspot: hotspot }) *
    advisoryMultiplier(current, NOW);
  assert.ok(elevated > 7, `advised night score ${elevated} should clear the threshold`);

  // Social chatter alone gets it partway, deliberately not all the way.
  const socialOnly = advisory({ sourceTier: SOURCE_SOCIAL, severity: "high" });
  const socialScore =
    zone.baseCrimeScore *
    temporalMultiplier(zone.categoryHint, 23, {
      isHotspot: advisoryImpliesHotspot(socialOnly, NOW),
    }) *
    advisoryMultiplier(socialOnly, NOW);
  assert.ok(socialScore > baselineNight, "chatter should still move the number");
  assert.ok(socialScore < elevated, "chatter should not reach what sourced reporting does");
});

test("the Worker's thana index has not drifted from the seed", async () => {
  // `cloudflare-worker/src/lib/thana_index.js` is generated from this seed
  // but cannot import it — Workers run on `workerd`, with no Node modules.
  // A drifted slug there would post advisories that match no `crimeZones`
  // document and silently do nothing, which looks exactly like a working
  // pipeline. So the copy is asserted rather than trusted.
  const fs = require("node:fs");
  const path = require("node:path");
  const { THANA_CRIME_SEED } = require("../data/dhaka_thana_crime_seed");

  const generated = path.join(__dirname, "../../cloudflare-worker/src/lib/thana_index.js");
  const source = fs.readFileSync(generated, "utf8");

  const slugify = (n) => n.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");

  for (const entry of THANA_CRIME_SEED) {
    const slug = slugify(entry.thanaName);
    assert.ok(
      source.includes(`slug: '${slug}'`),
      `${entry.thanaName} (${slug}) is missing from the Worker's thana index — regenerate it`,
    );
    assert.ok(
      source.includes(`bn: '${entry.thanaNameBn}'`),
      `${entry.thanaName}'s Bangla name is missing or stale in the Worker's thana index`,
    );
  }

  const generatedCount = (source.match(/slug: '/g) || []).length;
  assert.equal(generatedCount, THANA_CRIME_SEED.length, "the Worker index has extra or missing thanas");
});
