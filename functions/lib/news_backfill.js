/**
 * Builds a per-thana crime baseline out of dated, citable news reporting,
 * so the 2009 academic table stops being the app's idea of Dhaka's geography.
 *
 * ## Why this replaces the seed rather than supplementing it
 *
 * `dhaka_thana_crime_seed.js` is three months of DMP figures from 2009,
 * reproduced from a 2011 paper. It is honest and citable and seventeen years
 * old, and nothing can refresh it: **no public source publishes crime broken
 * down by Dhaka thana.** DMP's own monthly table is citywide totals — checked
 * by reading the published scan.
 *
 * Published reporting is the only per-neighbourhood signal that exists. This
 * module turns it into one.
 *
 * ## Months with evidence, never article counts
 *
 * Raw volume must not become a score. Measured across thanas, article counts
 * run 29-71 and cluster around 49, which is Google's relevance cap rather
 * than a measurement — and more importantly volume encodes *newsworthiness*:
 * central and affluent areas are covered more, so a volume-ranked map would
 * call Gulshan dangerous and a poor peripheral thana safe. That is precisely
 * the harm `thana_advisory.js` is structured to refuse.
 *
 * So this counts **distinct months in which a credible crime report named the
 * thana**, which is what `learned_baseline.js` already consumes. A thana needs
 * one article in a month, not many, which damps the attention bias hard and
 * makes the result cap irrelevant — presence per month saturates either way.
 *
 * ## Why it cannot run in a Cloud Function
 *
 * Google News RSS returns **HTTP 503 to Cloud Functions**, consistently,
 * probed from a deployed function in `us-central1` on 2026-09-16. It answers
 * an ordinary connection perfectly. That is the third time this project has
 * hit a datacenter-IP block (`police.gov.bd`, and `dmp.gov.bd`'s earlier bot
 * wall), so the shape is familiar: this module is deliberately
 * **Firebase-free** and runs from wherever has access, writing through the
 * `recordThanaIncident` callable — the same split
 * `crime_report_ingestion.js` already uses.
 *
 * ## What this is honestly weak at
 *
 * A thana nobody reports on scores low. Media attention is not incidence, and
 * counting months damps that bias without removing it. The difference from
 * the 2009 table is that this weakness can be *described and dated*, and every
 * month of evidence traces to a URL.
 */

const { THANA_CRIME_SEED } = require("../data/dhaka_thana_crime_seed");
const {
  CRIME_TERMS,
  EXCLUSION_TERMS,
  thanaSlug,
  looksLikeStreetCrime,
  parseRssItems,
} = require("./news_ingestion");

/**
 * How far back to gather. Matches `learned_baseline.WINDOW_MONTHS` — evidence
 * older than the window is discarded there anyway, so fetching more would be
 * work whose results are thrown away.
 */
const BACKFILL_WINDOW_MONTHS = 24;

/** Between queries, so 41 thanas do not look like a scraper. */
const QUERY_SPACING_MS = 1500;

const CRIME_QUERY = "(mugging OR robbery OR snatching OR murder OR dacoity OR extortion OR stabbed)";

/** Every thana, with the slug `crimeZones` documents are keyed by. */
function allThanas() {
  return THANA_CRIME_SEED.map((t) => ({ slug: thanaSlug(t.thanaName), name: t.thanaName }));
}

function queryUrlFor(thanaName) {
  const q = `${thanaName} Dhaka ${CRIME_QUERY}`;
  return `https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-BD&gl=BD&ceid=BD:en`;
}

/** `YYYY-MM` in Dhaka's fixed UTC+6 offset, matching the baseline's clock. */
function periodOf(ms) {
  return new Date(ms + 6 * 60 * 60 * 1000).toISOString().slice(0, 7);
}

/**
 * The incidents one thana's search results justify.
 *
 * Deliberately **one incident per month**, not per article. The baseline
 * counts months, so twenty stories in March and one in April are two months
 * either way — and keeping only the first of each month means a single
 * heavily-covered event cannot outweigh a quieter month in which something
 * genuinely happened.
 */
function incidentsFrom(items, thana, nowMs) {
  const cutoff = nowMs - BACKFILL_WINDOW_MONTHS * 31 * 24 * 60 * 60 * 1000;
  const byMonth = new Map();

  for (const item of items) {
    const text = `${item.title || ""} ${item.description || ""}`;
    if (!looksLikeStreetCrime(text)) continue;
    // Google News titles carry the outlet after a dash — "… - The Daily Star".
    // The thana name has to appear in the story itself, not merely in the
    // query that produced it: Google returns loosely-related results, and an
    // article about somewhere else would otherwise be filed under this thana.
    if (!new RegExp(`(^|[^a-z])${thana.name.toLowerCase()}([^a-z]|$)`).test(text.toLowerCase())) continue;

    const url = String(item.link || "").trim();
    if (!/^https?:\/\/\S+$/.test(url)) continue;
    const publishedAtMs = Date.parse(item.pubDate || "");
    if (Number.isNaN(publishedAtMs)) continue;
    if (publishedAtMs < cutoff) continue;
    if (publishedAtMs > nowMs + 24 * 60 * 60 * 1000) continue;

    const period = periodOf(publishedAtMs);
    const existing = byMonth.get(period);
    // Earliest article in the month wins, so re-running the backfill produces
    // the same set rather than drifting with Google's ordering.
    if (!existing || publishedAtMs < existing.publishedAtMs) {
      byMonth.set(period, {
        thanaSlug: thana.slug,
        sourceUrl: url,
        publishedAt: new Date(publishedAtMs).toISOString(),
        publishedAtMs,
        headline: String(item.title || "").slice(0, 300),
        period,
      });
    }
  }
  return [...byMonth.values()].sort((a, b) => a.publishedAtMs - b.publishedAtMs);
}

/** Fetches and parses one thana's search results. */
async function fetchThanaIncidents(thana, nowMs = Date.now(), fetchImpl = fetch) {
  const res = await fetchImpl(queryUrlFor(thana.name), {
    redirect: "follow",
    headers: { "User-Agent": "Mozilla/5.0 (compatible; ANT-research/1.0)" },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return incidentsFrom(parseRssItems(await res.text()), thana, nowMs);
}

/**
 * Walks every thana and returns what the corpus supports.
 *
 * Never throws on one thana's failure: a backfill that abandons the whole
 * city because one query was rate-limited is a backfill nobody can finish.
 */
async function collectBackfill({
  nowMs = Date.now(),
  fetchImpl = fetch,
  onProgress = () => {},
  spacingMs = QUERY_SPACING_MS,
} = {}) {
  const results = [];
  const errors = [];
  for (const thana of allThanas()) {
    try {
      const incidents = await fetchThanaIncidents(thana, nowMs, fetchImpl);
      results.push({ thana, incidents });
      onProgress(thana, incidents.length, null);
    } catch (e) {
      errors.push(`${thana.name}: ${e.message}`);
      onProgress(thana, 0, e.message);
    }
    if (spacingMs) await new Promise((r) => setTimeout(r, spacingMs));
  }
  return { results, errors };
}

module.exports = {
  BACKFILL_WINDOW_MONTHS,
  CRIME_QUERY,
  CRIME_TERMS,
  EXCLUSION_TERMS,
  allThanas,
  queryUrlFor,
  periodOf,
  incidentsFrom,
  fetchThanaIncidents,
  collectBackfill,
};
