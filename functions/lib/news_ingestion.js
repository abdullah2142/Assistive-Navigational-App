/**
 * Reads Bangladeshi news for crime reporting that names a Dhaka thana, so
 * `thana_advisory.js` has something current to work from.
 *
 * ## Why this exists
 *
 * The per-thana baseline is a 2009 academic table. It can say which
 * neighbourhoods carried more street crime seventeen years ago and nothing
 * about which have deteriorated since, and **no public source publishes crime
 * broken down by Dhaka thana** — DMP's own monthly table is citywide totals
 * only, confirmed by reading the published scan. Published reporting is the
 * only per-neighbourhood signal available, which is why the advisory and
 * learned-baseline layers were built to accept it.
 *
 * They were built and nothing ever fed them. `recordThanaAdvisory` is a
 * callable with no caller, and the hourly decay job has been reporting
 * "0 thanas gained an evidence month" ever since. This is the caller.
 *
 * ## Outlets, and why these ones
 *
 * Probed from inside a deployed Cloud Function in `us-central1` on
 * 2026-09-16, because reachability from a laptop proves nothing about
 * reachability from the runtime that will actually do the fetching —
 * `police.gov.bd` answers an ordinary connection and times out from GCP.
 *
 *     200  The Daily Star   RSS
 *     200  Prothom Alo EN   section page
 *     200  TBS News         RSS
 *     403  Dhaka Tribune    bot-blocked
 *     403  bdnews24         bot-blocked
 *     403  New Age          bot-blocked
 *
 * The 403s block an ordinary browser too, so they are a publisher's decision
 * rather than a GCP-specific one, and are left alone rather than evaded.
 *
 * ## What this deliberately does not do
 *
 * **It does not touch social media.** The tiering in `thana_advisory.js`
 * supports it and `social_signal.js` is written, but rumour propagates faster
 * than correction, attaches disproportionately to poorer areas, and this app
 * converts what it believes directly into "will not walk you through there"
 * for someone who cannot see the map to disagree. Published reporting first,
 * with a name and a date attached; the social tier can wait until the news
 * tier is demonstrably behaving.
 *
 * **It never lowers risk.** An advisory can only raise a score, and expires
 * on its own. Nothing here can talk the app into believing a place is safer
 * than the sourced baseline says.
 */

const { THANA_CRIME_SEED } = require("../data/dhaka_thana_crime_seed");

/**
 * Feeds that answered from Cloud Functions, section-scoped where a section
 * exists.
 *
 * The front-page feeds carry 8-10 general headlines and almost never a
 * neighbourhood crime story — a live run against them produced nothing at
 * all, which is what sent this looking for sections. The crime and city
 * sections carry 20 each and are the right population to filter.
 *
 * The Daily Star's city feed is reached through a taxonomy id rather than a
 * readable path (`/city/rss.xml` 301s to it). That is brittle by nature, so a
 * source that stops returning items is logged and skipped rather than
 * allowed to fail the run.
 */
const NEWS_SOURCES = [
  { name: "TBS News", url: "https://www.tbsnews.net/bangladesh/crime/rss.xml" },
  { name: "TBS News", url: "https://www.tbsnews.net/bangladesh/rss.xml" },
  { name: "The Daily Star", url: "https://www.thedailystar.net/taxonomy/term/109/rss.xml" },
  { name: "The Daily Star", url: "https://www.thedailystar.net/rss.xml" },
];

/**
 * Words that make an article about crime rather than about anything else.
 *
 * Deliberately about *street* crime against a person. A fraud case or a
 * political arrest tells a pedestrian nothing about whether to walk down a
 * road, and treating them as risk evidence would label neighbourhoods for
 * having courts and government offices in them.
 */
const CRIME_TERMS = [
  "mugging", "mugged", "snatching", "snatched", "robbery", "robbed", "robber",
  "dacoity", "dacoit", "stabbed", "stabbing", "assault", "assaulted",
  "murder", "murdered", "killed", "shot dead", "gunned down",
  "extortion", "hijack", "hijacked", "kidnap", "kidnapped", "abducted",
  "gang", "miscreants", "held at knifepoint", "knifepoint", "gunpoint",
];

/** Terms that mean the article is not about a street-crime risk at all. */
const EXCLUSION_TERMS = [
  "road accident", "road crash", "bus crash", "train", "ferry", "launch capsize",
  "fire service", "building collapse", "dengue", "election", "verdict", "court",
  "tribunal", "sentenced", "acquitted", "cricket", "football",
  // Historical or anniversary pieces describe a place's past, not its present.
  "years ago", "anniversary", "liberation war", "1971",
];

/** Every thana, with the slug `crimeZones` documents are keyed by. */
function thanaSlug(name) {
  return name.toLowerCase().trim().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
}

const THANAS = THANA_CRIME_SEED.map((t) => ({
  slug: thanaSlug(t.thanaName),
  en: t.thanaName,
  bn: t.thanaNameBn,
}));

/**
 * Neighbourhood and landmark names that are not thanas, mapped to the thana
 * that contains them.
 *
 * Articles name the place people know — "Farmgate", "Karwan Bazar", "Gulshan
 * 2" — not the administrative unit. Without this almost every relevant story
 * resolves to nothing.
 *
 * Only unambiguous, well-known containments are listed. Anything a reasonable
 * person could place in two thanas is left out on purpose: a wrong
 * attribution puts a lasting label on a real neighbourhood, and a missed
 * article costs only that article.
 *
 * Two entries must never appear here, and both were caught by the assertion
 * in this module's tests rather than by reading:
 *
 * - **A name that is itself a thana.** Kalabagan, Rampura, Shahbagh and
 *   Uttara are all thanas in their own right. Listing them as landmarks
 *   pointing elsewhere makes every article about them resolve to *two*
 *   slugs, which the ambiguity guard then refuses — so the effect is not a
 *   wrong answer but a silent, total loss of coverage for that
 *   neighbourhood.
 * - **A target that is not one of the 41.** Mohakhali sits in Banani thana,
 *   which is not in the DMP seed at all, so there is no honest slug to point
 *   it at and it is simply absent. `recordThanaAdvisory` would refuse the
 *   write anyway — correctly — but it would refuse it after the article had
 *   been counted as understood.
 */
const LANDMARK_TO_THANA = {
  "farmgate": "tejgaon",
  "karwan bazar": "tejgaon",
  "kawran bazar": "tejgaon",
  "panthapath": "tejgaon",
  "science lab": "dhanmondi",
  "zigatola": "dhanmondi",
  "jigatola": "dhanmondi",
  "satmasjid road": "dhanmondi",
  "lalmatia": "mohammadpur",
  "shyamoli": "sher-e-bangla-nagar",
  "agargaon": "sher-e-bangla-nagar",
  "nilkhet": "new-market",
  "azimpur": "lalbagh",
  "bangla motor": "ramna",
  "banglamotor": "ramna",
  "bailey road": "ramna",
  "moghbazar": "ramna",
  "mogbazar": "ramna",
  "malibagh": "ramna",
  "gulistan": "paltan",
  "purana paltan": "paltan",
  "kamalapur": "motijheel",
  "arambagh": "motijheel",
  "banani": "gulshan",
  "baridhara": "gulshan",
  "bashundhara": "badda",
  "sayedabad": "jatrabari",
  "gabtoli": "darus-salam",

  // Spelling variants the press actually uses. Newspapers romanise Bangla
  // place names inconsistently — "Gandaria mason murder" was a live story
  // that resolved to nothing because the seed spells the thana "Gendaria".
  // Listed explicitly rather than solved with fuzzy matching: an edit-distance
  // rule over 41 short names would start pairing genuinely different thanas,
  // and a wrong attribution here is durable in a way a miss is not.
  "gandaria": "gendaria",
  "chawkbazar": "chak-bazar",
  "chalk bazar": "chak-bazar",
  "kamrangirchar": "kamrangir-char",
  "sherebangla nagar": "sher-e-bangla-nagar",
  "shere bangla nagar": "sher-e-bangla-nagar",
  "darussalam": "darus-salam",
  "dakshin khan": "dakshinkhan",
  "uttarkhan": "uttar-khan",
};

const BENGALI_RANGE = /[ঀ-৿]/;

/**
 * Which thana an article is about, or null.
 *
 * Returns null on any ambiguity, and that is the important behaviour. An
 * article naming two thanas is usually a citywide roundup, and attributing it
 * to whichever was mentioned first is how a neighbourhood acquires a label it
 * did not earn. Evidence that is not clearly about one place is not evidence.
 */
function resolveThana(text) {
  const haystack = ` ${String(text || "").toLowerCase()} `;
  const found = new Set();

  for (const thana of THANAS) {
    const en = thana.en.toLowerCase();
    // Word-bounded: "Badda" must not match inside "Baddah Road", and more to
    // the point "Demra" must not match inside a longer unrelated word.
    if (new RegExp(`(^|[^a-z])${escapeRegExp(en)}([^a-z]|$)`).test(haystack)) found.add(thana.slug);
    if (thana.bn && BENGALI_RANGE.test(text || "") && String(text).includes(thana.bn)) found.add(thana.slug);
  }
  for (const [landmark, slug] of Object.entries(LANDMARK_TO_THANA)) {
    if (haystack.includes(` ${landmark} `) || haystack.includes(` ${landmark},`)) found.add(slug);
  }

  return found.size === 1 ? [...found][0] : null;
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Whether an article is about street crime against a person in Dhaka. */
function looksLikeStreetCrime(text) {
  const lower = String(text || "").toLowerCase();
  if (EXCLUSION_TERMS.some((term) => lower.includes(term))) return false;
  return CRIME_TERMS.some((term) => lower.includes(term));
}

/**
 * Severity from a single article, capped at `high`.
 *
 * `severe` is never assigned here, and that cap is the point rather than
 * caution for its own sake: severe promotes a thana to notorious-hotspot
 * temporal behaviour, which is a standing claim about a neighbourhood. One
 * article is a news cycle. A place that genuinely deteriorates accumulates
 * evidence months through `learned_baseline.js`, which is the mechanism built
 * for exactly this and is deliberately slow.
 */
function severityFor(text) {
  const lower = String(text || "").toLowerCase();
  const violent = ["murder", "murdered", "killed", "shot dead", "gunned down", "stabbed", "gunpoint", "knifepoint"];
  return violent.some((term) => lower.includes(term)) ? "high" : "elevated";
}

/** Minimal RSS parsing — title, link, description, pubDate per item. */
function parseRssItems(xml) {
  const items = [];
  const blocks = String(xml).split(/<item[\s>]/i).slice(1);
  for (const block of blocks) {
    const body = block.split(/<\/item>/i)[0];
    items.push({
      title: unwrap(firstTag(body, "title")),
      link: unwrap(firstTag(body, "link")),
      description: unwrap(firstTag(body, "description")),
      pubDate: unwrap(firstTag(body, "pubDate")),
    });
  }
  return items;
}

function firstTag(xml, tag) {
  const m = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)</${tag}>`, "i").exec(xml);
  return m ? m[1] : "";
}

function unwrap(value) {
  return String(value || "")
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/<[^>]+>/g, " ")
    .replace(/&amp;/g, "&").replace(/&#039;/g, "'").replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** How recent an article has to be to count as current reporting. */
const MAX_ARTICLE_AGE_MS = 21 * 24 * 60 * 60 * 1000;

/**
 * Turns one feed item into an advisory, or null.
 *
 * Every rejection here is deliberate: not crime, not one identifiable thana,
 * not recent, or missing the provenance `validateAdvisory` requires. A feed
 * item that cannot supply a URL and a date is not admissible evidence no
 * matter what it says.
 */
function advisoryFrom(item, sourceName, nowMs = Date.now()) {
  const text = `${item.title || ""} ${item.description || ""}`;
  if (!text.trim()) return null;
  if (!looksLikeStreetCrime(text)) return null;

  const slug = resolveThana(text);
  if (!slug) return null;

  const url = String(item.link || "").trim();
  if (!/^https?:\/\/\S+$/.test(url)) return null;

  const published = Date.parse(item.pubDate || "");
  if (Number.isNaN(published)) return null;
  if (nowMs - published > MAX_ARTICLE_AGE_MS) return null;
  // A publication date in the future is a feed with a broken clock, not
  // tomorrow's news.
  if (published > nowMs + 24 * 60 * 60 * 1000) return null;

  return {
    thanaSlug: slug,
    severity: severityFor(text),
    sourceTier: "news",
    sourceUrl: url,
    sourceTitle: `${sourceName}: ${item.title}`.slice(0, 300),
    publishedAt: new Date(published).toISOString(),
  };
}

/** Fetches every reachable feed and returns the advisories they justify. */
async function collectAdvisories(nowMs = Date.now(), fetchImpl = fetch) {
  const advisories = [];
  const errors = [];
  for (const source of NEWS_SOURCES) {
    try {
      const res = await fetchImpl(source.url, {
        redirect: "follow",
        headers: { "User-Agent": "Mozilla/5.0 (compatible; ANT/1.0)" },
      });
      if (!res.ok) {
        errors.push(`${source.name}: HTTP ${res.status}`);
        continue;
      }
      for (const item of parseRssItems(await res.text())) {
        const advisory = advisoryFrom(item, source.name, nowMs);
        if (advisory) advisories.push(advisory);
      }
    } catch (e) {
      errors.push(`${source.name}: ${e.message}`);
    }
  }
  // One advisory per source URL. The same story syndicated twice is one piece
  // of evidence, and `recordThanaAdvisory` keys on the URL anyway.
  const seen = new Set();
  const unique = advisories.filter((a) => (seen.has(a.sourceUrl) ? false : seen.add(a.sourceUrl)));
  return { advisories: unique, errors };
}

module.exports = {
  NEWS_SOURCES,
  CRIME_TERMS,
  EXCLUSION_TERMS,
  LANDMARK_TO_THANA,
  MAX_ARTICLE_AGE_MS,
  thanaSlug,
  resolveThana,
  looksLikeStreetCrime,
  severityFor,
  parseRssItems,
  advisoryFrom,
  collectAdvisories,
};
