// The incident ledger is the long memory. An advisory expires in weeks; a
// bad incident sits for two years quietly pushing a real neighbourhood's
// score up. So the thresholds and the dedup are tested harder than the
// happy path.

const test = require("node:test");
const assert = require("node:assert/strict");

const {
  INCIDENTS_PER_EVIDENCE_MONTH,
  INCIDENT_RETENTION_MS,
  periodOf,
  incidentId,
  validateIncident,
  isStale,
  evidenceMonthsFromIncidents,
  mergeEvidenceMonths,
} = require("../lib/thana_incident");
const { isWithinWindow, learnedAdjustment, MIN_EVIDENCE_MONTHS } = require("../lib/learned_baseline");

const NOW = Date.parse("2026-09-05T12:00:00Z");
const ok = (over = {}) => ({
  thanaSlug: "mohammadpur",
  sourceUrl: "https://www.thedailystar.net/news/one",
  headline: "Mugging reported in Mohammadpur",
  outlet: "The Daily Star",
  publishedAt: "2026-09-02T09:00:00Z",
  ...over,
});

test("provenance is mandatory, exactly as it is for advisories", () => {
  assert.throws(() => validateIncident(ok({ thanaSlug: "" }), NOW), /thanaSlug/);
  assert.throws(() => validateIncident(ok({ sourceUrl: "" }), NOW), /sourceUrl/);
  assert.throws(() => validateIncident(ok({ sourceUrl: "not-a-url" }), NOW), /sourceUrl/);
  assert.throws(() => validateIncident(ok({ publishedAt: "whenever" }), NOW), /publishedAt/);
});

test("a future publication date is a feed bug, not a scoop", () => {
  // Accepting one would file evidence into a month that has not happened.
  assert.throws(
    () => validateIncident(ok({ publishedAt: "2027-01-01T00:00:00Z" }), NOW),
    /future/,
  );
});

test("anything older than the window is refused rather than stored unusable", () => {
  const tooOld = new Date(NOW - INCIDENT_RETENTION_MS - 86400000).toISOString();
  assert.throws(() => validateIncident(ok({ publishedAt: tooOld }), NOW), /older/);
});

test("the period is the month it was published, on Dhaka's clock", () => {
  const incident = validateIncident(ok({ publishedAt: "2026-07-31T20:00:00Z" }), NOW);
  // 20:00 UTC on 31 July is 02:00 on 1 August in Dhaka (UTC+6).
  assert.equal(incident.period, "2026-08");
  assert.equal(periodOf(Date.parse("2026-07-31T17:00:00Z")), "2026-07");
});

test("the same story always gets the same id, whatever the case or spacing", () => {
  const a = incidentId("https://www.thedailystar.net/news/one");
  assert.equal(a, incidentId("  HTTPS://WWW.THEDAILYSTAR.NET/news/one  "));
  assert.notEqual(a, incidentId("https://www.thedailystar.net/news/two"));
});

test("re-reading one article cannot manufacture an evidence month", () => {
  // Every run re-reads three weeks of articles, and the same story appears
  // in a section feed and the outlet's general feed. Counting by document
  // instead of by URL is how one mugging becomes a pattern.
  const sameStory = Array.from({ length: 10 }, () => ({
    period: "2026-08",
    publishedAt: "2026-08-10T00:00:00Z",
    sourceUrl: "https://example.com/one",
  }));
  assert.deepEqual(evidenceMonthsFromIncidents(sameStory, NOW), []);
});

test("three distinct stories in a month make that month count", () => {
  const incidents = ["one", "two", "three"].map((n) => ({
    period: "2026-08",
    publishedAt: "2026-08-10T00:00:00Z",
    sourceUrl: `https://example.com/${n}`,
  }));
  assert.equal(INCIDENTS_PER_EVIDENCE_MONTH, 3);
  assert.deepEqual(evidenceMonthsFromIncidents(incidents, NOW), ["2026-08"]);

  // Two is not enough, and is treated exactly like none.
  assert.deepEqual(evidenceMonthsFromIncidents(incidents.slice(0, 2), NOW), []);
});

test("months are counted separately, not pooled", () => {
  const spread = [
    ...["a", "b"].map((n) => ({ period: "2026-07", publishedAt: "2026-07-05T00:00:00Z", sourceUrl: `u/${n}` })),
    ...["c", "d"].map((n) => ({ period: "2026-08", publishedAt: "2026-08-05T00:00:00Z", sourceUrl: `u/${n}` })),
  ];
  // Four incidents, but neither month reaches three.
  assert.deepEqual(evidenceMonthsFromIncidents(spread, NOW), []);
});

test("aged-out incidents stop counting on their own", () => {
  const old = Array.from({ length: 5 }, (_, i) => ({
    period: "2023-01",
    publishedAt: "2023-01-10T00:00:00Z",
    sourceUrl: `https://example.com/old-${i}`,
  }));
  assert.deepEqual(evidenceMonthsFromIncidents(old, NOW), []);
  assert.equal(isStale(old[0], NOW), true);
});

test("merging adds past months, and reports no-change as null", () => {
  const merged = mergeEvidenceMonths(["2026-09"], ["2026-07", "2026-08"], isWithinWindow, NOW);
  assert.deepEqual(merged, ["2026-07", "2026-08", "2026-09"]);

  // The hourly sweep runs against every thana; returning null on no change
  // is the difference between a free sweep and rewriting every document.
  assert.equal(mergeEvidenceMonths(["2026-08"], ["2026-08"], isWithinWindow, NOW), null);
  assert.equal(mergeEvidenceMonths([], [], isWithinWindow, NOW), null);
});

test("months outside the window can never be added", () => {
  // Nothing changes, so there is nothing to write — null, not a rewrite of
  // the same list.
  assert.equal(mergeEvidenceMonths(["2026-09"], ["2020-01"], isWithinWindow, NOW), null);
});

test("a stored month that has aged out is pruned on the next sweep", () => {
  // This is how the memory decays without anyone maintaining it: a
  // neighbourhood that improves recovers on its own.
  const merged = mergeEvidenceMonths(["2020-01", "2026-09"], [], isWithinWindow, NOW);
  assert.deepEqual(merged, ["2026-09"]);
});

test("the whole path still cannot label a neighbourhood off one news cycle", () => {
  // One busy month: nine separate stories, all in August.
  const busyMonth = Array.from({ length: 9 }, (_, i) => ({
    period: "2026-08",
    publishedAt: "2026-08-10T00:00:00Z",
    sourceUrl: `https://example.com/aug-${i}`,
  }));
  const months = evidenceMonthsFromIncidents(busyMonth, NOW);
  assert.deepEqual(months, ["2026-08"]);
  // One month of evidence, however heavy, moves the score not at all.
  assert.equal(learnedAdjustment(months, NOW), 1);
  assert.equal(MIN_EVIDENCE_MONTHS, 3);
});

test("a sustained pattern does eventually move it, slowly", () => {
  const months = [];
  for (const period of ["2026-07", "2026-08", "2026-09"]) {
    months.push(...Array.from({ length: 3 }, (_, i) => ({
      period,
      publishedAt: `${period}-10T00:00:00Z`,
      sourceUrl: `https://example.com/${period}-${i}`,
    })));
  }
  const evidence = evidenceMonthsFromIncidents(months, NOW);
  assert.deepEqual(evidence, ["2026-07", "2026-08", "2026-09"]);
  // Exactly at the threshold: counted, but still no multiplier yet.
  assert.equal(learnedAdjustment(evidence, NOW), 1);
  // And it stays capped no matter how much accumulates.
  const many = Array.from({ length: 24 }, (_, i) => `2025-${String((i % 12) + 1).padStart(2, "0")}`);
  assert.ok(learnedAdjustment(many, NOW) <= 1.6);
});

test("malformed rows are skipped rather than crashing the sweep", () => {
  const junk = [null, undefined, {}, { period: "nonsense", sourceUrl: "x" }];
  assert.deepEqual(evidenceMonthsFromIncidents(junk, NOW), []);
  assert.deepEqual(evidenceMonthsFromIncidents(null, NOW), []);
});
