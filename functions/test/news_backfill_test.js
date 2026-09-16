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

test("one incident per month, not per article", () => {
  // The baseline counts months. Twenty stories in one month and one in the
  // next is two months either way — and keeping only one per month stops a
  // single heavily-covered event outweighing a quieter month in which
  // something genuinely happened.
  const incidents = incidentsFrom([
    item({ link: "https://x.com/1", pubDate: "Tue, 01 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/2", pubDate: "Wed, 09 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/3", pubDate: "Thu, 10 Sep 2026 10:00:00 +0600" }),
    item({ link: "https://x.com/4", pubDate: "Fri, 01 Aug 2026 10:00:00 +0600" }),
  ], MOHAMMADPUR, NOW);

  assert.strictEqual(incidents.length, 2);
  assert.deepStrictEqual(incidents.map((i) => i.period), ["2026-08", "2026-09"]);
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
