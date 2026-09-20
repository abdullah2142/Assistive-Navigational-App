import { fetchFeed } from '../lib/feed.js';
import { callFunction, USER_AGENT, withAuth } from '../lib/firebase.js';
import { isCandidate } from '../lib/thana_match.js';

/**
 * Collects current, per-thana crime advisories from Bangladeshi news
 * outlets and posts them to `recordThanaAdvisory`.
 *
 * ## What problem this solves
 *
 * `dhaka_thana_crime_seed.js` is from 2009. It is honest about that, and it
 * cannot be anything else — no current source publishes crime broken down
 * by Dhaka thana. The monthly `police.gov.bd` ingest gives one citywide
 * number, which says nothing about *where*. Mohammadpur scores 3.8 in the
 * base table while being, by any current account, considerably worse than
 * that. This collector is the only path by which the routing engine can
 * learn that.
 *
 * ## Feeds
 *
 * All four confirmed reachable and correctly shaped while this was written
 * (`thedailystar.net` returns RSS 2.0 with `<a>` markup inside `<title>`;
 * Prothom Alo's `/feed/` 302s to `/stories.rss`). The crime-justice feed is
 * listed first because it is pre-filtered to the right subject, but the
 * general feeds are kept too — neighbourhood crime frequently runs as city
 * news rather than under a crime desk.
 */
/**
 * The outlets this pipeline cannot fetch directly, reached through Google
 * News instead.
 *
 * ## Why this indirection is worth it
 *
 * Dhaka Tribune, bdnews24 and New Age all return **403 from everywhere** —
 * a publisher bot block, not a datacenter one, so no amount of moving the
 * fetch around fixes it. They are also three of the outlets most likely to
 * run a neighbourhood mugging as local news. Google News aggregates them,
 * and `functions/lib/news_backfill.js` already makes exactly this trade for
 * the per-thana history.
 *
 * ## Why here and not in the Cloud Function
 *
 * Google News RSS returns **503 to Cloud Functions** (probed from a
 * deployed function in `us-central1`, 2026-09-16), which is why
 * `news_backfill.js` is a script you run from a laptop. This Worker is the
 * project's one scheduled, always-on host that is *not* in GCP — the same
 * reason the monthly crime ingest lives here.
 *
 * **Unverified from `workerd` as of 2026-09-21.** Cloudflare's edge is
 * architecturally unlike a GCP VM and has cleared two of these walls
 * already, but this project's own rule is that reachability from a laptop
 * proves nothing. Run `scripts/probe_feeds.mjs` locally to see the filters
 * work, then hit the deployed `/news` endpoint and check the per-feed
 * counts before trusting these. If Google answers 503 here too, `fetchFeed`
 * logs it and returns `[]`, so the four direct feeds carry on exactly as
 * before — this can only add, never subtract.
 *
 * ## Broad queries, not 41 per-thana ones
 *
 * The backfill runs one query per thana because it is a one-off building
 * two years of history. This runs twice a day forever, so it asks two broad
 * questions instead and lets `matchThana` do the locating — same filter
 * every other feed goes through.
 */
const GOOGLE_NEWS_QUERIES = [
  'Dhaka (mugging OR robbery OR snatching OR dacoity OR extortion OR stabbed)',
  'Dhaka (murder OR "gang" OR assault) crime',
];

function googleNewsFeeds() {
  return GOOGLE_NEWS_QUERIES.map((q) => ({
    name: `Google News — ${q.slice(0, 40)}`,
    url: `https://news.google.com/rss/search?q=${encodeURIComponent(q)}&hl=en-BD&gl=BD&ceid=BD:en`,
    // Marks the items that need the title/outlet cleanup below. Google News
    // is a wrapper around other outlets, so its items do not arrive in the
    // same shape a publisher's own feed produces.
    viaGoogleNews: true,
  }));
}

/**
 * Splits Google News's "Headline - The Outlet" title into its two parts.
 *
 * Every Google News title carries the publisher appended after a dash, and
 * leaving it on costs twice: the outlet name is stored inside the headline
 * instead of the `outlet` field, and `matchThana` runs over a few extra
 * words of publisher branding that have nothing to do with where the crime
 * happened.
 *
 * Only the *last* dash is treated as the separator, and only when something
 * plausible follows it — headlines contain dashes of their own ("Mirpur
 * mugging - police arrest three - Dhaka Tribune").
 */
function splitGoogleNewsTitle(title) {
  const raw = String(title || '');
  const cut = raw.lastIndexOf(' - ');
  if (cut < 1) return { title: raw, outlet: null };
  const outlet = raw.slice(cut + 3).trim();
  // A trailing fragment that is long or sentence-like is part of the
  // headline, not a masthead.
  if (!outlet || outlet.length > 40 || outlet.split(/\s+/).length > 5) return { title: raw, outlet: null };
  return { title: raw.slice(0, cut).trim(), outlet };
}

/** A title reduced to something two feeds' wordings of one story share. */
function titleKey(title) {
  return String(title || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

/**
 * Direct-publisher feeds first, Google News last.
 *
 * Order is load-bearing, not cosmetic: `collectNews` keeps the first version
 * of a story it sees, and the first version should be the one whose link is
 * the publisher's own URL rather than a Google redirect. That link is the
 * entire provenance record for an advisory about a real neighbourhood.
 */
const NEWS_FEEDS = [
  { name: 'The Daily Star — Crime & Justice', url: 'https://www.thedailystar.net/news/crime-justice/rss.xml' },
  { name: 'The Daily Star', url: 'https://www.thedailystar.net/rss.xml' },
  { name: 'Prothom Alo (English)', url: 'https://en.prothomalo.com/feed' },
  { name: 'Prothom Alo', url: 'https://www.prothomalo.com/stories.rss' },
  ...googleNewsFeeds(),
];

/** Nothing older than this becomes an advisory — it is a *current*-risk signal. */
const MAX_ARTICLE_AGE_MS = 21 * 24 * 60 * 60 * 1000;

/**
 * Ceiling on model calls per run.
 *
 * The cheap keyword filters remove the overwhelming majority of items
 * before this matters; the cap is a backstop against a feed that suddenly
 * returns hundreds of matching items, so a bad day costs a bounded number
 * of Gemini calls instead of an unbounded one.
 */
const MAX_CLASSIFICATIONS = 12;

/**
 * Asks Gemini how serious a story is, and — importantly — whether it is
 * about the neighbourhood's *ongoing* condition at all.
 *
 * The distinction the prompt is built around: a single arrest is not
 * evidence that an area has deteriorated, whereas a pattern is. Most crime
 * reporting is the former. The model is told to return `none` freely,
 * because the expensive mistake here is flagging a neighbourhood, not
 * missing a story.
 */
async function classifySeverity(item, geminiApiKey) {
  const prompt = `You are assessing whether a Bangladeshi news article indicates an ONGOING elevated
street-crime risk for pedestrians in a specific Dhaka neighbourhood (thana).

Neighbourhood: ${item.thana.en}
Headline: ${item.title}
Summary: ${item.summary}

Answer with severity:
- "none" — a single isolated incident, a court/arrest/verdict story, an
  incident that happened elsewhere, or anything that does not tell a
  pedestrian this area is currently riskier than usual. THIS IS THE MOST
  COMMON AND CORRECT ANSWER.
- "elevated" — credible reporting of a recent pattern affecting people on
  the street here (a spate of muggings or snatchings, a specific stretch
  repeatedly targeted).
- "high" — sustained or worsening reporting of street crime in this area.
- "severe" — this area is being reported as actively and repeatedly
  dangerous for ordinary pedestrians right now.

Be conservative. This changes navigation for blind users, and wrongly
labelling a real neighbourhood is worse than missing an article.

Return ONLY: {"severity": "none|elevated|high|severe", "reason": "<one short sentence>"}`;

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent?key=${geminiApiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ role: 'user', parts: [{ text: prompt }] }],
        generationConfig: { responseMimeType: 'application/json' },
      }),
    },
  );
  if (!res.ok) throw new Error(`Gemini classification returned HTTP ${res.status}`);
  const json = await res.json();
  const text = json.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error('Gemini returned no classification');
  return JSON.parse(text);
}

export async function collectNews(geminiApiKey, { now = Date.now() } = {}) {
  const seen = new Set();
  const candidates = [];

  // Direct-publisher feeds are listed before the Google News ones, so when
  // one story reaches both, the version kept is the one whose `link` is the
  // publisher's own URL. That link becomes an advisory's `sourceUrl` — the
  // whole provenance record for a claim about a real neighbourhood — and a
  // `news.google.com/rss/articles/CBMi…` redirect is a markedly worse one.
  const seenTitles = new Set();

  for (const feed of NEWS_FEEDS) {
    const items = await fetchFeed(feed.url, { userAgent: USER_AGENT });
    for (const raw of items) {
      // The same story frequently appears in both a section feed and the
      // outlet's general feed; counting it twice would inflate nothing
      // here (advisories are keyed by URL) but would double the model
      // spend.
      if (seen.has(raw.link)) continue;
      seen.add(raw.link);

      const { title, outlet } = feed.viaGoogleNews
        ? splitGoogleNewsTitle(raw.title)
        : { title: raw.title, outlet: null };

      // URL dedupe cannot see across sources: Google News rewrites every
      // link, so the same story arrives under two different URLs and would
      // otherwise be classified twice — a second model call for an answer
      // already paid for.
      const key = titleKey(title);
      if (key && seenTitles.has(key)) continue;
      if (key) seenTitles.add(key);

      const item = { ...raw, title };
      if (!item.publishedAt) continue;
      if (now - Date.parse(item.publishedAt) > MAX_ARTICLE_AGE_MS) continue;

      const candidate = isCandidate(item);
      // The real publisher when Google News named one, so an advisory's
      // stored outlet says "Dhaka Tribune" rather than "Google News".
      if (candidate) candidates.push({ ...candidate, outlet: outlet || feed.name });
    }
  }

  const considered = candidates.slice(0, MAX_CLASSIFICATIONS);
  const recorded = [];
  const skipped = [];
  const incidents = { filed: 0, duplicate: 0, rejected: 0 };

  await withAuth(async (idToken) => {
    // Every candidate is filed as an incident first, whatever the model
    // later says about it.
    //
    // These two questions are not the same question. "Is this a crime story
    // about exactly one Dhaka thana?" is a fact the matcher has already
    // established for free. "Has this neighbourhood deteriorated?" is a
    // judgement, and the classifier is told — correctly — to answer `none`
    // to it almost always.
    //
    // Conflating them is why this pipeline produced nothing: measured
    // against the live feeds it finds about one confirmed Dhaka-thana crime
    // story per run, every one an isolated incident, every one classified
    // `none`, so `thanaAdvisories` had never been written to at all and the
    // learned baseline had never had anything to remember. Counting is
    // cheap and honest; judging stays expensive and rare.
    //
    // Not capped at MAX_CLASSIFICATIONS: that cap exists to bound Gemini
    // spend, and this costs no model call.
    for (const candidate of candidates) {
      try {
        const result = await callFunction(
          'recordThanaIncident',
          {
            thanaSlug: candidate.thana.slug,
            sourceUrl: candidate.link,
            headline: candidate.title,
            outlet: candidate.outlet,
            publishedAt: candidate.publishedAt,
          },
          idToken,
        );
        if (result?.recorded) incidents.filed += 1;
        else incidents.duplicate += 1;
      } catch (err) {
        // Expected and harmless for an unknown thana slug or a malformed
        // date — the backend's validation doing its job. Never fatal to the
        // run; the advisory pass below is the more important half.
        incidents.rejected += 1;
        console.warn(`recordThanaIncident rejected ${candidate.link}:`, String(err));
      }
    }

    for (const candidate of considered) {
      let verdict;
      try {
        verdict = await classifySeverity(candidate, geminiApiKey);
      } catch (err) {
        console.warn(`classification failed for ${candidate.link}:`, String(err));
        continue;
      }
      if (!verdict || verdict.severity === 'none' || !verdict.severity) {
        skipped.push({ thana: candidate.thana.slug, title: candidate.title, reason: verdict?.reason });
        continue;
      }
      try {
        await callFunction(
          'recordThanaAdvisory',
          {
            thanaSlug: candidate.thana.slug,
            severity: verdict.severity,
            sourceTier: 'news',
            sourceUrl: candidate.link,
            sourceTitle: `${candidate.outlet}: ${candidate.title}`,
            publishedAt: candidate.publishedAt,
            summary: verdict.reason || candidate.summary,
          },
          idToken,
        );
        recorded.push({ thana: candidate.thana.slug, severity: verdict.severity, url: candidate.link });
      } catch (err) {
        // A rejected advisory is usually the backend's validation doing its
        // job (unknown thana slug, malformed date) — log and continue
        // rather than aborting the whole run.
        console.warn(`recordThanaAdvisory rejected ${candidate.link}:`, String(err));
      }
    }
  });

  return {
    feedsRead: NEWS_FEEDS.length,
    itemsSeen: seen.size,
    candidates: candidates.length,
    classified: considered.length,
    // The count that should be non-zero on a normal run. `recorded` being
    // empty is expected; `incidents.filed` staying at zero for weeks means
    // the matcher or the feeds have stopped, not that Dhaka got safer.
    incidents,
    recorded,
    skipped,
    truncated: candidates.length > MAX_CLASSIFICATIONS,
  };
}

export { NEWS_FEEDS, MAX_ARTICLE_AGE_MS, MAX_CLASSIFICATIONS, splitGoogleNewsTitle, titleKey };
