/**
 * Collector logic — the parts that decide *which neighbourhood* a story is
 * about, and whether it counts at all.
 *
 * These matter more than their size suggests: a misattribution here tells a
 * blind user that a real place is dangerous on the strength of an article
 * about somewhere else. The very first item in The Daily Star's live crime
 * feed while this was written was a killing in Raozan, Chattogram — so the
 * naive version of this code would have been wrong on real row one.
 */

import test from 'node:test';
import assert from 'node:assert/strict';

import { parseFeed } from '../src/lib/feed.js';
import { matchThana, mentionsCrime, isCandidate, containsPhrase, words } from '../src/lib/thana_match.js';
import { THANAS } from '../src/lib/thana_index.js';

test('the thana index covers all 41 DMP thanas with slugs', () => {
  assert.equal(THANAS.length, 41);
  for (const t of THANAS) {
    assert.match(t.slug, /^[a-z0-9-]+$/, `${t.en} has a malformed slug`);
    assert.ok(t.bn.length > 0, `${t.en} has no Bangla name`);
  }
  assert.ok(THANAS.some((t) => t.slug === 'mohammadpur'));
});

test('matches a Dhaka thana named in the text', () => {
  assert.equal(matchThana('Mugging spree in Mohammadpur worries residents')?.slug, 'mohammadpur');
  assert.equal(matchThana('গুলশানে ছিনতাই বেড়েছে')?.slug, 'gulshan');
});

test('a same-named thana in another city is NOT matched', () => {
  // Dhaka has a Kotwali. So does Chattogram. So does most of the country.
  assert.equal(matchThana('Robbery in Kotwali, Chattogram'), null);
  assert.equal(matchThana('Cantonment area of Sylhet sees unrest'), null);
  // ...unless the story is explicitly about Dhaka.
  assert.equal(matchThana('Robbery in Kotwali, Dhaka')?.slug, 'kotwali');
});

test('the real Raozan headline that would have broken a naive matcher', () => {
  const item = {
    title: 'Man hacked, shot dead in Raozan',
    summary: 'A man was hacked and shot dead by unidentified assailants in Keranihat Bazar area of Raozan upazila, Chattogram yesterday night.',
  };
  assert.equal(isCandidate(item), null);
});

test('an article naming several thanas is discarded, not attributed to one', () => {
  // Raising whichever was mentioned first would be arbitrary.
  assert.equal(matchThana('Crime compared across Mohammadpur, Mirpur and Gulshan in Dhaka'), null);
});

test('non-crime news about a thana is not a candidate', () => {
  assert.equal(isCandidate({ title: 'New park opens in Mohammadpur, Dhaka', summary: 'Residents welcome it.' }), null);
  assert.ok(mentionsCrime('mugging in the area'));
  assert.ok(mentionsCrime('ছিনতাই হয়েছে'));
  assert.ok(!mentionsCrime('a new bridge opened'));
});

test('a genuine Dhaka crime story is a candidate', () => {
  const candidate = isCandidate({
    title: 'Snatchers target pedestrians in Mohammadpur',
    summary: 'Police in Dhaka say muggings have risen sharply along the main road.',
  });
  assert.ok(candidate);
  assert.equal(candidate.thana.slug, 'mohammadpur');
});

test('matching is by whole word, never substring', () => {
  assert.ok(containsPhrase(words('crime in Adabor today'), 'Adabor'));
  assert.ok(!containsPhrase(words('Adaborough'), 'Adabor'));
  assert.ok(containsPhrase(words('Tejgaon Ind. Area, Dhaka'), 'Tejgaon Ind Area'));
});

test('parses the real RSS 2.0 shape The Daily Star returns', () => {
  // Note the <a> markup inside <title>, which is what that feed actually
  // does and which would otherwise leave HTML in every headline.
  const xml = `<rss><channel>
    <item>
      <title><a href="/news/x" hreflang="en">Man hacked, shot dead in Raozan</a></title>
      <link>https://www.thedailystar.net/news/x</link>
      <description>A man was hacked and shot dead in Raozan upazila, Chattogram.</description>
      <pubDate>Fri, 04 Sep 26 00:00:00 +0600</pubDate>
    </item>
  </channel></rss>`;
  const [item] = parseFeed(xml);
  assert.equal(item.title, 'Man hacked, shot dead in Raozan');
  assert.ok(!item.title.includes('<a'), 'markup leaked into the headline');
  assert.equal(item.link, 'https://www.thedailystar.net/news/x');
  assert.ok(item.publishedAt.startsWith('2026-09-03') || item.publishedAt.startsWith('2026-09-04'));
});

test('parses the Atom shape Reddit returns, including the author', () => {
  const xml = `<feed>
    <entry>
      <title>Anyone else seeing more snatching in Mohammadpur?</title>
      <link href="https://www.reddit.com/r/dhaka/comments/abc/" />
      <updated>2026-09-03T10:00:00+00:00</updated>
      <author><name>/u/someone</name></author>
    </entry>
  </feed>`;
  const [item] = parseFeed(xml);
  assert.equal(item.author, '/u/someone');
  assert.equal(item.link, 'https://www.reddit.com/r/dhaka/comments/abc/');
  assert.equal(item.publishedAt, '2026-09-03T10:00:00.000Z');
});

test('an undated item yields null rather than a fabricated timestamp', () => {
  // Advisories decay from their publication date, so guessing "now" would
  // keep an old story alive indefinitely.
  const [item] = parseFeed('<rss><channel><item><title>x</title><link>https://e.com/1</link></item></channel></rss>');
  assert.equal(item.publishedAt, null);
});

test('malformed feeds yield nothing instead of throwing', () => {
  assert.deepEqual(parseFeed(''), []);
  assert.deepEqual(parseFeed('not xml at all'), []);
  assert.deepEqual(parseFeed('<rss><channel><item><title>no link</title></item></channel></rss>'), []);
});

test('HTML entities are decoded out of titles', () => {
  const xml = `<rss><channel><item>
    <title>Mugging &amp; theft rise in Mohammadpur</title>
    <link>https://e.com/1</link><pubDate>Fri, 04 Sep 26 00:00:00 +0600</pubDate>
  </item></channel></rss>`;
  assert.equal(parseFeed(xml)[0].title, 'Mugging & theft rise in Mohammadpur');
});

test('every cron in wrangler.toml has a handler, and vice versa', async () => {
  // A cron registered without a handler fires forever and does nothing;
  // a handler with no cron never runs. Both fail silently, which for a
  // safety-data pipeline means the map quietly goes stale.
  const fs = await import('node:fs');
  const toml = fs.readFileSync(new URL('../wrangler.toml', import.meta.url), 'utf8');
  const index = fs.readFileSync(new URL('../src/index.js', import.meta.url), 'utf8');

  const cronsBlock = toml.slice(toml.indexOf('crons = ['));
  const declared = [...cronsBlock.matchAll(/"([\d*][^"]*)"/g)].map((m) => m[1]).sort();

  const jobsBlock = index.slice(index.indexOf('const CRON_JOBS'));
  const handled = [...jobsBlock.matchAll(/^\s*'([\d*][^']*)':/gm)].map((m) => m[1]).sort();

  assert.ok(declared.length >= 3, `expected the three schedules, found ${declared.length}`);
  assert.deepEqual(handled, declared, 'wrangler.toml and CRON_JOBS have drifted');
});
