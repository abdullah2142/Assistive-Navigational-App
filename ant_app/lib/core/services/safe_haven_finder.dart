import 'dart:math' as math;

// The same LatLng every other service in this app speaks — routing,
// planning and the narrator all use google_maps_flutter's. latlong2 exists
// here too (flutter_map needs it) and the two are not interchangeable, so
// picking the wrong one produces a type error at every boundary.
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../features/onboarding/models/saved_place.dart';

/// Where a safe haven came from. Decides what the app says, and how much it
/// can be trusted when nothing else is reachable.
enum HavenSource {
  /// A place the user saved themselves — home, a relative, their clinic.
  /// Has coordinates already, so it works with no network at all.
  savedPlace,

  /// The free-text "somewhere you feel safe" from onboarding. Needs
  /// geocoding, so it needs a network.
  statedSafePlace,

  /// A hospital or police station discovered nearby. Needs a network, and
  /// the user has probably never been there.
  discovered,
}

/// A candidate refuge.
class SafeHaven {
  const SafeHaven({
    required this.label,
    required this.source,
    this.location,
    this.address,
    this.distanceMeters,
  });

  final String label;
  final HavenSource source;

  /// Null for a [HavenSource.statedSafePlace] that has not been geocoded.
  final LatLng? location;
  final String? address;
  final double? distanceMeters;

  SafeHaven withDistanceFrom(LatLng origin) {
    if (location == null) return this;
    return SafeHaven(
      label: label,
      source: source,
      location: location,
      address: address,
      distanceMeters: SafeHavenFinder.metresBetween(origin, location!),
    );
  }
}

/// Chooses where to send someone who has just triggered the Magic Button.
///
/// ## Why this is not simply "the nearest hospital"
///
/// The module plan says to query for hospitals and police within a
/// kilometre and route to the closest. That is the right instinct and the
/// wrong first choice for these users.
///
/// A blind person in trouble at night does not want to arrive alone at the
/// gate of a hospital they have never been to, in a city where that gate
/// may be a guard, a queue and an unfamiliar layout. They want somewhere
/// they can get *into* — where the way in is known, and ideally where
/// somebody knows them. Onboarding already collects exactly that, twice
/// over: saved places, and a free-text "somewhere you feel safe".
///
/// So familiarity is ranked above proximity, and proximity only decides
/// between options of equal familiarity. A hospital 200 m away still loses
/// to their own home 600 m away, and that is deliberate.
///
/// ## And why offline-capability breaks the tie
///
/// Saved places carry coordinates. The stated safe place is a string that
/// needs a geocoder, and discovered places need a live query. An emergency
/// is disproportionately likely to coincide with no data — it is one of the
/// reasons the SMS path exists — so a haven that still works with the radio
/// off is worth more than one that is marginally closer.
class SafeHavenFinder {
  const SafeHavenFinder._();

  /// Beyond this, a discovered hospital or police station is not offered.
  ///
  /// The plan's 1 km. Someone frightened is not walking further than that to
  /// a place they do not know, and offering it would crowd out the honest
  /// answer, which is "stay where you are and wait for the people I have
  /// just messaged".
  static const double discoveredRadiusMeters = 1000;

  /// Saved-place kinds that are refuges rather than errands.
  ///
  /// Work and school are excluded on purpose: they are places the user goes,
  /// not places they retreat to, and at 2am they are locked. Worship is
  /// included — a mosque is open, staffed, and in Dhaka is a place a person
  /// in distress can reasonably present themselves.
  static const _refugeKinds = {
    SavedPlaceKind.home,
    SavedPlaceKind.family,
    SavedPlaceKind.medical,
    SavedPlaceKind.worship,
  };

  /// Every haven worth considering, best first.
  ///
  /// [discovered] are hospitals and police stations already found nearby;
  /// pass none when offline and the list simply gets shorter rather than
  /// the function failing.
  static List<SafeHaven> rank({
    required LatLng origin,
    required List<SavedPlace> savedPlaces,
    String? statedSafePlace,
    List<SafeHaven> discovered = const [],
  }) {
    final refuges = savedPlaces.where((p) => _refugeKinds.contains(p.kind));

    // `isRoutable` is true for a place with *either* coordinates or an
    // address, so it cannot be the test for "has coordinates" — reading
    // `lat!` behind it threw a null check on a saved place that only ever
    // had an address, which is a crash in the middle of an emergency.
    // Those places are still refuges; they just need a geocoder, so they
    // are ranked below the ones that work with the radio off.
    final saved = refuges
        .where((p) => p.hasCoordinates)
        .map((p) => SafeHaven(
              label: p.label,
              source: HavenSource.savedPlace,
              location: LatLng(p.lat!, p.lng!),
              address: p.address,
            ).withDistanceFrom(origin))
        .toList()
      ..sort((a, b) => (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));

    // Equally familiar, but unusable without a network, and with no
    // distance to sort by — so they keep the order the user saved them in.
    final savedByAddress = refuges
        .where((p) => !p.hasCoordinates && p.address.trim().isNotEmpty)
        .map((p) => SafeHaven(
              label: p.label,
              source: HavenSource.savedPlace,
              address: p.address,
            ))
        .toList();

    final stated = (statedSafePlace != null && statedSafePlace.trim().isNotEmpty)
        ? [
            SafeHaven(
              label: statedSafePlace.trim(),
              source: HavenSource.statedSafePlace,
              address: statedSafePlace.trim(),
            )
          ]
        : <SafeHaven>[];

    final nearby = discovered
        .map((h) => h.withDistanceFrom(origin))
        .where((h) => (h.distanceMeters ?? double.infinity) <= discoveredRadiusMeters)
        .toList()
      ..sort((a, b) => (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));

    // Familiarity first, distance only within a tier. See the class comment
    // for why a known home beats a nearer unknown hospital.
    return [...saved, ...savedByAddress, ...stated, ...nearby];
  }

  /// The single best haven, or null when the user has given us nothing and
  /// nothing was found nearby.
  ///
  /// Null is a real answer and must be spoken as one: "stay where you are,
  /// I have messaged your contacts" is honest, where inventing a
  /// destination is not.
  static SafeHaven? best({
    required LatLng origin,
    required List<SavedPlace> savedPlaces,
    String? statedSafePlace,
    List<SafeHaven> discovered = const [],
  }) {
    final ranked = rank(
      origin: origin,
      savedPlaces: savedPlaces,
      statedSafePlace: statedSafePlace,
      discovered: discovered,
    );
    return ranked.isEmpty ? null : ranked.first;
  }

  /// Metres between two points. Haversine on a spherical earth — accurate
  /// to well within a metre at these distances.
  static double metresBetween(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    final dLat = _radians(b.latitude - a.latitude);
    final dLng = _radians(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_radians(a.latitude)) *
            math.cos(_radians(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }

  /// Compass bearing from [a] to [b], in degrees clockwise from north.
  ///
  /// Used for the offline answer. When there is no network there is no
  /// route, but "your home is 600 metres to the north-east" is still
  /// something a person can act on, and is far better than silence.
  static double bearingDegrees(LatLng a, LatLng b) {
    final dLng = _radians(b.longitude - a.longitude);
    final lat1 = _radians(a.latitude);
    final lat2 = _radians(b.latitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    final deg = _degrees(math.atan2(y, x));
    return (deg + 360) % 360;
  }

  /// Eight-point compass name for [bearing], as an index into the caller's
  /// localized list — the names themselves are not English strings here.
  static int compassIndex(double bearing) => (((bearing + 22.5) % 360) ~/ 45).toInt();

  static double _radians(double degrees) => degrees * math.pi / 180;
  static double _degrees(double radians) => radians * 180 / math.pi;
}
