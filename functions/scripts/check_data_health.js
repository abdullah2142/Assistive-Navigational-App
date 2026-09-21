#!/usr/bin/env node
/**
 * Answers one question: is the safety engine actually holding data, or is
 * it scoring routes against nothing?
 *
 * ## Why this exists as a script
 *
 * Every piece of the crime pipeline is deployed and every piece has tests,
 * but "the code is correct" and "the collection has rows in it" are
 * different claims, and only the second one decides what a blind user is
 * told about a street tonight. A collector that silently stopped firing
 * looks exactly like a collector that correctly found nothing to report —
 * both leave an empty collection — and nothing in the app would ever
 * complain.
 *
 * So: print the counts, print the newest row's age, and say plainly which
 * of those two situations we are in.
 *
 * ## Running it
 *
 *   node scripts/check_data_health.js
 *
 * Read-only. It never writes.
 *
 * ## Why it no longer needs `gcloud`
 *
 * This used to read through the Admin SDK, which meant Application Default
 * Credentials, which meant `gcloud auth application-default login` on
 * whatever machine wanted to look. That is a real barrier for a check whose
 * entire job is to be run casually and often — and it is what left the
 * question "has `seedCrimeZones` actually written 41 documents?" answered
 * only from function logs, never by reading the collection.
 *
 * Every collection here is `allow read: if request.auth != null`, so an
 * ordinary signed-in client can read all of it. So it signs in anonymously
 * and reads over the Firestore REST API — the same throwaway-token pattern
 * `monthly_crime_ingest.js` and `backfill_thana_evidence.js` already use to
 * *write*, which is the stronger privilege. Nothing to install, runs
 * anywhere Node runs, and the account deletes itself afterwards.
 */

const { THANA_CRIME_SEED } = require('../data/dhaka_thana_crime_seed');
const { thanaSlug } = require('../lib/news_ingestion');

const PROJECT_ID = process.env.GCLOUD_PROJECT || 'ant-assistive-nav';
// Public by design — Firestore security rules are the access control, not
// this key's secrecy. Same key already ships inside the Flutter app.
const FIREBASE_WEB_API_KEY = 'AIzaSyAXm0kMvv5odpkkrHKRNZz2Cm6mvTx2uDg';
const FIRESTORE_URL = `https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents`;

function explainAndExit(err) {
  const message = String(err && err.message ? err.message : err);
  console.error('\nFailed to run.');
  console.error(message.slice(0, 300));
  console.error('');
  process.exit(2);
}

process.on('uncaughtException', explainAndExit);
process.on('unhandledRejection', explainAndExit);

async function signInAnonymously() {
  const res = await fetch(
    `https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${FIREBASE_WEB_API_KEY}`,
    { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true }) },
  );
  const json = await res.json();
  if (!json.idToken) throw new Error(`Anonymous sign-in failed: ${JSON.stringify(json).slice(0, 200)}`);
  return { idToken: json.idToken, localId: json.localId };
}

async function deleteAccount(idToken) {
  try {
    await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:delete?key=${FIREBASE_WEB_API_KEY}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ idToken }),
    });
  } catch {
    // Untidy, not harmful. Never let cleanup fail a read-only report.
  }
}

/**
 * Unwraps one Firestore REST value into something ordinary.
 *
 * The REST API types every field (`{"stringValue":"..."}`), unlike the Admin
 * SDK's plain objects. Only the shapes this script actually reads are
 * handled, because guessing at the rest would be inventing a serializer
 * nobody asked for.
 */
function plainValue(field) {
  if (!field || typeof field !== 'object') return undefined;
  if ('stringValue' in field) return field.stringValue;
  if ('timestampValue' in field) return field.timestampValue;
  if ('integerValue' in field) return Number(field.integerValue);
  if ('doubleValue' in field) return field.doubleValue;
  if ('booleanValue' in field) return field.booleanValue;
  return undefined;
}

/**
 * Reads up to `max` documents from a collection, following paging.
 *
 * `pageSize` is a request, not a promise — Firestore may return fewer and a
 * `nextPageToken`, so a single unpaged call can under-report a collection
 * and make a healthy collector look like a stopped one.
 */
async function readCollection(idToken, name, max) {
  const docs = [];
  let pageToken = '';
  do {
    const url = `${FIRESTORE_URL}/${name}?pageSize=${Math.min(300, max)}`
      + (pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : '');
    const res = await fetch(url, { headers: { Authorization: `Bearer ${idToken}` } });
    if (!res.ok) {
      const body = await res.text();
      throw new Error(`HTTP ${res.status} reading ${name}: ${body.slice(0, 160)}`);
    }
    const body = await res.json();
    for (const doc of body.documents || []) {
      docs.push({ id: doc.name.split('/').pop(), fields: doc.fields || {} });
    }
    pageToken = body.nextPageToken || '';
  } while (pageToken && docs.length < max);
  return docs;
}

/**
 * What each collection means, and how stale is too stale.
 *
 * `maxAgeHours` is "if the newest row is older than this, something has
 * stopped" — set from each collector's own schedule with generous slack,
 * not from what would be nice.
 */
const COLLECTIONS = [
  {
    name: 'crimeZones',
    what: 'the 2009 per-thana baseline every route score starts from',
    emptyMeans: 'CRITICAL — seedCrimeZones has never run. Route safety is scoring against nothing.',
    maxAgeHours: null, // static seed; it does not refresh and should not
    // "Not empty" is too weak a question for this one. A partial seed is the
    // dangerous case and the invisible one: routing still works, every
    // polyline still scores, and the missing thanas simply never flag —
    // indistinguishable from a safe neighbourhood. So count against the seed
    // and name what is absent.
    expectCount: THANA_CRIME_SEED.length,
    // `thanaSlug` imported rather than re-implemented: these ids have to
    // match what `seedCrimeZones` wrote exactly, and a local copy that
    // drifted by one character would report all 41 thanas missing from a
    // perfectly healthy seed.
    expectIds: THANA_CRIME_SEED.map((t) => thanaSlug(t.thanaName)),
  },
  {
    name: 'thanaIncidents',
    what: 'individual crime stories matched to a thana; three in a month make it count',
    emptyMeans:
      'The news collector has filed no incidents. This is the collection that should be '
      + 'growing steadily — roughly one per run. Empty for more than a few days means the '
      + 'matcher or the feeds have stopped, not that Dhaka got safer. Run '
      + 'cloudflare-worker/scripts/probe_feeds.mjs to see which.',
    maxAgeHours: 24 * 7,
  },
  {
    name: 'thanaAdvisories',
    what: 'current per-thana risk from news reporting',
    emptyMeans:
      'No advisory has ever been raised. This is EXPECTED and not a fault: an advisory needs a '
      + 'model to judge that an article describes an ongoing pattern, and almost all reporting is '
      + 'of isolated incidents. thanaIncidents above is the collection that should have rows.',
    maxAgeHours: 24 * 21, // advisories expire; nothing newer than 3 weeks means the feed stopped
  },
  {
    name: 'socialSignals',
    what: 'individual social posts awaiting corroboration',
    emptyMeans:
      'The social collector has never filed anything. Signals are swept after 72h, so an empty '
      + 'collection is normal on a quiet week and suspicious on a busy one.',
    maxAgeHours: 24 * 7,
  },
  {
    name: 'cityTrend',
    what: 'monthly citywide DMP figures; the last four set the multiplier applied to every route',
    emptyMeans:
      'No month has ever been ingested, so the citywide multiplier is pinned at a neutral 1.0. '
      + 'scrapeDmpCrimeReports fires on the 12th and reads only the newest month, so gaps in the '
      + 'middle of the series are never filled. Run scripts/backfill_city_trend.js.',
    // The scraper fires monthly; two months of silence means it has stopped.
    maxAgeHours: 24 * 62,
    // A count is not the useful question here — a *gap* is. The multiplier
    // takes the four newest periods and compares the latest to the other
    // three with no idea whether they are adjacent months or a year apart,
    // so a hole produces a confident wrong answer rather than a missing one.
    // Measured live 2026-09-21: 66 months ending 2025-05 plus a lone
    // 2026-07 put the multiplier on its 0.71 floor.
    checkContiguity: true,
  },
  {
    name: 'hazardZones',
    what: 'confirmed crowdsourced hazards that routing avoids',
    emptyMeans: 'No hazard has ever been confirmed. Expected until real users start reporting.',
    maxAgeHours: null,
  },
  {
    name: 'hazardReports',
    what: 'raw user reports, before clustering',
    emptyMeans: 'Nobody has ever filed a report. Expected before testing starts.',
    maxAgeHours: null,
  },
];

/** Best-effort newest timestamp across the field names this project writes. */
function newestMs(docs) {
  // `lastReportedAt`/`firstReportedAt` and `ingestedAt` were missing until a
  // live run reported "no timestamp field found" against five real
  // hazardZones documents.
  const fields = [
    'updatedAt', 'createdAt', 'recordedAt', 'publishedAt', 'postedAt',
    'seededAt', 'ingestedAt', 'lastReportedAt', 'firstReportedAt',
  ];
  let newest = null;
  for (const doc of docs) {
    for (const f of fields) {
      const v = plainValue(doc.fields[f]);
      if (!v) continue;
      const ms = Date.parse(v);
      if (Number.isFinite(ms) && (newest === null || ms > newest)) newest = ms;
    }
  }
  return newest;
}

/**
 * The months missing from the middle of a `YYYY-MM`-keyed collection.
 *
 * Only the interior matters: a series that simply has not started yet, or
 * has not caught up to this month yet, is not a hole. A hole is a month with
 * data on both sides of it.
 */
function interiorGaps(periods) {
  const sorted = [...periods].filter((p) => /^\d{4}-\d{2}$/.test(p)).sort();
  if (sorted.length < 2) return [];
  const asIndex = (p) => {
    const [y, m] = p.split('-').map(Number);
    return y * 12 + (m - 1);
  };
  const present = new Set(sorted.map(asIndex));
  const gaps = [];
  for (let i = asIndex(sorted[0]); i < asIndex(sorted[sorted.length - 1]); i++) {
    if (present.has(i)) continue;
    gaps.push(`${Math.floor(i / 12)}-${String((i % 12) + 1).padStart(2, '0')}`);
  }
  return gaps;
}

function describeAge(ms, nowMs) {
  const hours = (nowMs - ms) / 3600000;
  if (hours < 1) return `${Math.round(hours * 60)} minutes ago`;
  if (hours < 48) return `${Math.round(hours)} hours ago`;
  return `${Math.round(hours / 24)} days ago`;
}

async function main() {
  const now = Date.now();
  const problems = [];

  console.log(`\nProject: ${PROJECT_ID}`);
  const { idToken, localId } = await signInAnonymously();

  try {
    for (const c of COLLECTIONS) {
      // A collection with a completeness or contiguity expectation is read
      // in full; the rest are capped, because this is a health check and not
      // an export.
      const cap = c.expectCount ? c.expectCount * 2 : (c.checkContiguity ? 600 : 50);
      let docs;
      try {
        docs = await readCollection(idToken, c.name, cap);
      } catch (err) {
        console.log(`\n${c.name.padEnd(18)} ERROR  ${String(err.message).slice(0, 120)}`);
        problems.push(`${c.name}: could not be read`);
        continue;
      }

      if (docs.length === 0) {
        console.log(`\n${c.name.padEnd(18)} EMPTY`);
        console.log(`${''.padEnd(18)}   ${c.what}`);
        console.log(`${''.padEnd(18)}   ${c.emptyMeans}`);
        if (c.emptyMeans.startsWith('CRITICAL')) problems.push(`${c.name} is empty`);
        continue;
      }

      const newest = newestMs(docs);
      const age = newest === null ? 'no timestamp field found' : describeAge(newest, now);
      const stale = c.maxAgeHours !== null && newest !== null
        && (now - newest) / 3600000 > c.maxAgeHours;
      const capped = docs.length >= cap;

      console.log(
        `\n${c.name.padEnd(18)} ${String(docs.length).padStart(3)}${capped ? '+' : ' '} docs`
        + `   newest ${age}${stale ? '   <-- STALE' : ''}`,
      );
      console.log(`${''.padEnd(18)}   ${c.what}`);
      if (stale) {
        problems.push(`${c.name} has nothing newer than ${age} — its collector may have stopped`);
      }

      if (c.expectIds) {
        const present = new Set(docs.map((d) => d.id));
        const missing = c.expectIds.filter((id) => !present.has(id));
        if (missing.length === 0) {
          console.log(`${''.padEnd(18)}   all ${c.expectCount} seeded thanas present — seedCrimeZones has run`);
        } else {
          console.log(`${''.padEnd(18)}   MISSING ${missing.length} of ${c.expectCount}: ${missing.join(', ')}`);
          problems.push(
            `${c.name} is missing ${missing.length} thana${missing.length === 1 ? '' : 's'} `
            + '— routes through them score as though they were safe. Re-run seedCrimeZones.',
          );
        }
      }

      if (c.checkContiguity) {
        const gaps = interiorGaps(docs.map((d) => d.id));
        if (gaps.length === 0) {
          console.log(`${''.padEnd(18)}   no gaps in the series`);
        } else {
          const shown = gaps.length > 6 ? `${gaps.slice(0, 3).join(', ')} … ${gaps.slice(-3).join(', ')}` : gaps.join(', ');
          console.log(`${''.padEnd(18)}   ${gaps.length} MONTH(S) MISSING mid-series: ${shown}`);
          problems.push(
            `${c.name} has a ${gaps.length}-month hole (${gaps[0]} to ${gaps[gaps.length - 1]}). `
            + 'The citywide multiplier compares the newest month to the three before it in the '
            + 'collection, so it is comparing across that hole. Run scripts/backfill_city_trend.js.',
          );
        }
      }
    }
  } finally {
    await deleteAccount(idToken);
  }

  console.log('');
  if (problems.length === 0) {
    console.log('No problems found.\n');
  } else {
    console.log('Problems:');
    for (const p of problems) console.log(`  - ${p}`);
    console.log('');
  }
  console.log(`(read anonymously as ${localId}, since deleted; nothing was written)\n`);
  process.exit(problems.length ? 1 : 0);
}

main().catch(explainAndExit);
