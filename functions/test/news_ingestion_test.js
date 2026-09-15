/**
 * The news pipeline that feeds `thana_advisory.js`.
 *
 * Almost every test here is about **refusing** something. This is the only
 * path by which an outside claim about a real Dhaka neighbourhood can reach a
 * routing decision that a blind user cannot see or argue with, so the
 * interesting behaviour is not what it accepts.
 */

const test = require("node:test");
const assert = require("node:assert");

const {
  LANDMARK_TO_THANA,
  thanaSlug,
  resolveThana,
  looksLikeStreetCrime,
  severityFor,
  parseRssItems,
  advisoryFrom,
} = require("../lib/news_ingestion");
const { THANA_CRIME_SEED } = require("../data/dhaka_thana_crime_seed");
const { validateAdvisory } = require("../lib/thana_advisory");

const REAL_SLUGS = new Set(THANA_CRIME_SEED.map((t) => thanaSlug(t.thanaName)));
const REAL_NAMES = new Set(THANA_CRIME_SEED.map((t) => t.thanaName.toLowerCase()));

test("every landmark points at a thana that exists", () => {
  // A target outside the 41 is refused by `recordThanaAdvisory` — but only
  // after the article has been counted as understood, so the loss is silent.
  // Mohakhali was caught this way: it sits in Banani thana, which is not in
  // the DMP seed at all.
  for (const [landmark, slug] of Object.entries(LANDMARK_TO_THANA)) {
    assert.ok(REAL_SLUGS.has(slug), `"${landmark}" points at unknown thana "${slug}"`);
  }
});

test("no landmark is itself a thana", () => {
  // This is the subtler one. Kalabagan, Rampura, Shahbagh and Uttara are all
  // thanas in their own right; listing them as landmarks pointing elsewhere
  // makes an article about them resolve to *two* slugs, which the ambiguity
  // guard then refuses. The result is not a wrong answer but total, silent
  // loss of coverage for that neighbourhood.
  for (const landmark of Object.keys(LANDMARK_TO_THANA)) {
    assert.ok(!REAL_NAMES.has(landmark), `"${landmark}" is a thana and must not be a landmark key`);
  }
});

test("a thana named plainly resolves", () => {
  assert.strictEqual(resolveThana("Youth mugged in Mohammadpur last night"), "mohammadpur");
  assert.strictEqual(resolveThana("Robbery in Kalabagan"), "kalabagan");
});

test("a landmark resolves to the thana containing it", () => {
  // Articles name the place people know, not the administrative unit.
  assert.strictEqual(resolveThana("Snatching spree at Farmgate"), "tejgaon");
  assert.strictEqual(resolveThana("Mugging near Science Lab"), "dhanmondi");
});

test("two thanas in one article resolves to nothing", () => {
  // Usually a citywide roundup. Attributing it to whichever was mentioned
  // first is how a neighbourhood acquires a label it did not earn.
  assert.strictEqual(resolveThana("Muggings reported in Mohammadpur and Mirpur"), null);
});

test("a place outside Dhaka resolves to nothing", () => {
  assert.strictEqual(resolveThana("Robbery in Chattogram"), null);
  assert.strictEqual(resolveThana("Dacoity in Sylhet town"), null);
});

test("street crime is recognised; other news is not", () => {
  assert.ok(looksLikeStreetCrime("Youth mugged at knifepoint"));
  assert.ok(looksLikeStreetCrime("Miscreants snatched a phone"));
  // A road accident, a court verdict or a dengue story tells a pedestrian
  // nothing about whether to walk down a road.
  assert.ok(!looksLikeStreetCrime("Three killed in road accident"));
  assert.ok(!looksLikeStreetCrime("Court sentenced him for murder"));
  assert.ok(!looksLikeStreetCrime("Dengue cases rise in the capital"));
});

test("a historical piece is not current evidence", () => {
  // An anniversary retrospective describes a place's past, and would
  // otherwise read as a fresh report of whatever it describes.
  assert.ok(!looksLikeStreetCrime("The murder that shook Dhanmondi 30 years ago"));
});

test("one article can never reach severe", () => {
  // `severe` promotes a thana to notorious-hotspot temporal behaviour, which
  // is a standing claim about a neighbourhood. One article is a news cycle;
  // a place that genuinely deteriorates accumulates evidence months through
  // learned_baseline, which is deliberately slow.
  assert.strictEqual(severityFor("man stabbed to death in a mugging"), "high");
  assert.strictEqual(severityFor("phone snatched from a rickshaw"), "elevated");
  for (const text of ["murder", "gunned down", "snatching", "robbery at gunpoint"]) {
    assert.notStrictEqual(severityFor(text), "severe");
  }
});

test("an advisory built from a feed item satisfies the real validator", () => {
  // The end-to-end contract: whatever this produces has to pass the same
  // check every other write path goes through.
  const now = Date.parse("2026-09-16T10:00:00Z");
  const advisory = advisoryFrom({
    title: "Youth mugged at knifepoint in Mohammadpur",
    description: "Miscreants snatched his phone near Lalmatia.",
    link: "https://www.thedailystar.net/news/example-123",
    pubDate: "Mon, 15 Sep 2026 18:30:00 +0600",
  }, "The Daily Star", now);

  assert.ok(advisory, "should produce an advisory");
  assert.strictEqual(advisory.thanaSlug, "mohammadpur");
  assert.strictEqual(advisory.sourceTier, "news");
  assert.strictEqual(validateAdvisory(advisory), null);
});

test("provenance is mandatory", () => {
  const now = Date.parse("2026-09-16T10:00:00Z");
  const base = {
    title: "Youth mugged in Mohammadpur",
    description: "",
    link: "https://www.thedailystar.net/news/x",
    pubDate: "Mon, 15 Sep 2026 18:30:00 +0600",
  };
  // An item that cannot supply a real URL or a real date is not admissible
  // evidence, whatever it says.
  assert.strictEqual(advisoryFrom({ ...base, link: "" }, "X", now), null);
  assert.strictEqual(advisoryFrom({ ...base, link: "not-a-url" }, "X", now), null);
  assert.strictEqual(advisoryFrom({ ...base, pubDate: "" }, "X", now), null);
});

test("stale and future-dated articles are refused", () => {
  const now = Date.parse("2026-09-16T10:00:00Z");
  const base = {
    title: "Youth mugged in Mohammadpur",
    description: "",
    link: "https://www.thedailystar.net/news/x",
  };
  assert.strictEqual(advisoryFrom({ ...base, pubDate: "Mon, 01 Jan 2026 10:00:00 +0600" }, "X", now), null);
  // A feed with a broken clock, not tomorrow's news.
  assert.strictEqual(advisoryFrom({ ...base, pubDate: "Mon, 01 Jan 2027 10:00:00 +0600" }, "X", now), null);
});

test("RSS items parse, including CDATA and entities", () => {
  const xml = `<rss><channel>
    <item><title><![CDATA[Mugged in Mohammadpur]]></title>
      <link>https://example.com/a</link>
      <description>Phone &amp; wallet taken</description>
      <pubDate>Mon, 15 Sep 2026 18:30:00 +0600</pubDate></item>
    <item><title>Second story</title><link>https://example.com/b</link>
      <description>x</description><pubDate>Mon, 15 Sep 2026 19:00:00 +0600</pubDate></item>
  </channel></rss>`;
  const items = parseRssItems(xml);
  assert.strictEqual(items.length, 2);
  assert.strictEqual(items[0].title, "Mugged in Mohammadpur");
  assert.strictEqual(items[0].description, "Phone & wallet taken");
  assert.strictEqual(items[1].link, "https://example.com/b");
});
