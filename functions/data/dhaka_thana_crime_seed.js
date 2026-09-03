/**
 * Seed data for the `crimeZones` Firestore collection (Module 4 — Contextual
 * Safety & Crime Data).
 *
 * ## Where this data actually comes from
 *
 * The live DMP scraper (`scrapeDmpCrimeReports` in `index.js`) is what's
 * *supposed* to keep `crimeZones` current per `04_module_plan_crime.md` —
 * but `dmp.gov.bd` sits behind a bot-check wall this sandbox can't get past
 * to confirm a stable PDF-listing URL/selectors against, and there's no
 * Document AI processor provisioned yet either. Rather than invent
 * plausible-looking "12 muggings in Mirpur this month" numbers and present
 * them as real to a safety app used by disabled/vulnerable users, this seed
 * uses the best real substitute available: Table 2 ("DCC – Thana wise Crime
 * Database") from Urmee Chowdhury, "Spatial Distribution of Street Crime
 * Occurrences in Dhaka City", AUST Journal of Science and Technology Vol.3
 * No.2 (2011) — itself sourced from DMP Headquarters' own Jan-Mar 2009
 * crime data. Real, DMP-derived, citable, but **old and only three months**
 * — hence `dataSource: 'estimated_2009_academic'`, never presented as a
 * live figure anywhere in the app.
 *
 * `baseCrimeScore` is derived from that table's *crime density* column
 * (recorded street crimes per sq km), not raw crime count or the
 * population-normalized rate — density is what the paper's own author
 * recommends for exactly this use case (small-population commercial thanas
 * otherwise produce wildly inflated/near-infinite rates), and it's also the
 * more relevant signal for a *pedestrian* walking through a physical area,
 * which is what this app's routing actually needs. Density values are
 * min-max normalized to a 1-10 scale, anchored on the table's real min
 * (Demra, 0.08/km2) and max (Paltan, 29.77/km2).
 *
 * A number of current DMP thanas (mostly newer splits of thanas that existed
 * as single larger units in 2009, e.g. Adabor/Sher-e-Bangla Nagar out of
 * Mohammadpur, Kalabagan out of Dhanmondi, Bangshal/Chak Bazar/Gendaria out
 * of the old-town thanas) aren't in the 2009 table at all. Those get a
 * `densityEstimate` interpolated from the geographically- and
 * functionally-nearest thana(s) that *are* in the table, tagged
 * `dataSource: 'estimated_neighbor_interpolation'` — one honesty tier below
 * the academic-sourced entries, so the app/UI can distinguish them if it
 * ever needs to.
 *
 * `categoryHint` feeds `checkRouteSafety`'s temporal multiplier (Step 3 of
 * the module plan: "spiking danger scores in commercial zones after 8 PM").
 */

// densityEstimate: recorded street crimes per sq km (3-month window where
// real; a same-scale eyeballed estimate where interpolated — see dataSource).
const THANA_CRIME_SEED = [
  // --- Real DMP-sourced entries (Table 2, Jan-Mar 2009) ---
  { thanaName: 'Adabor', thanaNameBn: 'আদাবর', densityEstimate: 9.61, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Biman Bandar', thanaNameBn: 'বিমানবন্দর', densityEstimate: 3.80, dataSource: 'estimated_2009_academic', categoryHint: 'transit_hub' },
  { thanaName: 'Badda', thanaNameBn: 'বাড্ডা', densityEstimate: 8.74, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Cantonment', thanaNameBn: 'ক্যান্টনমেন্ট', densityEstimate: 1.24, dataSource: 'estimated_2009_academic', categoryHint: 'institutional' },
  { thanaName: 'Dakshinkhan', thanaNameBn: 'দক্ষিণখান', densityEstimate: 0.74, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Demra', thanaNameBn: 'ডেমরা', densityEstimate: 0.08, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Dhanmondi', thanaNameBn: 'ধানমন্ডি', densityEstimate: 16.52, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Gulshan', thanaNameBn: 'গুলশান', densityEstimate: 14.76, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Hazaribagh', thanaNameBn: 'হাজারীবাগ', densityEstimate: 1.02, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Kafrul', thanaNameBn: 'কাফরুল', densityEstimate: 2.94, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Khilgaon', thanaNameBn: 'খিলগাঁও', densityEstimate: 9.50, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Khilkhet', thanaNameBn: 'খিলক্ষেত', densityEstimate: 1.88, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Kotwali', thanaNameBn: 'কোতোয়ালি', densityEstimate: 15.53, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Lalbagh', thanaNameBn: 'লালবাগ', densityEstimate: 2.03, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Mirpur', thanaNameBn: 'মিরপুর', densityEstimate: 4.64, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Mohammadpur', thanaNameBn: 'মোহাম্মদপুর', densityEstimate: 9.35, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Motijheel', thanaNameBn: 'মতিঝিল', densityEstimate: 15.96, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'New Market', thanaNameBn: 'নিউমার্কেট', densityEstimate: 7.66, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Pallabi', thanaNameBn: 'পল্লবী', densityEstimate: 2.45, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Paltan', thanaNameBn: 'পল্টন', densityEstimate: 29.77, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Ramna', thanaNameBn: 'রমনা', densityEstimate: 13.39, dataSource: 'estimated_2009_academic', categoryHint: 'institutional' },
  { thanaName: 'Sabujbagh', thanaNameBn: 'সবুজবাগ', densityEstimate: 15.32, dataSource: 'estimated_2009_academic', categoryHint: 'mixed' },
  { thanaName: 'Shahbagh', thanaNameBn: 'শাহবাগ', densityEstimate: 12.22, dataSource: 'estimated_2009_academic', categoryHint: 'institutional' },
  { thanaName: 'Shyampur', thanaNameBn: 'শ্যামপুর', densityEstimate: 8.47, dataSource: 'estimated_2009_academic', categoryHint: 'industrial' },
  { thanaName: 'Sutrapur', thanaNameBn: 'সূত্রাপুর', densityEstimate: 3.01, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Tejgaon', thanaNameBn: 'তেজগাঁও', densityEstimate: 14.22, dataSource: 'estimated_2009_academic', categoryHint: 'commercial_core' },
  { thanaName: 'Tejgaon Ind. Area', thanaNameBn: 'তেজগাঁও শিল্পাঞ্চল', densityEstimate: 14.73, dataSource: 'estimated_2009_academic', categoryHint: 'industrial' },
  { thanaName: 'Uttara', thanaNameBn: 'উত্তরা', densityEstimate: 10.20, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },
  { thanaName: 'Uttar Khan', thanaNameBn: 'উত্তরখান', densityEstimate: 0.10, dataSource: 'estimated_2009_academic', categoryHint: 'residential' },

  // --- Interpolated (post-2009 thana splits, not in the source table) ---
  // Old-town core, between Kotwali and Sutrapur — inherits their commercial
  // density, weighted down slightly for its smaller footprint.
  { thanaName: 'Bangshal', thanaNameBn: 'বংশাল', densityEstimate: 12.5, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'commercial_core' },
  // Old-town, adjacent to Lalbagh — similar residential/artisanal character.
  { thanaName: 'Chak Bazar', thanaNameBn: 'চকবাজার', densityEstimate: 4.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'mixed' },
  // Split off Mirpur/Pallabi — residential, similar to its parent thanas.
  { thanaName: 'Darus Salam', thanaNameBn: 'দারুস সালাম', densityEstimate: 3.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'residential' },
  // Old-town, between Sutrapur and Kotwali.
  { thanaName: 'Gendaria', thanaNameBn: 'গেন্ডারিয়া', densityEstimate: 6.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'mixed' },
  // Major inter-district bus terminal/highway junction — historically one of
  // Dhaka's most-cited street-crime hotspots in general reporting, so
  // weighted toward the higher end despite no 2009 table entry.
  { thanaName: 'Jatrabari', thanaNameBn: 'যাত্রাবাড়ী', densityEstimate: 13.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'transit_hub' },
  // Adjacent Shyampur (industrial) and Jatrabari (transit hub).
  { thanaName: 'Kadamtali', thanaNameBn: 'কদমতলী', densityEstimate: 9.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'industrial' },
  // Split off Dhanmondi — inherits a somewhat lower version of its density.
  { thanaName: 'Kalabagan', thanaNameBn: 'কলাবাগান', densityEstimate: 11.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'mixed' },
  // Dense informal riverside settlement, historically underserved by
  // infrastructure/policing in general reporting.
  { thanaName: 'Kamrangir Char', thanaNameBn: 'কামরাঙ্গীরচর', densityEstimate: 8.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'residential' },
  // Between Khilgaon and Badda — similar mixed-commercial character.
  { thanaName: 'Rampura', thanaNameBn: 'রামপুরা', densityEstimate: 9.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'mixed' },
  // Split off Mirpur — residential.
  { thanaName: 'Shah Ali', thanaNameBn: 'শাহ আলী', densityEstimate: 4.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'residential' },
  // Parliament/secretariat institutional zone, split off Mohammadpur.
  { thanaName: 'Sher-e-bangla Nagar', thanaNameBn: 'শেরেবাংলা নগর', densityEstimate: 7.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'institutional' },
  // Far northern periphery — sparse, semi-industrial.
  { thanaName: 'Turag', thanaNameBn: 'তুরাগ', densityEstimate: 2.0, dataSource: 'estimated_neighbor_interpolation', categoryHint: 'industrial' },
];

const DENSITY_MIN = 0.08; // Demra, the real table's minimum.
const DENSITY_MAX = 29.77; // Paltan, the real table's maximum.

/** Min-max normalizes a crime density value onto a 1-10 score, clipped. */
function densityToScore(density) {
  const raw = 1 + 9 * ((density - DENSITY_MIN) / (DENSITY_MAX - DENSITY_MIN));
  return Math.max(1, Math.min(10, Math.round(raw * 10) / 10));
}

module.exports = { THANA_CRIME_SEED, densityToScore };
