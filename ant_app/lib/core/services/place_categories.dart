/// Recognising "the nearest *kind of place*" as distinct from a place name.
///
/// ## The bug this exists for
///
/// `RoutePlanningService.plan` had exactly one way to turn a destination into
/// a point: Nominatim, which answers *"where is this name"*. So "the nearest
/// toilet" was searched for as though `nearest toilet` were the name of
/// somewhere in Dhaka, found nothing, and came back `destination_not_found` —
/// which the assistant reports by asking which area the user means, about a
/// place they never named. Reported from the 22 September session as
/// "nearest bathroom, nearest restaurant, anything like that didnt route me",
/// and it is the whole of the stress test's Category 1.
///
/// The app already had the right call for this — `RoutingService
/// .nearbyRefuges`, an Overpass `around:` query — but it was wired only to
/// the emergency safe-haven finder and only for hospital/clinic/police.
///
/// ## Why a table and not the model
///
/// The assistant is told, correctly, that no live POI database exists and not
/// to invent businesses. It cannot name "the nearest toilet" because it does
/// not know one — but it does not need to. It only has to pass the *category*
/// through, and this turns that word into the OSM tags that answer it.
///
/// Matching is substring-based for Bangla (a suffixed `টয়লেটে` must still
/// match `টয়লেট`) and whole-word for Latin, which is the same split
/// `LocalIntentMatcher` uses and for the same reason.
library;

/// A kind of place that can be searched for by proximity rather than by name.
class PlaceCategory {
  const PlaceCategory({
    required this.id,
    required this.osmFilters,
    required this.latin,
    required this.bangla,
    this.googleType,
  });

  /// Stable id, used in logs and to name the category back to the user.
  final String id;

  /// Overpass tag filters, e.g. `["amenity"="toilets"]`. More than one
  /// because OSM spreads a single human category over several tags — a
  /// pharmacy is `amenity=pharmacy` and also `shop=chemist`.
  final List<String> osmFilters;

  /// Google Places `includedPrimaryTypes` value, when the Places backend is
  /// the one answering.
  final String? googleType;

  final List<String> latin;
  final List<String> bangla;
}

/// Ordered most-specific first: `pharmacy` must be tested before the generic
/// `shop`, or "medicine shop" resolves to a grocery.
const List<PlaceCategory> placeCategories = [
  PlaceCategory(
    id: 'toilet',
    osmFilters: ['"amenity"="toilets"'],
    googleType: 'public_bathroom',
    latin: [
      'toilet', 'toilets', 'restroom', 'bathroom', 'washroom', 'loo', 'wc',
      'lavatory', 'pee', 'urinal',
      'toilet ta', 'bathroom ta', 'washroom ta', 'prosrab', 'peshab',
    ],
    bangla: ['টয়লেট', 'শৌচাগার', 'ওয়াশরুম', 'বাথরুম', 'প্রস্রাব', 'পেশাব'],
  ),
  PlaceCategory(
    id: 'pharmacy',
    osmFilters: ['"amenity"="pharmacy"', '"shop"="chemist"'],
    googleType: 'pharmacy',
    latin: ['pharmacy', 'chemist', 'drugstore', 'medicine', 'medicine shop',
      'dawa', 'osudh', 'oshudh', 'farmesi'],
    bangla: ['ফার্মেসি', 'ওষুধ', 'ঔষধ', 'ওসুধ', 'মেডিসিন'],
  ),
  PlaceCategory(
    id: 'hospital',
    osmFilters: ['"amenity"="hospital"', '"amenity"="clinic"'],
    googleType: 'hospital',
    latin: ['hospital', 'clinic', 'emergency room', 'doctor', 'daktar',
      'hashpatal', 'clinic ta'],
    bangla: ['হাসপাতাল', 'ক্লিনিক', 'ডাক্তার'],
  ),
  PlaceCategory(
    id: 'restaurant',
    osmFilters: ['"amenity"="restaurant"', '"amenity"="fast_food"', '"amenity"="cafe"'],
    googleType: 'restaurant',
    latin: ['restaurant', 'food', 'eat', 'hungry', 'cafe', 'canteen', 'hotel',
      'khabar', 'khete', 'khide', 'restora', 'restoran'],
    bangla: ['রেস্টুরেন্ট', 'রেস্তোরাঁ', 'খাবার', 'খেতে', 'খিদে', 'ক্যাফে', 'ক্যান্টিন'],
  ),
  PlaceCategory(
    id: 'water',
    osmFilters: ['"amenity"="drinking_water"', '"amenity"="water_point"'],
    latin: ['drinking water', 'water fountain', 'thirsty', 'water',
      'pani', 'paani', 'tesh', 'testa'],
    bangla: ['পানি', 'খাবার পানি', 'তেষ্টা', 'পিপাসা'],
  ),
  PlaceCategory(
    id: 'mosque',
    osmFilters: ['"amenity"="place_of_worship"'],
    googleType: 'mosque',
    latin: ['mosque', 'masjid', 'prayer', 'namaz', 'jummah', 'jumma'],
    bangla: ['মসজিদ', 'নামাজ', 'জুম্মা'],
  ),
  PlaceCategory(
    id: 'atm',
    osmFilters: ['"amenity"="atm"', '"amenity"="bank"'],
    googleType: 'atm',
    latin: ['atm', 'cash machine', 'bank', 'cash'],
    bangla: ['এটিএম', 'ব্যাংক', 'ব্যাঙ্ক', 'টাকা'],
  ),
  PlaceCategory(
    id: 'bus_stop',
    osmFilters: ['"highway"="bus_stop"', '"amenity"="bus_station"'],
    googleType: 'bus_station',
    latin: ['bus stop', 'bus stand', 'bus station', 'bus counter',
      'bus stop ta', 'bashstand'],
    bangla: ['বাস স্ট্যান্ড', 'বাসস্ট্যান্ড', 'বাস স্টপ', 'বাস কাউন্টার'],
  ),
  PlaceCategory(
    id: 'police',
    osmFilters: ['"amenity"="police"'],
    googleType: 'police',
    latin: ['police', 'police station', 'thana', 'thanaa'],
    bangla: ['পুলিশ', 'থানা'],
  ),
  PlaceCategory(
    id: 'shop',
    osmFilters: ['"shop"="convenience"', '"shop"="supermarket"', '"shop"="general"'],
    googleType: 'convenience_store',
    latin: ['shop', 'store', 'grocery', 'supermarket', 'dokan', 'dokaan'],
    bangla: ['দোকান', 'মুদি', 'সুপারশপ', 'বাজার'],
  ),
  PlaceCategory(
    id: 'bench',
    osmFilters: ['"amenity"="bench"', '"leisure"="park"'],
    googleType: 'park',
    latin: ['bench', 'sit down', 'somewhere to sit', 'rest', 'park',
      'boshte', 'bosar', 'bishram'],
    bangla: ['বেঞ্চ', 'বসতে', 'বসার', 'বিশ্রাম', 'পার্ক'],
  ),
];

/// Words that mark a destination as "whichever one is closest" rather than a
/// specific named place. Their presence is a strong signal on its own, but a
/// bare category word ("a toilet") is treated the same way — there is no
/// named place in Dhaka called "toilet".
const List<String> nearestMarkersLatin = [
  'nearest', 'closest', 'near', 'nearby', 'around here', 'close by', 'any',
  'a ', 'some', 'kache', 'kachakachi', 'nikot',
];
const List<String> nearestMarkersBangla = [
  'কাছের', 'কাছাকাছি', 'নিকটতম', 'নিকট', 'আশেপাশে', 'আশপাশে', 'সবচেয়ে কাছে',
];

/// The category [query] is asking for, or null when it names a specific place.
///
/// Bangla is matched as a substring because the language suffixes onto the
/// noun — `টয়লেটে` ("to the toilet") must match `টয়লেট`. Latin is matched on
/// word boundaries so `water` does not fire inside `Waterloo`, with the
/// multi-word entries checked as substrings since they cannot be tokens.
PlaceCategory? categoryFor(String query) {
  final lower = query.toLowerCase().trim();
  if (lower.isEmpty) return null;
  final words = lower
      .split(RegExp(r'[^a-z0-9ঀ-৿]+'))
      .where((w) => w.isNotEmpty)
      .toSet();

  for (final category in placeCategories) {
    for (final term in category.bangla) {
      if (lower.contains(term)) return category;
    }
    for (final term in category.latin) {
      final trimmed = term.trim();
      if (trimmed.contains(' ')) {
        if (lower.contains(trimmed)) return category;
      } else if (words.contains(trimmed)) {
        return category;
      }
    }
  }
  return null;
}
