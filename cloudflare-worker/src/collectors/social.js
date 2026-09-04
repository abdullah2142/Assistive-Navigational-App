import { fetchFeed } from '../lib/feed.js';
import { callFunction, USER_AGENT, withAuth } from '../lib/firebase.js';
import { isCandidate } from '../lib/thana_match.js';

/**
 * Collects social-media posts about Dhaka neighbourhoods and files them as
 * *signals* — never directly as advisories.
 *
 * ## What this deliberately does not decide
 *
 * Nothing here judges whether a neighbourhood is dangerous. Each post is
 * submitted to `recordSocialSignal` and forgotten; the backend decides,
 * and only once **three separate accounts** have posted about the same
 * thana inside 72 hours (`functions/lib/social_signal.js`, reusing Module
 * 5's Red Flag threshold exactly). Even then the resulting advisory is
 * capped below the tier that can promote a thana to hotspot behaviour.
 *
 * That split is the whole design. A collector that could decide would be a
 * collector that could be wrong on one enthusiastic poster, and the thing
 * it would be wrong about is what the app tells a blind user about a real
 * place where real people live.
 *
 * ## Sources
 *
 * Public feeds only, and no scraping behind a login or past a bot wall.
 * Reddit's `.rss` endpoints were confirmed reachable (200) while this was
 * written; its JSON API was not (403 without OAuth), which is why the RSS
 * form is used.
 *
 * **X/Twitter and Facebook are deliberately absent.** Both require paid or
 * authenticated API access for search, and the alternative — scraping HTML
 * behind their bot protection — produces a pipeline that breaks silently
 * and unpredictably. A source that fails quietly is worse than no source,
 * because the safety map then goes stale without anyone noticing. Add them
 * here when real API credentials exist; the ingestion contract will not
 * need to change.
 */
const SOCIAL_FEEDS = [
  { platform: 'reddit', name: 'r/dhaka', url: 'https://www.reddit.com/r/dhaka/new/.rss' },
  { platform: 'reddit', name: 'r/bangladesh', url: 'https://www.reddit.com/r/bangladesh/new/.rss' },
];

/**
 * Posts older than this are not submitted at all — the backend's
 * corroboration window is 72 hours, so anything older can never contribute
 * and would only be swept away again.
 */
const MAX_POST_AGE_MS = 72 * 60 * 60 * 1000;

/** Backstop on how many signals one run will file. */
const MAX_SIGNALS = 40;

export async function collectSocial({ now = Date.now() } = {}) {
  const seen = new Set();
  const candidates = [];

  for (const feed of SOCIAL_FEEDS) {
    const items = await fetchFeed(feed.url, { userAgent: USER_AGENT });
    for (const item of items) {
      if (seen.has(item.link)) continue;
      seen.add(item.link);
      if (!item.publishedAt) continue;
      if (now - Date.parse(item.publishedAt) > MAX_POST_AGE_MS) continue;

      const candidate = isCandidate(item);
      if (!candidate) continue;
      // No author handle means the backend cannot count corroboration by
      // account, which is the entire anti-spam rule — so an unattributable
      // post is dropped rather than filed under a placeholder.
      if (!item.author || !item.author.trim()) continue;

      candidates.push({ ...candidate, platform: feed.platform });
    }
  }

  const considered = candidates.slice(0, MAX_SIGNALS);
  const filed = [];
  const corroborated = [];

  await withAuth(async (idToken) => {
    for (const candidate of considered) {
      try {
        const result = await callFunction(
          'recordSocialSignal',
          {
            thanaSlug: candidate.thana.slug,
            authorHandle: candidate.author.trim(),
            postUrl: candidate.link,
            postedAt: candidate.publishedAt,
            excerpt: `${candidate.title} ${candidate.summary}`.slice(0, 300),
            platform: candidate.platform,
          },
          idToken,
        );
        filed.push({ thana: candidate.thana.slug, url: candidate.link });
        if (result?.corroborated) {
          corroborated.push({
            thana: candidate.thana.slug,
            authors: result.corroboratingAuthors,
          });
        }
      } catch (err) {
        console.warn(`recordSocialSignal rejected ${candidate.link}:`, String(err));
      }
    }
  });

  return {
    feedsRead: SOCIAL_FEEDS.length,
    itemsSeen: seen.size,
    candidates: candidates.length,
    filed: filed.length,
    // Which thanas actually crossed the threshold this run — usually none,
    // which is the expected and correct outcome.
    corroborated,
    truncated: candidates.length > MAX_SIGNALS,
  };
}

export { SOCIAL_FEEDS, MAX_POST_AGE_MS, MAX_SIGNALS };
