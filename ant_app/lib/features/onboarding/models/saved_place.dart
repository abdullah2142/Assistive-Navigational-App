/// A place this user goes to often, saved so they can ask for it by name.
///
/// ## Why this is worth its own model
///
/// "Take me to work" has to be answerable without geocoding, without a
/// language model, and without asking the user where work is — every time.
/// Those three things are exactly what makes the difference between a
/// three-second reply and a fifteen-second one, and for a blind user
/// standing on a footpath waiting to start walking, that gap is the whole
/// experience.
///
/// It also solves a problem geocoding genuinely cannot. "My sister's
/// house", "the clinic", "school" are not searchable place names — no
/// geocoder on earth resolves them, and Dhaka addresses are frequently
/// informal enough ("behind the third mosque on Road 8") that even a real
/// address may not resolve either. Saving the coordinates once, when the
/// user is somewhere calm and can be asked properly, is what makes those
/// destinations reachable at all.
class SavedPlace {
  const SavedPlace({
    required this.label,
    this.address = '',
    this.lat,
    this.lng,
    this.kind = SavedPlaceKind.other,
  });

  /// What the user calls it, in their own words — "work", "Ma's house",
  /// "স্কুল". Matched against loosely (see `SavedPlaceMatcher`), so this is
  /// a name, not a key.
  final String label;

  /// The written address, when there is one. Geocoded on first use if
  /// [lat]/[lng] are still null.
  final String address;

  /// Resolved coordinates, once known.
  ///
  /// Cached deliberately: a saved place that has been geocoded once never
  /// needs geocoding again, which removes a network round trip from the
  /// most common routing request the app will ever serve. It also means a
  /// frequent destination stays reachable with no connectivity at all —
  /// the "Graceful Offline Degradation" rule applied to the thing the user
  /// actually does every day.
  final double? lat;
  final double? lng;

  /// Only used to pick an icon and to seed sensible spoken synonyms
  /// ("home"/"house"/"বাসা"). Never a unique key — a user may well have two
  /// places they think of as relatives' houses.
  final SavedPlaceKind kind;

  bool get hasCoordinates => lat != null && lng != null;

  /// Whether this is worth keeping at all. A place with neither an address
  /// nor coordinates is just a name that cannot be routed to, which would
  /// fail confusingly later rather than being rejected now.
  bool get isRoutable => hasCoordinates || address.trim().isNotEmpty;

  SavedPlace copyWith({String? label, String? address, double? lat, double? lng, SavedPlaceKind? kind}) =>
      SavedPlace(
        label: label ?? this.label,
        address: address ?? this.address,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        kind: kind ?? this.kind,
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'address': address,
        'lat': lat,
        'lng': lng,
        'kind': kind.name,
      };

  factory SavedPlace.fromJson(Map<String, dynamic> json) => SavedPlace(
        label: json['label'] as String? ?? '',
        address: json['address'] as String? ?? '',
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
        kind: SavedPlaceKind.fromFirestore(json['kind'] as String?),
      );
}

enum SavedPlaceKind {
  home,
  work,
  school,
  family,
  medical,
  worship,
  other;

  static SavedPlaceKind fromFirestore(String? value) =>
      SavedPlaceKind.values.where((k) => k.name == value).firstOrNull ?? SavedPlaceKind.other;
}
