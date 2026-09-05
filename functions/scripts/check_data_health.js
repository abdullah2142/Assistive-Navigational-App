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
 *   gcloud auth application-default login
 *   node scripts/check_data_health.js
 *
 * Read-only. It never writes.
 */

// Modular imports, not the `admin.firestore()` namespace — firebase-admin
// v14 removed that, and this script found out the hard way.
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');

const PROJECT_ID = process.env.GCLOUD_PROJECT || 'ant-assistive-nav';

/**
 * Turns the credentials failure into one actionable line.
 *
 * The Firestore client resolves Application Default Credentials on a
 * background promise while building its gRPC stub, so when they are missing
 * it throws *outside* the await this script controls — no try/catch around
 * the query can catch it, and the person running this gets thirty lines of
 * google-gax stack instead of the one command they need to run. These
 * handlers exist purely to fix that.
 */
function explainAndExit(err) {
  const message = String(err && err.message ? err.message : err);
  if (/default credentials|GoogleAuthException|could not load/i.test(message)) {
    console.error('\nNot signed in to Google Cloud on this machine.\n');
    console.error('  gcloud auth application-default login\n');
    console.error('Then run this again. Nothing was read or written.\n');
    process.exit(2);
  }
  console.error('\nFailed to run.');
  console.error(message.slice(0, 300));
  console.error('');
  process.exit(2);
}

process.on('uncaughtException', explainAndExit);
process.on('unhandledRejection', explainAndExit);

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
  },
  {
    name: 'thanaAdvisories',
    what: 'current per-thana risk from news reporting',
    emptyMeans:
      'The news collector has never filed anything. Expected occasionally — it is deliberately '
      + 'conservative — but not after weeks of hourly runs. Check the Cloudflare cron logs.',
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

/** Best-effort newest timestamp in a snapshot, across the field names used. */
function newestMs(snapshot) {
  const fields = ['updatedAt', 'createdAt', 'recordedAt', 'publishedAt', 'postedAt', 'seededAt'];
  let newest = null;
  snapshot.forEach((doc) => {
    const data = doc.data();
    for (const f of fields) {
      const v = data[f];
      if (!v) continue;
      const ms = typeof v.toMillis === 'function' ? v.toMillis() : Date.parse(v);
      if (Number.isFinite(ms) && (newest === null || ms > newest)) newest = ms;
    }
  });
  return newest;
}

function describeAge(ms, nowMs) {
  const hours = (nowMs - ms) / 3600000;
  if (hours < 1) return `${Math.round(hours * 60)} minutes ago`;
  if (hours < 48) return `${Math.round(hours)} hours ago`;
  return `${Math.round(hours / 24)} days ago`;
}

async function main() {
  initializeApp({ projectId: PROJECT_ID });
  const db = getFirestore();
  const now = Date.now();
  const problems = [];

  console.log(`\nProject: ${PROJECT_ID}\n`);

  for (const c of COLLECTIONS) {
    let snap;
    try {
      // Capped: this is a health check, not an export. Enough rows to find
      // a recent timestamp, few enough to stay free.
      snap = await db.collection(c.name).limit(50).get();
    } catch (err) {
      console.log(`${c.name.padEnd(18)} ERROR  ${String(err).slice(0, 100)}`);
      problems.push(`${c.name}: could not be read`);
      continue;
    }

    if (snap.empty) {
      console.log(`${c.name.padEnd(18)} EMPTY`);
      console.log(`${''.padEnd(18)}   ${c.what}`);
      console.log(`${''.padEnd(18)}   ${c.emptyMeans}\n`);
      if (c.emptyMeans.startsWith('CRITICAL')) problems.push(`${c.name} is empty`);
      continue;
    }

    const newest = newestMs(snap);
    const age = newest === null ? 'no timestamp field found' : describeAge(newest, now);
    const stale = c.maxAgeHours !== null && newest !== null
      && (now - newest) / 3600000 > c.maxAgeHours;

    console.log(
      `${c.name.padEnd(18)} ${String(snap.size).padStart(3)}${snap.size === 50 ? '+' : ' '} docs`
      + `   newest ${age}${stale ? '   <-- STALE' : ''}`,
    );
    console.log(`${''.padEnd(18)}   ${c.what}\n`);
    if (stale) {
      problems.push(`${c.name} has nothing newer than ${age} — its collector may have stopped`);
    }
  }

  if (problems.length === 0) {
    console.log('No problems found.\n');
  } else {
    console.log('Problems:');
    for (const p of problems) console.log(`  - ${p}`);
    console.log('');
  }
  process.exit(problems.length ? 1 : 0);
}

main().catch(explainAndExit);
