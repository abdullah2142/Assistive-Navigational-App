/**
 * The 41 Dhaka Metropolitan Police thanas, with the slug each
 * `crimeZones` document is keyed by.
 *
 * **Generated from `functions/data/dhaka_thana_crime_seed.js`** — not
 * hand-maintained. Workers run on `workerd`, so this file cannot literally
 * import the Node module the way the Cloud Function does; `functions/test/`
 * asserts the two stay identical instead of relying on anyone remembering.
 * A drifted slug here would post advisories that match no zone and silently
 * do nothing, which looks exactly like a working pipeline.
 */
export const THANAS = [
  { slug: 'adabor', en: 'Adabor', bn: 'আদাবর' },
  { slug: 'biman-bandar', en: 'Biman Bandar', bn: 'বিমানবন্দর' },
  { slug: 'badda', en: 'Badda', bn: 'বাড্ডা' },
  { slug: 'cantonment', en: 'Cantonment', bn: 'ক্যান্টনমেন্ট' },
  { slug: 'dakshinkhan', en: 'Dakshinkhan', bn: 'দক্ষিণখান' },
  { slug: 'demra', en: 'Demra', bn: 'ডেমরা' },
  { slug: 'dhanmondi', en: 'Dhanmondi', bn: 'ধানমন্ডি' },
  { slug: 'gulshan', en: 'Gulshan', bn: 'গুলশান' },
  { slug: 'hazaribagh', en: 'Hazaribagh', bn: 'হাজারীবাগ' },
  { slug: 'kafrul', en: 'Kafrul', bn: 'কাফরুল' },
  { slug: 'khilgaon', en: 'Khilgaon', bn: 'খিলগাঁও' },
  { slug: 'khilkhet', en: 'Khilkhet', bn: 'খিলক্ষেত' },
  { slug: 'kotwali', en: 'Kotwali', bn: 'কোতোয়ালি' },
  { slug: 'lalbagh', en: 'Lalbagh', bn: 'লালবাগ' },
  { slug: 'mirpur', en: 'Mirpur', bn: 'মিরপুর' },
  { slug: 'mohammadpur', en: 'Mohammadpur', bn: 'মোহাম্মদপুর' },
  { slug: 'motijheel', en: 'Motijheel', bn: 'মতিঝিল' },
  { slug: 'new-market', en: 'New Market', bn: 'নিউমার্কেট' },
  { slug: 'pallabi', en: 'Pallabi', bn: 'পল্লবী' },
  { slug: 'paltan', en: 'Paltan', bn: 'পল্টন' },
  { slug: 'ramna', en: 'Ramna', bn: 'রমনা' },
  { slug: 'sabujbagh', en: 'Sabujbagh', bn: 'সবুজবাগ' },
  { slug: 'shahbagh', en: 'Shahbagh', bn: 'শাহবাগ' },
  { slug: 'shyampur', en: 'Shyampur', bn: 'শ্যামপুর' },
  { slug: 'sutrapur', en: 'Sutrapur', bn: 'সূত্রাপুর' },
  { slug: 'tejgaon', en: 'Tejgaon', bn: 'তেজগাঁও' },
  { slug: 'tejgaon-ind-area', en: 'Tejgaon Ind. Area', bn: 'তেজগাঁও শিল্পাঞ্চল' },
  { slug: 'uttara', en: 'Uttara', bn: 'উত্তরা' },
  { slug: 'uttar-khan', en: 'Uttar Khan', bn: 'উত্তরখান' },
  { slug: 'bangshal', en: 'Bangshal', bn: 'বংশাল' },
  { slug: 'chak-bazar', en: 'Chak Bazar', bn: 'চকবাজার' },
  { slug: 'darus-salam', en: 'Darus Salam', bn: 'দারুস সালাম' },
  { slug: 'gendaria', en: 'Gendaria', bn: 'গেন্ডারিয়া' },
  { slug: 'jatrabari', en: 'Jatrabari', bn: 'যাত্রাবাড়ী' },
  { slug: 'kadamtali', en: 'Kadamtali', bn: 'কদমতলী' },
  { slug: 'kalabagan', en: 'Kalabagan', bn: 'কলাবাগান' },
  { slug: 'kamrangir-char', en: 'Kamrangir Char', bn: 'কামরাঙ্গীরচর' },
  { slug: 'rampura', en: 'Rampura', bn: 'রামপুরা' },
  { slug: 'shah-ali', en: 'Shah Ali', bn: 'শাহ আলী' },
  { slug: 'sher-e-bangla-nagar', en: 'Sher-e-bangla Nagar', bn: 'শেরেবাংলা নগর' },
  { slug: 'turag', en: 'Turag', bn: 'তুরাগ' },
];
