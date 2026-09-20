#!/usr/bin/env node
/**
 * Runs the collectors' own filters over the live feeds, locally, and prints
 * where every item is lost.
 *
 * ## Why this exists
 *
 * `thanaAdvisories` and `socialSignals` did not exist in Firestore at all —
 * not empty, absent, which in Firestore means nothing has ever been written
 * to them. That has two completely different explanations with the same
 * symptom: the collectors are broken, or the collectors are working and
 * correctly finding nothing worth filing. No log or dashboard distinguishes
 * those, because "filed nothing" is the expected outcome of most runs.
 *
 * This does distinguish them. It runs the real `fetchFeed`, `mentionsCrime`
 * and `isCandidate` against the real feeds and reports the funnel:
 * fetched -> dated -> fresh -> mentions crime -> names exactly one Dhaka
 * thana. Whatever survives is what a run would have paid Gemini to
 * classify.
 *
 * It makes no Firebase calls and no Gemini calls, so it is free and safe to
 * run as often as you like.
 *
 *   node scripts/probe_feeds.mjs
 *   node scripts/probe_feeds.mjs --misses   # also show what was rejected, and why
 */

import { fetchFeed } from '../src/lib/feed.js';
import {
  NEWS_FEEDS,
  MAX_ARTICLE_AGE_MS,
  splitGoogleNewsTitle,
  titleKey,
} from '../src/collectors/news.js';
import { SOCIAL_FEEDS, MAX_POST_AGE_MS } from '../src/collectors/social.js';
import {
  isCandidate,
  matchThana,
  mentionsCrime,
  words,
  containsPhrase,
  COMPETING_LOCATIONS,
} from '../src/lib/thana_match.js';
import { THANAS } from '../src/lib/thana_index.js';
import { USER_AGENT } from '../src/lib/firebase.js';

const showMisses = process.argv.includes('--misses');
const now = Date.now();

/** Why one item was rejected — the part that turns a count into a decision. */
function explainMiss(text) {
  const tokens = words(text);
  const competing = COMPETING_LOCATIONS.filter((c) => containsPhrase(tokens, c));
  const named = THANAS.filter((t) => containsPhrase(tokens, t.en) || containsPhrase(tokens, t.bn));
  const mentionsDhaka = containsPhrase(tokens, 'dhaka') || containsPhrase(tokens, 'ঢাকা');

  if (competing.length && !mentionsDhaka) return `elsewhere: ${competing.join(', ')}`;
  if (named.length === 0) return 'no Dhaka thana named';
  if (named.length > 1) return `ambiguous: ${named.map((t) => t.en).join(', ')}`;
  return 'unclear';
}

async function probe(label, feeds, maxAgeMs) {
  console.log(`\n=== ${label} ===`);
  const funnel = { items: 0, duplicate: 0, dated: 0, fresh: 0, crime: 0, candidates: 0 };
  const misses = [];
  const hits = [];
  // Shared across feeds, exactly as in `collectNews` — the point of the
  // cross-source dedupe is that it spans feeds, so a per-feed set would
  // measure nothing.
  const seenTitles = new Set();

  for (const feed of feeds) {
    const name = feed.name || feed.url;
    let items;
    try {
      items = await fetchFeed(feed.url, { userAgent: USER_AGENT });
    } catch (err) {
      // A feed that stopped responding is the single most likely silent
      // failure here, so it is reported loudly rather than counted as zero.
      console.log(`  ${name.padEnd(34)} UNREACHABLE — ${String(err).slice(0, 70)}`);
      continue;
    }

    let fresh = 0;
    let crime = 0;
    let candidates = 0;
    let duplicate = 0;
    for (const raw of items) {
      funnel.items++;

      // The same two normalisations `collectNews` applies, for the same
      // reason this script exists at all: a probe that filters differently
      // from the real run predicts a run that never happens.
      const item = feed.viaGoogleNews
        ? { ...raw, title: splitGoogleNewsTitle(raw.title).title }
        : raw;
      const key = titleKey(item.title);
      if (key && seenTitles.has(key)) {
        // Counted, not silently dropped — how much Google News merely
        // repeats the direct feeds is the thing worth knowing about it.
        duplicate++;
        funnel.duplicate++;
        continue;
      }
      if (key) seenTitles.add(key);

      if (!item.publishedAt) continue;
      funnel.dated++;
      if (now - Date.parse(item.publishedAt) > maxAgeMs) continue;
      funnel.fresh++;
      fresh++;

      const text = `${item.title || ''} ${item.summary || ''}`;
      if (!mentionsCrime(text)) continue;
      funnel.crime++;
      crime++;

      const candidate = isCandidate(item);
      if (candidate) {
        funnel.candidates++;
        candidates++;
        hits.push(`${candidate.thana.en}: ${(item.title || '').slice(0, 80)}`);
      } else if (showMisses) {
        misses.push(`${explainMiss(text).padEnd(28)} ${(item.title || '').slice(0, 70)}`);
      }
    }

    console.log(
      `  ${name.padEnd(34)} items=${String(items.length).padStart(3)}`
      + ` dup=${String(duplicate).padStart(2)}`
      + ` fresh=${String(fresh).padStart(3)} crime=${String(crime).padStart(2)}`
      + ` candidates=${candidates}`,
    );
  }

  console.log(
    `  FUNNEL  fetched=${funnel.items} -> new=${funnel.items - funnel.duplicate}`
    + ` -> dated=${funnel.dated} -> fresh=${funnel.fresh}`
    + ` -> crime=${funnel.crime} -> CANDIDATES=${funnel.candidates}`,
  );
  for (const h of hits) console.log(`     candidate  ${h}`);
  for (const m of misses) console.log(`     rejected   ${m}`);

  if (funnel.candidates === 0) {
    console.log(
      '  No candidates this run. That is a normal outcome — most reporting is not'
      + '\n  about a named Dhaka thana — but a long unbroken run of zeroes means the'
      + '\n  pipeline is starved rather than working.',
    );
  } else {
    console.log(
      `  Each candidate is filed as an incident (no model call). ${funnel.candidates} incident(s)`
      + '\n  this run; three distinct ones in a calendar month make that month count'
      + '\n  toward the learned baseline.',
    );
  }
  return funnel;
}

const news = await probe('NEWS', NEWS_FEEDS, MAX_ARTICLE_AGE_MS);
const social = await probe('SOCIAL', SOCIAL_FEEDS, MAX_POST_AGE_MS);

console.log(
  `\nThana index: ${THANAS.length} entries.`
  + ` Candidates would cost ${news.candidates + social.candidates} Gemini calls this run.\n`,
);
