#!/usr/bin/env node
/**
 * Fills `busRoutes` with the Dhaka bus operators the Snapshot Vision Engine
 * matches signboards against.
 *
 * ## Why this collection exists
 *
 * Module 6 reads a bus signboard with a vision model and tells a blind user
 * which bus is in front of them. The model's reading of Bangla conjunct text
 * degrades under blur, motion and bad light — measured on this project as
 * `গুলশান` coming back as `ঠানশান`. Reading a hallucinated bus name to
 * somebody who cannot check it against the board is the most harmful thing
 * that feature could do.
 *
 * So the reading is never trusted on its own. It is matched against this
 * collection, and the app speaks what the *directory* says. Matching noisy
 * text to a closed list of 156 names is a far easier problem than matching it
 * to nothing — see `BusRouteDirectory`.
 *
 * ## Why it is keyed by operator, not by route number
 *
 * Because Dhaka is. Of the 156 operators in this dataset, **7 have a number
 * in the name and 149 do not** — real signboards say `আছিম পরিবহন`,
 * `অগ্রদূত`, `আকাশ বাস`. The first version of this feature assumed a route
 * number and was built against an invented test image; the real data
 * overturned it.
 *
 * ## Provenance
 *
 * `functions/data/dhaka_bus_routes.json`, derived from a public compilation
 * of Dhaka local bus operators and their stop sequences. Route lists are
 * factual data — which places a bus serves — rather than creative work.
 *
 * Two things worth knowing before relying on it:
 *   - It is a snapshot, not a feed. Dhaka routes change and nothing here
 *     notices. Re-run this script against refreshed data periodically.
 *   - The stop names are transliterated inconsistently at source
 *     ("Mirpur 10", "Mirpur10", "Mirpur 1"). `BusRouteDirectory` compares
 *     them fuzzily for that reason; do not assume exact keys.
 *
 * ## Running it
 *
 *   gcloud auth application-default login     # once per machine
 *   cd functions && node scripts/seed_bus_routes.js
 *
 * Idempotent: it writes each operator at a deterministic document id, so
 * running it twice updates rather than duplicates. Pass `--dry` to print what
 * it would write and touch nothing.
 */

const fs = require('fs');
const path = require('path');
// Modular imports, matching `index.js`. firebase-admin v14 removed the old
// `admin.firestore()` namespace style entirely.
const { initializeApp, applicationDefault } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

const DRY = process.argv.includes('--dry');
const DATA = path.join(__dirname, '..', 'data', 'dhaka_bus_routes.json');

/** Firestore refuses a batch over 500 writes. */
const BATCH_LIMIT = 450;

async function main() {
  if (!fs.existsSync(DATA)) {
    console.error(`No dataset at ${DATA}`);
    process.exit(1);
  }

  const raw = JSON.parse(fs.readFileSync(DATA, 'utf8'));
  const ids = Object.keys(raw);

  // Guard against seeding a truncated file over a good collection. A partial
  // directory is worse than none: every name it lacks becomes a confident
  // "no match" rather than an honest unknown.
  if (ids.length < 100) {
    console.error(`Only ${ids.length} operators in the dataset — refusing to seed.`);
    console.error('Expected ~156. Check the file before overwriting the collection.');
    process.exit(1);
  }

  const withNumber = ids.filter((id) => raw[id].routeNumber).length;
  const stops = new Set();
  ids.forEach((id) => (raw[id].stops || []).forEach((s) => stops.add(s)));

  console.log(`Operators:        ${ids.length}`);
  console.log(`With a number:    ${withNumber}  (the rest are name-only)`);
  console.log(`Distinct stops:   ${stops.size}`);
  console.log(DRY ? '\nDry run — nothing will be written.\n' : '');

  if (DRY) {
    ids.slice(0, 5).forEach((id) => {
      const r = raw[id];
      console.log(`  ${id}\n    ${r.nameBn} / ${r.nameEn}\n    ${r.stops.length} stops: ${r.origin} -> ${r.destination}`);
    });
    console.log(`  ... and ${ids.length - 5} more`);
    return;
  }

  initializeApp({
    credential: applicationDefault(),
    projectId: process.env.GOOGLE_CLOUD_PROJECT || 'ant-assistive-nav',
  });
  const db = getFirestore();

  let written = 0;
  for (let i = 0; i < ids.length; i += BATCH_LIMIT) {
    const batch = db.batch();
    for (const id of ids.slice(i, i + BATCH_LIMIT)) {
      const r = raw[id];
      batch.set(
        db.collection('busRoutes').doc(id),
        {
          nameEn: r.nameEn || '',
          nameBn: r.nameBn || '',
          routeNumber: r.routeNumber || null,
          stops: r.stops || [],
          serviceType: r.serviceType || '',
          updatedAt: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      written += 1;
    }
    await batch.commit();
    console.log(`  committed ${Math.min(i + BATCH_LIMIT, ids.length)}/${ids.length}`);
  }

  console.log(`\nSeeded ${written} operators into busRoutes.`);
  console.log('Verify with: node scripts/check_data_health.js');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
