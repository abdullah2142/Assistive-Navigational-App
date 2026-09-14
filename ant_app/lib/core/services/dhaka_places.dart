/// Place names the recognizer should expect to hear.
///
/// Reported directly: a user says a Dhaka location and Cloud STT returns
/// something unrelated. That is the normal failure mode for proper nouns —
/// a general model is weighted towards common vocabulary, and Dhaka thana
/// names are rare words that sound like ordinary ones.
///
/// Google's Speech-to-Text takes `speechContexts`: a list of phrases to
/// treat as more likely, with a boost. It is built for exactly this, it costs
/// nothing per request, and this app never used it.
///
/// Both scripts are always supplied, whichever language the session is in.
/// A `bn-BD` recognizer regularly returns a Bangla-script approximation of an
/// English name, and an `en-US` one returns a Latin approximation of a Bangla
/// one — the same reason the emergency vocabulary keeps `হেল্প` beside `help`.
library;

/// The 41 Dhaka Metropolitan thanas, in both scripts.
///
/// The same list Module 4 already carries as its crime baseline
/// (`functions/data/dhaka_thana_crime_seed.js`) — kept in step with it
/// deliberately, since a thana the router can score is one a user can ask for.
const dhakaThanas = <({String en, String bn})>[
  (en: 'Adabor', bn: 'আদাবর'),
  (en: 'Badda', bn: 'বাড্ডা'),
  (en: 'Bangshal', bn: 'বংশাল'),
  (en: 'Biman Bandar', bn: 'বিমানবন্দর'),
  (en: 'Cantonment', bn: 'ক্যান্টনমেন্ট'),
  (en: 'Chak Bazar', bn: 'চকবাজার'),
  (en: 'Dakshinkhan', bn: 'দক্ষিণখান'),
  (en: 'Darus Salam', bn: 'দারুস সালাম'),
  (en: 'Demra', bn: 'ডেমরা'),
  (en: 'Dhanmondi', bn: 'ধানমন্ডি'),
  (en: 'Gendaria', bn: 'গেন্ডারিয়া'),
  (en: 'Gulshan', bn: 'গুলশান'),
  (en: 'Hazaribagh', bn: 'হাজারীবাগ'),
  (en: 'Jatrabari', bn: 'যাত্রাবাড়ী'),
  (en: 'Kadamtali', bn: 'কদমতলী'),
  (en: 'Kafrul', bn: 'কাফরুল'),
  (en: 'Kalabagan', bn: 'কলাবাগান'),
  (en: 'Kamrangir Char', bn: 'কামরাঙ্গীরচর'),
  (en: 'Khilgaon', bn: 'খিলগাঁও'),
  (en: 'Khilkhet', bn: 'খিলক্ষেত'),
  (en: 'Kotwali', bn: 'কোতোয়ালি'),
  (en: 'Lalbagh', bn: 'লালবাগ'),
  (en: 'Mirpur', bn: 'মিরপুর'),
  (en: 'Mohammadpur', bn: 'মোহাম্মদপুর'),
  (en: 'Motijheel', bn: 'মতিঝিল'),
  (en: 'New Market', bn: 'নিউমার্কেট'),
  (en: 'Pallabi', bn: 'পল্লবী'),
  (en: 'Paltan', bn: 'পল্টন'),
  (en: 'Ramna', bn: 'রমনা'),
  (en: 'Rampura', bn: 'রামপুরা'),
  (en: 'Sabujbagh', bn: 'সবুজবাগ'),
  (en: 'Shah Ali', bn: 'শাহ আলী'),
  (en: 'Shahbagh', bn: 'শাহবাগ'),
  (en: 'Sher-e-bangla Nagar', bn: 'শেরেবাংলা নগর'),
  (en: 'Shyampur', bn: 'শ্যামপুর'),
  (en: 'Sutrapur', bn: 'সূত্রাপুর'),
  (en: 'Tejgaon', bn: 'তেজগাঁও'),
  (en: 'Tejgaon Ind. Area', bn: 'তেজগাঁও শিল্পাঞ্চল'),
  (en: 'Turag', bn: 'তুরাগ'),
  (en: 'Uttar Khan', bn: 'উত্তরখান'),
  (en: 'Uttara', bn: 'উত্তরা'),
];

/// Areas and landmarks people actually name, which are not thanas.
///
/// A thana is an administrative unit; almost nobody says "take me to
/// Shahbagh Thana". They say a neighbourhood, a market, a hospital or a
/// roundabout, and those are the words the recognizer has to get right.
const dhakaLandmarks = <({String en, String bn})>[
  (en: 'Dhanmondi 27', bn: 'ধানমন্ডি ২৭'),
  (en: 'Dhanmondi 32', bn: 'ধানমন্ডি ৩২'),
  (en: 'Gulshan 1', bn: 'গুলশান ১'),
  (en: 'Gulshan 2', bn: 'গুলশান ২'),
  (en: 'Banani', bn: 'বনানী'),
  (en: 'Farmgate', bn: 'ফার্মগেট'),
  (en: 'Karwan Bazar', bn: 'কারওয়ান বাজার'),
  (en: 'New Market', bn: 'নিউ মার্কেট'),
  (en: 'Shahbagh', bn: 'শাহবাগ'),
  (en: 'Science Lab', bn: 'সায়েন্স ল্যাব'),
  (en: 'Mirpur 1', bn: 'মিরপুর ১'),
  (en: 'Mirpur 10', bn: 'মিরপুর ১০'),
  (en: 'Mirpur 11', bn: 'মিরপুর ১১'),
  (en: 'Mohakhali', bn: 'মহাখালী'),
  (en: 'Motijheel', bn: 'মতিঝিল'),
  (en: 'Uttara Sector 7', bn: 'উত্তরা সেক্টর ৭'),
  (en: 'Uttara Sector 10', bn: 'উত্তরা সেক্টর ১০'),
  (en: 'Bashundhara', bn: 'বসুন্ধরা'),
  (en: 'Jatrabari', bn: 'যাত্রাবাড়ী'),
  (en: 'Gabtoli', bn: 'গাবতলী'),
  (en: 'Sayedabad', bn: 'সায়েদাবাদ'),
  (en: 'Kamalapur', bn: 'কমলাপুর'),
  (en: 'Nilkhet', bn: 'নীলক্ষেত'),
  (en: 'Elephant Road', bn: 'এলিফ্যান্ট রোড'),
  (en: 'Satmasjid Road', bn: 'সাতমসজিদ রোড'),
  (en: 'Mint Road', bn: 'মিন্টো রোড'),
  (en: 'Bailey Road', bn: 'বেইলি রোড'),
  (en: 'Agargaon', bn: 'আগারগাঁও'),
  (en: 'Shyamoli', bn: 'শ্যামলী'),
  (en: 'Kalabagan', bn: 'কলাবাগান'),
  (en: 'Rampura', bn: 'রামপুরা'),
  (en: 'Malibagh', bn: 'মালিবাগ'),
  (en: 'Moghbazar', bn: 'মগবাজার'),
  (en: 'Panthapath', bn: 'পান্থপথ'),
  (en: 'Tejgaon', bn: 'তেজগাঁও'),
  (en: 'Bangla Motor', bn: 'বাংলামোটর'),
  (en: 'Zigatola', bn: 'জিগাতলা'),
  (en: 'Lalmatia', bn: 'লালমাটিয়া'),
  (en: 'Azimpur', bn: 'আজিমপুর'),
  (en: 'Narayanganj', bn: 'নারায়ণগঞ্জ'),
  (en: 'Savar', bn: 'সাভার'),
];

/// Every known Dhaka place name, both scripts, deduplicated.
///
/// Order matters a little: Google caps the useful size of a phrase-hint list,
/// and the landmarks come first because they are what people actually say.
List<String> get dhakaPlacePhrases {
  final seen = <String>{};
  final out = <String>[];
  for (final place in [...dhakaLandmarks, ...dhakaThanas]) {
    for (final name in [place.bn, place.en]) {
      if (name.trim().isEmpty) continue;
      if (seen.add(name)) out.add(name);
    }
  }
  return out;
}

/// The phrase list for a session where the user may name a place.
///
/// [savedPlaceLabels] and the addresses come first and are repeated nowhere
/// else: what somebody calls their own home ("Ma's house", "আম্মার বাসা") is a
/// far stronger hint than any gazetteer entry, and it is the name they will
/// actually say.
///
/// Capped, because a phrase list is not free at the recognizer's end — Google
/// treats a very large context as weaker, not stronger, since everything being
/// likely is the same as nothing being likely.
List<String> placeNameHints({
  List<String> savedPlaceLabels = const [],
  String? homeAddress,
  String? safePlaceAddress,
  int limit = 400,
}) {
  final seen = <String>{};
  final out = <String>[];
  void add(String? value) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty || out.length >= limit) return;
    if (seen.add(trimmed)) out.add(trimmed);
  }

  for (final label in savedPlaceLabels) {
    add(label);
  }
  add(homeAddress);
  add(safePlaceAddress);
  for (final phrase in dhakaPlacePhrases) {
    add(phrase);
  }
  return out;
}
