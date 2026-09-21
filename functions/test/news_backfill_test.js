/**
 * The per-thana baseline rebuilt from news, replacing the 2009 seed.
 *
 * The tests that matter here are about what does *not* become evidence. This
 * decides which Dhaka neighbourhoods the app will route a blind user around,
 * from a corpus nobody curated.
 */

const test = require("node:test");
const assert = require("node:assert");

const {
  allThanas,
  queryUrlFor,
  periodOf,
  incidentsFrom,
  collectBackfill,
  BACKFILL_WINDOW_MONTHS,
} = require("../lib/news_backfill");
const { WINDOW_MONTHS, MIN_EVIDENCE_MONTHS } = require("../lib/learned_baseline");

const NOW = Date.parse("2026-09-16T12:00:00Z");
const MOHAMMADPUR = { slug: "mohammadpur", name: "Mohammadpur" };

function item(overrides = {}) {
  return {
    title: "Youth mugged at knifepoint in Mohammadpur",
    description: "Miscreants snatched his phone.",
    link: "https://www.thedailystar.net/a",
    pubDate: "Mon, 01 Sep 2026 10:00:00 +0600",
    ...overrides,
  };
}

test("the backfill window matches what the baseline actually keeps", () => {
  // Fetching more would be work whose results learned_baseline discards.
  assert.strictEqual(BACKFILL_WINDOW_MONTHS, WINDOW_MONTHS);
});

test("all 41 thanas are searched", () => {
  assert.strictEqual(allThanas().length, 41);
  assert.ok(queryUrlFor("Mohammadpur").startsWith("https://news.google.com/rss/search?q="));
});

test("at most three incidents per month — enough to corroborate, not enough to rank", () => {
  // This kept ONE per month until 2026-09-21, and the consequence was a
  // ledger that could not produce a single evidence month:
  // `evidenceMonthsFromIncidents` needs three distinct incidents in a month
  // before it counts, so one-per-month never reaches the gate. Measured
  // live before the fix: 107 incidents, 111 (thana, month) cells, zero
  // qualifying, no route score moved.
  const incidents = incidentsFrom([
    item({ link: "https://x.com/1", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/2", pubDate: "Wed, 09 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/3", pubDate: "Thu, 10 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/4", pubDate: "Fri, 11 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/5", pubDate: "Sat, 12 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/6", pubDate: "Fri, 01 Aug 2026 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);

  // Five September stories contribute three; one August story contributes
  // one. The cap is what stops raw article volume — which encodes
  // newsworthiness, not incidence — from ranking neighbourhoods.
  assert.strictEqual(incidents.filter((i) => i.period === "2026-09").length, 3);
  assert.strictEqual(incidents.filter((i) => i.period === "2026-08").length, 1);
  assert.strictEqual(incidents.length, 4);
});

test("a heavily covered month and a barely covered one are still one month each", () => {
  // The property the old one-per-month rule was protecting, kept intact.
  const many = incidentsFrom(
    Array.from({ length: 40 }, (_, i) =>
      item({ link: `https://x.com/${i}`, pubDate: `Tue, 0${(i % 9) + 1} Sep 2026 10:00:00 +0600` })),
    MOHAMMADPUR, NOW,
  );
  const few = incidentsFrom([
    item({ link: "https://y.com/1", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://y.com/2", pubDate: "Wed, 02 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://y.com/3", pubDate: "Thu, 03 Sep 2026 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);

  assert.strictEqual(many.length, few.length, "40 stories must weigh the same as 3");
  assert.strictEqual(new Set(many.map((i) => i.period)).size, 1);
});

test("one article in a month still fails the corroboration gate", () => {
  // The gate the cap must not defeat: a single story is news, not a pattern.
  const { evidenceMonthsFromIncidents } = require("../lib/thana_incident");
  const lonely = incidentsFrom([
    item({ link: "https://x.com/only", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);
  assert.strictEqual(lonely.length, 1);
  assert.deepStrictEqual(evidenceMonthsFromIncidents(lonely, NOW), []);
});

test("three distinct articles in a month do produce an evidence month", () => {
  // End to end across the two modules that disagreed: what the backfill
  // collects must be something the ledger can actually count.
  const { evidenceMonthsFromIncidents } = require("../lib/thana_incident");
  const corroborated = incidentsFrom([
    item({ link: "https://x.com/1", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/2", pubDate: "Wed, 02 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/3", pubDate: "Thu, 03 Sep 2026 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);
  assert.deepStrictEqual(evidenceMonthsFromIncidents(corroborated, NOW), ["2026-09"]);
});

test("the same run twice picks the same article", () => {
  // Earliest in the month wins, so a re-run records the same set rather than
  // drifting with Google's result ordering.
  const items = [
    item({ link: "https://x.com/late", pubDate: "Thu, 10 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/early", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
  ];
  assert.strictEqual(incidentsFrom(items, MOHAMMADPUR, NOW)[0].sourceUrl, "https://x.com/early");
  assert.strictEqual(incidentsFrom([...items].reverse(), MOHAMMADPUR, NOW)[0].sourceUrl, "https://x.com/early");
});

test("an article that does not name the thana is not evidence for it", () => {
  // Google returns loosely-related results for any query. Without this, an
  // article about somewhere else gets filed under whichever thana was
  // searched — which is how a neighbourhood acquires a score it did not earn.
  const incidents = incidentsFrom([
    item({ title: "Youth mugged in Mirpur", description: "Phone snatched." }),
  ], MOHAMMADPUR, NOW);
  assert.strictEqual(incidents.length, 0);
});

test("non-crime coverage is not evidence", () => {
  const incidents = incidentsFrom([
    item({ title: "New park opens in Mohammadpur", description: "Residents welcomed it." }),
    item({ title: "Three killed in road accident in Mohammadpur", description: "" }),
  ], MOHAMMADPUR, NOW);
  assert.strictEqual(incidents.length, 0);
});

test("evidence outside the window is dropped", () => {
  const incidents = incidentsFrom([
    item({ pubDate: "Mon, 01 Jan 2020 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);
  assert.strictEqual(incidents.length, 0);
});

test("a future-dated article is a broken feed clock, not news", () => {
  const incidents = incidentsFrom([
    item({ pubDate: "Mon, 01 Jan 2030 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);
  assert.strictEqual(incidents.length, 0);
});

test("an item without a citable URL is refused", () => {
  // Provenance is the whole basis on which this replaces a cited academic
  // table. An undated or unsourced claim is not an upgrade on 2009.
  assert.strictEqual(incidentsFrom([item({ link: "" })], MOHAMMADPUR, NOW).length, 0);
  assert.strictEqual(incidentsFrom([item({ link: "not-a-url" })], MOHAMMADPUR, NOW).length, 0);
  assert.strictEqual(incidentsFrom([item({ pubDate: "" })], MOHAMMADPUR, NOW).length, 0);
});

test("periods use Dhaka's clock, not UTC", () => {
  // 31 Aug 23:00 UTC is 1 Sep in Dhaka. Filing it under August would put
  // evidence in the wrong month at every month boundary.
  assert.strictEqual(periodOf(Date.parse("2026-08-31T23:00:00Z")), "2026-09");
  assert.strictEqual(periodOf(Date.parse("2026-09-01T05:00:00Z")), "2026-09");
});

test("three months is still what moves the baseline", () => {
  // The backfill's usefulness is defined by this threshold — it exists to get
  // thanas over it with real evidence rather than a 2009 estimate.
  assert.strictEqual(MIN_EVIDENCE_MONTHS, 3);
});

test("one thana failing does not abandon the city", async () => {
  let calls = 0;
  const fetchImpl = async () => {
    calls++;
    if (calls === 2) throw new Error("rate limited");
    return { ok: true, text: async () => "<rss></rss>" };
  };
  const { results, errors } = await collectBackfill({ nowMs: NOW, fetchImpl, spacingMs: 0 });
  assert.strictEqual(errors.length, 1);
  assert.strictEqual(results.length, 40, "the other 40 thanas still return");
});
