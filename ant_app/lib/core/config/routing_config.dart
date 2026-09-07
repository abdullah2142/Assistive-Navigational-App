/// Which backend [RoutingService] uses for geocoding, walking directions and
/// nearby-place discovery.
///
/// ## Google is the intended backend, and the reason is safety
///
/// This started as OpenStreetMap-only because `MapsConfig.apiKey` had no
/// billing attached and both Geocoding and Directions returned
/// `REQUEST_DENIED` (confirmed live 2026-09-02). That got the feature
/// working, but it carries a defect that matters more for this app than for
/// almost any other:
///
/// **The public OSRM demo server does not run a pedestrian profile.** Its
/// `foot` endpoint returns byte-identical distance *and* duration to its
/// `driving` endpoint on the same two points (confirmed live 2026-09-03) —
/// it is car routing wearing a walking label. [RoutingService] compensates
/// by discarding OSRM's duration and recomputing it from distance at a
/// walking pace, but that only corrects the number the app *says*. The
/// geometry is still a car route: it can follow a flyover approach, a road
/// with no footpath, or miss a pedestrian cut-through entirely.
///
/// For a sighted user that is an annoyance. For a blind user following
/// spoken turn-by-turn instructions with no way to see that the road has no
/// pavement, it is the app confidently narrating a route into traffic. That
/// is the single reason Google's Routes API — which has a real `WALK`
/// travel mode — is worth attaching a billing account for.
///
/// Geocoding recall is the second reason. The whole input method here is
/// someone *saying* a destination. Nominatim is volunteer OSM data and
/// Dhaka POI coverage is thin, so "take me to Labaid" is a coin flip. A
/// navigation app that cannot resolve the destination has not degraded
/// gracefully; it has failed at the only thing it was asked to do.
///
/// And the third: neither Nominatim nor the OSRM demo server owes this app
/// anything. Nominatim's usage policy caps absolutely at 1 request/second
/// with no heavy use, and OSRM's demo server carries no uptime guarantee at
/// all. Every distributed APK shares that one quota, so the realistic
/// failure is a tester reporting "routing is broken" when it is really a
/// 429 from a volunteer server.
///
/// ## Why OSM stays anyway
///
/// Not as the primary, but as the fallback. Swapping one single point of
/// failure for another would be no improvement, and the rest of this
/// codebase degrades rather than fails. If the key is revoked, the quota is
/// hit, or billing lapses, routing keeps working — worse, and honestly
/// labelled as worse (see [RouteCandidate.isPedestrianProfile]), instead of
/// going dark.
///
/// ## Turning Google on
///
/// ```
/// flutter run --dart-define=ROUTING_PREFER_GOOGLE=true
/// ```
///
/// Defaults to off, because it costs real money the moment it is wrong and
/// because it needs three APIs enabled on a billing-attached project first
/// (Geocoding API, Routes API, Places API — see `README.md`). Flip it only
/// once those exist and the key is restricted.
library;

/// Which service answers geocoding, routing and place-discovery calls.
enum RoutingBackend {
  /// Google Maps Platform: Geocoding API, Routes API, Places API.
  google,

  /// Nominatim, the public OSRM demo server, and Overpass.
  openStreetMap,
}

class RoutingConfig {
  RoutingConfig._();

  /// Whether Google is tried first for geocoding, routing and discovery.
  ///
  /// Compile-time so it can be flipped per-build without a code change —
  /// the same shape as `EmergencyConfig.liveDispatch`, and for the same
  /// reason: a build that spends money should be a deliberate build.
  static const bool preferGoogle =
      bool.fromEnvironment('ROUTING_PREFER_GOOGLE', defaultValue: false);

  /// Whether OSM answers when Google cannot.
  ///
  /// On by default. Turn it off only to *prove* the Google path works —
  /// with it on, a misconfigured key looks like a working app, because
  /// every call quietly succeeds through the fallback. That is exactly the
  /// failure mode worth being able to switch off during setup.
  ///
  /// ```
  /// flutter run --dart-define=ROUTING_PREFER_GOOGLE=true --dart-define=ROUTING_OSM_FALLBACK=false
  /// ```
  static const bool allowOsmFallback =
      bool.fromEnvironment('ROUTING_OSM_FALLBACK', defaultValue: true);

  static RoutingBackend get primary =>
      preferGoogle ? RoutingBackend.google : RoutingBackend.openStreetMap;
}
