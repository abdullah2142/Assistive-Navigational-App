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
const NEWS_FEEDS = [
  { name: 'The Daily Star — Crime & Justice', url: 'https://www.thedailystar.net/news/crime-justice/rss.xml' },
  { name: 'The Daily Star', url: 'https://www.thedailystar.net/rss.xml' },
  { name: 'Prothom Alo (English)', url: 'https://en.prothomalo.com/feed' },
  { name: 'Prothom Alo', url: 'https://www.prothomalo.com/stories.rss' },
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

  for (const feed of NEWS_FEEDS) {
    const items = await fetchFeed(feed.url, { userAgent: USER_AGENT });
    for (const item of items) {
      // The same story frequently appears in both a section feed and the
      // outlet's general feed; counting it twice would inflate nothing
      // here (advisories are keyed by URL) but would double the model
      // spend.
      if (seen.has(item.link)) continue;
      seen.add(item.link);

      if (!item.publishedAt) continue;
      if (now - Date.parse(item.publishedAt) > MAX_ARTICLE_AGE_MS) continue;

      const candidate = isCandidate(item);
      if (candidate) candidates.push({ ...candidate, outlet: feed.name });
    }
  }

  const considered = candidates.slice(0, MAX_CLASSIFICATIONS);
  const recorded = [];
  const skipped = [];

  await withAuth(async (idToken) => {
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
    recorded,
    skipped,
    truncated: candidates.length > MAX_CLASSIFICATIONS,
  };
}

export { NEWS_FEEDS, MAX_ARTICLE_AGE_MS, MAX_CLASSIFICATIONS };
