/**
 * Minimal RSS/Atom reader.
 *
 * Regex rather than a DOM parse, for the same reason the monthly crime
 * ingest parses its table that way: Workers run on `workerd`, which has no
 * Node APIs and no DOMParser for arbitrary XML, and pulling in a full XML
 * library to read four well-formed feeds would be more moving parts than
 * the job needs.
 *
 * Shapes handled, both confirmed against live responses while writing this:
 * - RSS 2.0 `<item>` with `<title>/<link>/<description>/<pubDate>` — The
 *   Daily Star, Prothom Alo.
 * - Atom `<entry>` with `<title>/<link href>/<updated>/<author><name>` —
 *   Reddit's `.rss`.
 *
 * The Daily Star wraps its titles in an `<a href>` tag inside the `<title>`
 * element, which is unusual and would otherwise leave markup in every
 * headline — hence the tag strip on every extracted field.
 */

function decodeEntities(text) {
  return String(text || '')
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

function tag(block, name) {
  const match = block.match(new RegExp(`<${name}[^>]*>([\\s\\S]*?)</${name}>`, 'i'));
  return match ? decodeEntities(match[1]) : '';
}

function linkOf(block) {
  // Atom puts the URL in an attribute; RSS puts it in the element body.
  const atom = block.match(/<link[^>]*\shref="([^"]+)"/i);
  if (atom) return atom[1];
  const rss = tag(block, 'link');
  return rss || '';
}

/**
 * Parses a feed body into a normalized shape.
 *
 * `publishedAt` is an ISO string when the feed gave a parseable date, and
 * null otherwise — never "now" as a fallback. A fabricated timestamp would
 * make an old story look current, and advisories decay from their
 * publication date, so that single guess would keep stale news alive.
 */
export function parseFeed(xml, { limit = 40 } = {}) {
  const blocks = [
    ...String(xml || '').matchAll(/<(item|entry)[\s>][\s\S]*?<\/\1>/gi),
  ].map((m) => m[0]);

  const items = [];
  for (const block of blocks.slice(0, limit)) {
    const link = linkOf(block);
    if (!link) continue;
    const rawDate = tag(block, 'pubDate') || tag(block, 'updated') || tag(block, 'published');
    const parsed = rawDate ? Date.parse(rawDate) : NaN;
    items.push({
      title: tag(block, 'title'),
      summary: tag(block, 'description') || tag(block, 'summary') || tag(block, 'content'),
      link,
      publishedAt: Number.isNaN(parsed) ? null : new Date(parsed).toISOString(),
      author: tag(block, 'name') || tag(block, 'creator') || tag(block, 'author') || '',
    });
  }
  return items;
}

/** Fetches and parses a feed, returning [] rather than throwing. */
/**
 * Statuses worth trying again, and how long to wait.
 *
 * Reddit rate-limits this User-Agent intermittently: probing the two
 * subreddit feeds back to back, `r/bangladesh` returned 429 on one run and
 * 200 on the next, seconds apart. Without a retry that is simply a feed
 * that silently contributes nothing on roughly half of all runs, and
 * because "found nothing" is the normal outcome here, nobody would ever
 * notice the difference.
 *
 * Short, few, and only for statuses that actually mean "later": a Worker
 * has a wall-clock budget and there is no value in fighting a 404.
 */
const RETRY_STATUSES = new Set([429, 500, 502, 503, 504]);
const RETRY_DELAYS_MS = [1200, 4000];

export async function fetchFeed(url, { userAgent, sleep = (ms) => new Promise((r) => setTimeout(r, ms)) }) {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, {
        headers: {
          'user-agent': userAgent,
          accept: 'application/rss+xml, application/xml, text/xml, */*',
        },
      });
      if (res.ok) return parseFeed(await res.text());

      if (RETRY_STATUSES.has(res.status) && attempt < RETRY_DELAYS_MS.length) {
        // Honour Retry-After when the server sets it — guessing shorter
        // than it asked for is how a rate limit turns into a ban.
        const header = Number(res.headers.get('retry-after'));
        const wait = Number.isFinite(header) && header > 0
          ? Math.min(header * 1000, 10000)
          : RETRY_DELAYS_MS[attempt];
        console.warn(`feed ${url} returned HTTP ${res.status}; retrying in ${wait}ms`);
        await sleep(wait);
        continue;
      }

      console.warn(`feed ${url} returned HTTP ${res.status}`);
      return [];
    } catch (err) {
      if (attempt < RETRY_DELAYS_MS.length) {
        console.warn(`feed ${url} failed (${String(err)}); retrying`);
        await sleep(RETRY_DELAYS_MS[attempt]);
        continue;
      }
      // One unreachable outlet must not take the whole run down — the other
      // sources are still worth collecting.
      console.warn(`feed ${url} failed:`, String(err));
      return [];
    }
  }
}
