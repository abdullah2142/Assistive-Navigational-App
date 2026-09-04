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
export async function fetchFeed(url, { userAgent }) {
  try {
    const res = await fetch(url, { headers: { 'user-agent': userAgent, accept: 'application/rss+xml, application/xml, text/xml, */*' } });
    if (!res.ok) {
      console.warn(`feed ${url} returned HTTP ${res.status}`);
      return [];
    }
    return parseFeed(await res.text());
  } catch (err) {
    // One unreachable outlet must not take the whole run down — the other
    // sources are still worth collecting.
    console.warn(`feed ${url} failed:`, String(err));
    return [];
  }
}
