import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import 'place_categories.dart';

import '../config/maps_config.dart';
import '../config/routing_config.dart';
import 'api_budget.dart';

/// A generic User-Agent identifying this app, not a specific user — required
/// by Nominatim's usage policy (every request must identify the calling
/// application) and good practice for the OSRM demo server too. Points at
/// the repo rather than a personal contact address since this string ships
/// inside the client app itself, publicly inspectable.
const String _osmUserAgent = 'ANT-AssistiveNavigationalApp/1.0 (+https://github.com/abdullah2142/Assistive-Navigational-App)';

/// Plain average walking speed used to compute [RouteCandidate.durationSeconds]
/// when the backend's own reported duration isn't trustworthy for
/// pedestrians (see `RoutingConfig`'s doc comment — this is the public OSRM
/// demo server's situation today). ~4.5 km/h — a touch under the often-cited
/// "average adult" 5 km/h, since this app's users skew toward mobility
/// aids/vision accommodations that plausibly mean a slower typical pace.
const double _walkingSpeedMps = 1.25;

/// A single manoeuvre along a route — "turn left onto Satmasjid Road".
///
/// This is what makes spoken turn-by-turn navigation possible at all. The
/// overview polyline alone can say "you are 1.2 km away" and point an arrow;
/// it cannot say *when* to turn or *which way*, which is the only part a
/// user who cannot see the map actually needs.
class RouteStep {
  const RouteStep({
    required this.location,
    required this.distanceMeters,
    required this.maneuver,
    this.streetName = '',
    this.bearingAfter = 0,
  });

  /// Where the manoeuvre happens — the point the user has to reach before
  /// doing it.
  final LatLng location;

  /// Length of the leg that *ends* at [location], i.e. how far the user
  /// walks before this manoeuvre.
  final double distanceMeters;

  /// Normalized manoeuvre. Backend-agnostic on purpose: OSRM and Google
  /// describe turns completely differently (`{type, modifier}` versus a
  /// blob of HTML), and neither vocabulary should leak into the narration
  /// layer or into the bilingual strings.
  final ManeuverKind maneuver;

  /// The road being turned onto, when the backend gives one. Spoken when
  /// present ("turn left onto Satmasjid Road") and simply omitted when not —
  /// unnamed lanes and alleys are extremely common in Dhaka, and "turn left"
  /// on its own is still a complete, usable instruction.
  final String streetName;

  /// Compass bearing (0-360) to travel after completing this manoeuvre.
  final double bearingAfter;
}

/// Pulls the road name out of a Routes API step's English instruction.
///
/// Routes API has no street-name field at all — OSRM's `name` has no
/// counterpart — so "turn left onto Satmasjid Road" came out as a bare "turn
/// left" on the Google backend, which is the backend this app is migrating
/// *to*. Losing the road name is not cosmetic for someone who cannot see a
/// street sign: it is the only way to confirm they turned onto the right
/// road.
///
/// Parsing prose is a compromise, and is treated as one. It is safe here for
/// one specific reason: `languageCode` is pinned to `en-US` on every request
/// (see `_walkingRoutesGoogle`'s body), so the phrasing cannot drift with the
/// user's locale — and anything unrecognized yields an empty string, which
/// every consumer already handles, because unnamed lanes are everywhere in
/// Dhaka. Only the name is taken; the sentence around it is still built in
/// the user's own language from [ManeuverKind].
String streetNameFromGoogleInstruction(String? instruction) {
  final text = instruction?.trim() ?? '';
  if (text.isEmpty) return '';
  // "Turn left onto X", "Continue onto X", "Head north on X".
  final match = RegExp(r'\b(?:onto|on)\s+(.+)$', caseSensitive: false).firstMatch(text);
  if (match == null) return '';
  var name = match.group(1)!.trim();
  // Routes API appends destination/side notes after a comma or a dash:
  // "onto Satmasjid Road, Destination will be on the right".
  for (final separator in [',', ' - ', ' – ']) {
    final cut = name.indexOf(separator);
    if (cut > 0) name = name.substring(0, cut).trim();
  }
  // The tail of a destination note ("on the right"), not a road. Nothing is
  // better than a wrong road name.
  if (RegExp(r'^(?:the |your )?(?:right|left)$', caseSensitive: false).hasMatch(name)) return '';
  return name;
}

/// The road a route mostly follows — the "via Satmasjid Road" in a spoken
/// route summary.
///
/// One line of context that turns "showing the way to Labaid" into something
/// the user can agree or object to. Reported directly: after asking to be
/// taken somewhere, the assistant said only that the route passed a risky
/// area, and the user wanted to know *which way* it was taking them.
///
/// The longest single named stretch, not the first one — a route usually
/// starts on whichever lane the user is standing in, which identifies
/// nothing. Empty when no step carries a name, which is common in Dhaka and
/// simply means the sentence is built without it.
String routeViaSummary(List<RouteStep> steps) {
  final byRoad = <String, double>{};
  for (final step in steps) {
    final name = step.streetName.trim();
    if (name.isEmpty) continue;
    byRoad[name] = (byRoad[name] ?? 0) + step.distanceMeters;
  }
  if (byRoad.isEmpty) return '';
  return byRoad.entries.reduce((a, b) => b.value > a.value ? b : a).key;
}

/// The turn vocabulary this app speaks, independent of any routing backend.
enum ManeuverKind {
  depart,
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uTurn,
  roundabout,
  crossing,
  arrive,
}

/// Maps OSRM's `{type, modifier}` pair onto [ManeuverKind].
///
/// `modifier` carries the direction for most types; `type` only decides the
/// shape for the few that have no modifier (depart/arrive/roundabout).
/// Anything unrecognized becomes [ManeuverKind.straight] rather than being
/// dropped — a step that exists but can't be named is still a real point on
/// the route, and silently discarding it would leave the narrator thinking
/// the next turn is further away than it is.
ManeuverKind maneuverFromOsrm(String? type, String? modifier) {
  switch (type) {
    case 'depart':
      return ManeuverKind.depart;
    case 'arrive':
      return ManeuverKind.arrive;
    case 'roundabout':
    case 'rotary':
    case 'roundabout turn':
      return ManeuverKind.roundabout;
  }
  switch (modifier) {
    case 'left':
      return ManeuverKind.left;
    case 'right':
      return ManeuverKind.right;
    case 'slight left':
      return ManeuverKind.slightLeft;
    case 'slight right':
      return ManeuverKind.slightRight;
    case 'sharp left':
      return ManeuverKind.sharpLeft;
    case 'sharp right':
      return ManeuverKind.sharpRight;
    case 'uturn':
      return ManeuverKind.uTurn;
    case 'straight':
      return ManeuverKind.straight;
  }
  return ManeuverKind.straight;
}

/// Maps the Routes API's `navigationInstruction.maneuver` enum onto
/// [ManeuverKind].
///
/// Deliberately total: an unrecognized value becomes [ManeuverKind.straight]
/// rather than being dropped, for the same reason [maneuverFromOsrm] does it.
/// A step that exists but cannot be named is still a real point on the route,
/// and discarding it would leave the narrator believing the next turn is
/// further away than it is — which for a blind user means being told to keep
/// walking straight through the turn.
///
/// `NAME_CHANGE` and `MERGE` map to straight on purpose: they are real steps
/// that require no action from someone on foot.
ManeuverKind maneuverFromGoogleRoutes(String? maneuver) => switch (maneuver) {
      'TURN_LEFT' || 'RAMP_LEFT' || 'FORK_LEFT' => ManeuverKind.left,
      'TURN_RIGHT' || 'RAMP_RIGHT' || 'FORK_RIGHT' => ManeuverKind.right,
      'TURN_SLIGHT_LEFT' || 'KEEP_LEFT' => ManeuverKind.slightLeft,
      'TURN_SLIGHT_RIGHT' || 'KEEP_RIGHT' => ManeuverKind.slightRight,
      'TURN_SHARP_LEFT' => ManeuverKind.sharpLeft,
      'TURN_SHARP_RIGHT' => ManeuverKind.sharpRight,
      'TURN_U_TURN_LEFT' || 'TURN_U_TURN_RIGHT' => ManeuverKind.uTurn,
      'ROUNDABOUT_LEFT' || 'ROUNDABOUT_RIGHT' => ManeuverKind.roundabout,
      'DEPART' => ManeuverKind.depart,
      'DESTINATION' || 'DESTINATION_LEFT' || 'DESTINATION_RIGHT' => ManeuverKind.arrive,
      'STRAIGHT' || 'NAME_CHANGE' || 'MERGE' => ManeuverKind.straight,
      _ => ManeuverKind.straight,
    };

/// One place a geocoder thinks a spoken destination might be.
///
/// The old `geocode()` returned only the top hit, which quietly threw away
/// the information that matters most when a user names somewhere loosely:
/// *whether the geocoder was actually sure*. "The hospital" matches a dozen
/// places in Dhaka, and silently walking someone to whichever scored highest
/// is the worst of the available options — they cannot see that it picked
/// wrong until they arrive somewhere else.
class GeocodeCandidate {
  const GeocodeCandidate({required this.label, required this.location});

  /// How the geocoder describes it, e.g. "Ibn Sina Hospital, Dhanmondi,
  /// Dhaka". Read aloud when asking the user which one they meant, so it
  /// has to be a human sentence rather than an id.
  final String label;
  final LatLng location;

  /// A short form for speech — geocoders return long comma-separated
  /// hierarchies ("X, Road 5, Dhanmondi, Dhaka, 1209, Bangladesh") and
  /// reading the whole chain aloud for each of three options is unusable.
  /// Keeps the first two components, which is the name and its area.
  String get spokenLabel {
    final parts = label.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    return parts.take(2).join(', ');
  }
}

/// One candidate walking route.
class RouteCandidate {
  const RouteCandidate({
    required this.encodedPolyline,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.initialBearingDegrees,
    this.steps = const [],
    this.isPedestrianProfile = true,
  });

  final String encodedPolyline;
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;

  /// Compass bearing (0-360, 0 = north) of the route's very first leg —
  /// what the Split-Mode Dashboard's giant directional arrow should point
  /// along the instant a route is accepted (see Module 2's own note that
  /// the arrow is static until "Modules 4-5 will feed it real turn
  /// instructions" — this module is the first of those).
  final double initialBearingDegrees;

  /// Turn-by-turn manoeuvres, in order. Empty when the backend didn't
  /// return step detail — every consumer treats that as "no spoken
  /// turn-by-turn available" and falls back to distance-and-bearing
  /// guidance rather than failing.
  final List<RouteStep> steps;

  /// Whether this route came from a routing engine that actually models
  /// pedestrians.
  ///
  /// True for Google's Routes API `WALK` mode. **False for the public OSRM
  /// demo server**, whose `foot` profile returns car routing under a
  /// walking label (see `RoutingConfig`). A false route is still worth
  /// offering — it is drawn from OSM's real street network and beats no
  /// route at all — but it may follow a road with no footpath, and a user
  /// who cannot see that is entitled to be told.
  ///
  /// This exists so that the fallback degrades *honestly* rather than
  /// silently. The narration layer decides what to say about it; this class
  /// only refuses to lose the fact.
  final bool isPedestrianProfile;
}

/// One place of a given kind found near a point — a hospital, clinic or
/// police station. Named because it crosses several layers and an inline
/// record type in each signature reads worse than the thing it represents.
typedef NearbyRefuge = ({String name, LatLng location, String kind});

/// Thrown for any Directions/Geocoding failure the caller should show a
/// graceful "couldn't plan that route" message for, rather than crash —
/// consistent with the app's offline/degradation philosophy.
class RoutingException implements Exception {
  const RoutingException(this.reason);
  final String reason;
}

/// Geocoding, walking directions and nearby-place discovery, over whichever
/// backend is available.
///
/// ## The cascade
///
/// When [_preferGoogle] is on, every call tries Google first
/// and falls back to the OpenStreetMap services on failure. Callers
/// (`RoutePlanningService`, `EmergencyService`) never learn which answered —
/// with one deliberate exception, [RouteCandidate.isPedestrianProfile],
/// because a car route sold as a walking route is not a detail a blind
/// user's app gets to keep to itself.
///
/// The fallback is not symmetric across the three call types, and the
/// asymmetry is the interesting part:
///
/// - **Geocoding** falls back even on an *empty* result. Costing one extra
///   request to double-check a destination the user just spoke is cheap,
///   and Nominatim occasionally knows a local Dhaka name Google does not.
/// - **Routing** falls back only on *error*, never on an empty result. If
///   Google's `WALK` mode says no walking route exists, that is an answer,
///   and asking OSRM instead would produce a route only because its car
///   profile always finds one — precisely the failure this migration is
///   meant to end.
/// - **Discovery** never throws at all, in either backend. It runs mid
///   emergency, after the SMS has gone out, where an exception would
///   discard the steps after it.
class RoutingService {
  /// [backend] and [allowFallback] default to the compile-time
  /// [RoutingConfig] values and exist to be overridden.
  ///
  /// Not only for tests, though that is what forced them: the Google path
  /// cannot be exercised without a billing-attached project, so without a
  /// seam its wire format would ship entirely unverified. They are also how
  /// a caller pins a backend deliberately — and how the setup instructions
  /// can tell someone to prove Google works before trusting a build where a
  /// misconfigured key hides behind a silent fallback.
  RoutingService({
    http.Client? client,
    RoutingBackend? backend,
    bool? allowFallback,
    ApiBudget? budget,
  })  : _client = client ?? http.Client(),
        _backend = backend ?? RoutingConfig.primary,
        _allowFallback = allowFallback ?? RoutingConfig.allowOsmFallback,
        _budget = budget ?? defaultApiBudget;

  final http.Client _client;
  final RoutingBackend _backend;
  final bool _allowFallback;
  final ApiBudget _budget;

  bool get _preferGoogle => _backend == RoutingBackend.google;

  /// Whether a billable call to [api] is both wanted and affordable.
  ///
  /// A refused budget is reported as "Google is not available right now",
  /// deliberately indistinguishable from a network failure, because the
  /// caller's correct response is identical: use OpenStreetMap. There is no
  /// user-visible difference between the free tier running out and the key
  /// being unreachable — both produce a working route from a free backend.
  Future<bool> _canSpend(BillableApi api) async {
    if (!_preferGoogle) return false;
    return _budget.tryConsume(api);
  }

  /// Resolves free-text like "Gulshan 2, Dhaka" to coordinates. Returns
  /// `null` (not a thrown exception) when nothing matches — a genuinely
  /// unrecognized destination isn't a failure the caller needs to log, just
  /// something to tell the user.
  Future<LatLng?> geocode(String address) async {
    final candidates = await geocodeCandidates(address, limit: 1);
    return candidates.isEmpty ? null : candidates.first.location;
  }

  /// Every place the backend thinks [address] might be, best first.
  ///
  /// Used by the clarification loop: more than one distinct answer means
  /// the assistant should ask which, rather than pick. See
  /// [GeocodeCandidate].
  ///
  /// On Google this is a two-step cascade, and the order is a cost
  /// decision as much as a quality one. The Geocoding API is the cheap SKU
  /// and is built for *addresses*; Places Text Search is several times
  /// dearer and is built for *names of things*. Users of this app say both
  /// — "Road 7 Dhanmondi" and "Labaid" — so the address lookup runs first
  /// and the expensive name search only runs when it comes back empty.
  Future<List<GeocodeCandidate>> geocodeCandidates(String address, {int limit = 5}) async {
    if (_preferGoogle) {
      try {
        // Gated separately, because they are separate SKUs with separate
        // allowances — exhausting the cheap geocoding budget must not also
        // spend the Places one, and vice versa.
        if (await _canSpend(BillableApi.geocoding)) {
          final byAddress = await _geocodeCandidatesGoogle(address, limit);
          if (byAddress.isNotEmpty) return byAddress;
        }
        if (await _canSpend(BillableApi.places)) {
          final byName = await _placesTextSearch(address, limit);
          if (byName.isNotEmpty) return byName;
        }
      } on RoutingException catch (e) {
        if (!_allowFallback) rethrow;
        debugPrint('[Routing] Google geocode failed (${e.reason}); trying Nominatim');
      }
      if (!_allowFallback) return const [];
    }
    return _geocodeCandidatesOsm(address, limit);
  }

  /// What to call the spot at [location] — the answer to "where am I".
  ///
  /// The reverse of [geocode], and added for item 48: a tester asked where
  /// they were and was told the app could not say. The location was there all
  /// along (the logs show a fix within four seconds and 529 of them after
  /// that) — there was simply nothing that could turn it into words, so the
  /// assistant answered from the only thing it had, which was its own
  /// ignorance.
  ///
  /// Coordinates are not an answer. Someone who cannot see the map needs a
  /// road and an area, which is what [GeocodeCandidate.spokenLabel] reduces a
  /// geocoder's full hierarchy to.
  ///
  /// Returns null rather than throwing when nothing is found: being unable to
  /// name a spot is an ordinary thing to say out loud, not a failure.
  Future<GeocodeCandidate?> describeLocation(LatLng location) async {
    if (_preferGoogle) {
      try {
        // The same Geocoding SKU as a forward lookup, so it draws on the same
        // allowance — reverse geocoding is not separately billed.
        if (await _canSpend(BillableApi.geocoding)) {
          final found = await _reverseGeocodeGoogle(location);
          if (found != null) return found;
        }
      } on RoutingException catch (e) {
        if (!_allowFallback) rethrow;
        debugPrint('[Routing] Google reverse geocode failed (${e.reason}); trying Nominatim');
      }
      if (!_allowFallback) return null;
    }
    return _reverseGeocodeOsm(location);
  }

  /// Every walking-mode alternative the backend offers between two points,
  /// ordered fastest-first — `RoutePlanningService` is what actually picks
  /// among these for safety.
  Future<List<RouteCandidate>> walkingRoutes({
    required LatLng origin,
    required LatLng destination,
  }) async {
    if (await _canSpend(BillableApi.routes)) {
      try {
        // An empty list is returned as-is, on purpose. See the class comment:
        // "Google found no pedestrian route" is a real answer, and OSRM would
        // override it with a car route every single time.
        return await _walkingRoutesGoogle(origin: origin, destination: destination);
      } on RoutingException catch (e) {
        if (!_allowFallback) rethrow;
        debugPrint('[Routing] Google routing failed (${e.reason}); trying OSRM');
      }
    }
    return _walkingRoutesOsrm(origin: origin, destination: destination);
  }

  Future<List<GeocodeCandidate>> _geocodeCandidatesGoogle(String address, int limit) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': address,
      'region': 'bd',
      'bounds': '23.62,90.28|23.92,90.52',
      'key': MapsConfig.apiKey,
    });
    final response = await _get(uri, headers: MapsConfig.androidRestrictionHeaders);
    final status = response['status'] as String?;
    if (status == 'ZERO_RESULTS') return const [];
    if (status != 'OK') throw RoutingException('geocode_failed:$status');
    final results = (response['results'] as List<dynamic>).take(limit);
    return [
      for (final r in results)
        GeocodeCandidate(
          label: (r as Map<String, dynamic>)['formatted_address'] as String? ?? address,
          location: LatLng(
            ((r['geometry']['location'] as Map<String, dynamic>)['lat'] as num).toDouble(),
            ((r['geometry']['location'] as Map<String, dynamic>)['lng'] as num).toDouble(),
          ),
        ),
    ];
  }

  /// Places API **Text Search (New)** — the "what is that place called"
  /// lookup, run only when the Geocoding API has already come back empty.
  ///
  /// The two answer different questions and this app needs both. Geocoding
  /// resolves *addresses* ("Road 7, Dhanmondi"); Text Search resolves *names*
  /// ("Labaid", "Square Hospital", "the big mosque in Gulshan"). Users of a
  /// voice-first app overwhelmingly say the second kind, and a geocoder
  /// handed a business name returns either nothing or something confidently
  /// wrong.
  ///
  /// It is second in the cascade purely on price — this is a Pro-tier SKU,
  /// several times the cost of a geocode, with a smaller free monthly
  /// allowance. Running it only on a miss keeps the expensive call rare
  /// without giving up the recall it buys.
  Future<List<GeocodeCandidate>> _placesTextSearch(String query, int limit) async {
    final response = await _postJson(
      Uri.https('places.googleapis.com', '/v1/places:searchText'),
      headers: {
        'X-Goog-Api-Key': MapsConfig.apiKey,
        'X-Goog-FieldMask': 'places.displayName,places.formattedAddress,places.location',
      },
      body: {
        'textQuery': query,
        'maxResultCount': limit.clamp(1, 20),
        'languageCode': 'en',
        'regionCode': 'BD',
        // Bias, not restriction — same Dhaka bounding box the Geocoding and
        // Nominatim paths use. Restricting outright would make the app
        // useless the moment a user travels, for no benefit.
        'locationBias': {
          'rectangle': {
            'low': {'latitude': 23.62, 'longitude': 90.28},
            'high': {'latitude': 23.92, 'longitude': 90.52},
          },
        },
      },
      failurePrefix: 'places_text_failed',
    );
    final places = response['places'];
    if (places is! List) return const [];
    final out = <GeocodeCandidate>[];
    for (final place in places) {
      if (place is! Map) continue;
      final latLng = place['location'];
      if (latLng is! Map) continue;
      final lat = latLng['latitude'];
      final lng = latLng['longitude'];
      if (lat is! num || lng is! num) continue;
      final name = (place['displayName'] as Map?)?['text'] as String?;
      final address = place['formattedAddress'] as String?;
      // Name first, then area — `GeocodeCandidate.spokenLabel` keeps the
      // first two comma-separated parts, so this ordering is what makes the
      // clarification question say "Labaid, Dhanmondi" rather than a house
      // number and a postcode.
      final label = [
        if (name != null && name.trim().isNotEmpty) name.trim(),
        if (address != null && address.trim().isNotEmpty) address.trim(),
      ].join(', ');
      out.add(GeocodeCandidate(
        label: label.isEmpty ? query : label,
        location: LatLng(lat.toDouble(), lng.toDouble()),
      ));
    }
    return out;
  }

  /// Hospitals, clinics and police stations within [radiusMeters].
  ///
  /// Returns an empty list on any failure rather than throwing. This runs
  /// during an emergency, after the SMS has already gone out, and an
  /// exception here would lose the steps after it in order to report the
  /// absence of something that was never guaranteed. "No hospital nearby"
  /// and "the server is down" are the same thing to the caller: no
  /// discovered haven, fall back to somewhere the user already knows.
  ///
  /// The timeout is deliberately short. Someone is standing still waiting
  /// for an answer, and the honest fallback — "stay where you are, I have
  /// messaged your contacts" — is available instantly, so a slow reply is
  /// worse than no reply. It is passed to *each* backend rather than
  /// shared across both: a cascade that inherits one deadline gives the
  /// fallback whatever fraction of a second the first attempt left over,
  /// which is the same as not having a fallback.
  Future<List<NearbyRefuge>> nearbyRefuges({
    required LatLng origin,
    double radiusMeters = 1000,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (_preferGoogle) {
      final places = await _nearbyRefugesPlaces(
        origin: origin,
        radiusMeters: radiusMeters,
        timeout: timeout,
      );
      if (places.isNotEmpty) return places;
      if (!_allowFallback) return const [];
    }
    return _nearbyRefugesOverpass(
      origin: origin,
      radiusMeters: radiusMeters,
      timeout: timeout,
    );
  }

  /// The nearest places of a given [category], nearest first.
  ///
  /// The generalisation of [nearbyRefuges], which could only ever ask for
  /// hospital/clinic/police because those were hard-coded into its Overpass
  /// query. Routing needed the same question asked about toilets, pharmacies,
  /// restaurants and bus stops, and having no way to ask it is why "take me
  /// to the nearest toilet" was sent to a *name* geocoder and came back
  /// "I don't know where that is" — see `place_categories.dart`.
  ///
  /// Overpass only, deliberately. [nearbyRefuges] pays for Google Places
  /// because it runs when somebody is already in trouble and a volunteer
  /// service is a poor thing to have in that path. This one runs on ordinary
  /// requests, many times a day, for things like a shop — that is exactly the
  /// volume that should not be billed, and a failure here costs a spoken
  /// "I couldn't find one nearby" rather than a missed emergency.
  Future<List<NearbyRefuge>> nearbyOfCategory({
    required LatLng origin,
    required PlaceCategory category,
    double radiusMeters = 1500,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final r = radiusMeters.round();
    final lat = origin.latitude;
    final lng = origin.longitude;
    // `nwr` rather than `node`: a toilet block, a hospital or a supermarket is
    // very often mapped as a building way or a relation, not a point, and
    // asking only for nodes silently misses most of them. `center` gives each
    // one a usable coordinate.
    final clauses = category.osmFilters
        .map((f) => 'nwr[$f](around:$r,$lat,$lng);')
        .join();
    final query = '[out:json][timeout:8];($clauses);out center $_categoryResultLimit;';
    try {
      final response = await _client
          .post(
            Uri.https('overpass-api.de', '/api/interpreter'),
            headers: {'User-Agent': _osmUserAgent, 'Content-Type': 'text/plain; charset=utf-8'},
            body: query,
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        debugPrint('[Routing] category search returned HTTP ${response.statusCode}');
        return const [];
      }
      final decoded = jsonDecode(response.body);
      final elements = decoded is Map<String, dynamic> ? decoded['elements'] : null;
      if (elements is! List) return const [];
      final out = <NearbyRefuge>[];
      for (final element in elements) {
        if (element is! Map) continue;
        // A node carries lat/lon directly; a way or relation carries them
        // under `center` because of `out center` above.
        final centre = element['center'];
        final rawLat = element['lat'] ?? (centre is Map ? centre['lat'] : null);
        final rawLng = element['lon'] ?? (centre is Map ? centre['lon'] : null);
        if (rawLat is! num || rawLng is! num) continue;
        final tags = element['tags'];
        final name = tags is Map && tags['name'] is String ? tags['name'] as String : '';
        out.add((
          name: name,
          location: LatLng(rawLat.toDouble(), rawLng.toDouble()),
          kind: category.id,
        ));
      }
      out.sort((a, b) => _haversineMeters(origin, a.location)
          .compareTo(_haversineMeters(origin, b.location)));
      debugPrint('[Routing] category ${category.id}: ${out.length} within ${r}m');
      return out;
    } catch (e) {
      debugPrint('[Routing] category search failed: $e');
      return const [];
    }
  }

  static const int _categoryResultLimit = 30;

  /// Great-circle distance in metres.
  ///
  /// Local to this file rather than shared with `NavigationNarrator`'s copy:
  /// Overpass's `around:` filter is a radius, not an ordering, so the results
  /// come back in whatever order the database yields them. Sorting them is
  /// what makes "the **nearest** toilet" true rather than "a toilet".
  static double _haversineMeters(LatLng a, LatLng b) {
    const earthRadius = 6371000.0;
    double rad(double deg) => deg * math.pi / 180;
    final dLat = rad(b.latitude - a.latitude);
    final dLng = rad(b.longitude - a.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.sin(dLng / 2) * math.sin(dLng / 2) *
            math.cos(rad(a.latitude)) * math.cos(rad(b.latitude));
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }

  /// Places API **Nearby Search (New)**.
  ///
  /// Worth the money here specifically because of where it runs. This is the
  /// one call in the app that fires when the user is already in trouble, its
  /// volume is therefore about as low as a call can be, and Overpass — a
  /// volunteer service with no uptime guarantee — is a poor thing to have
  /// standing between a frightened person and the nearest hospital.
  ///
  /// `displayName` is what makes this billable at the Pro tier rather than
  /// Essentials, and it is requested anyway: "Ibn Sina Hospital, 300 metres
  /// north-east" is actionable and "a hospital, 300 metres north-east" is
  /// most of the way to useless when the user has to ask a stranger for the
  /// rest.
  Future<List<NearbyRefuge>> _nearbyRefugesPlaces({
    required LatLng origin,
    required double radiusMeters,
    required Duration timeout,
  }) async {
    try {
      final response = await _postJson(
        Uri.https('places.googleapis.com', '/v1/places:searchNearby'),
        headers: {
          'X-Goog-Api-Key': MapsConfig.apiKey,
          'X-Goog-FieldMask': 'places.displayName,places.location,places.primaryType',
        },
        body: {
          'includedTypes': const ['hospital', 'police', 'doctor'],
          'maxResultCount': 20,
          'locationRestriction': {
            'circle': {
              'center': {'latitude': origin.latitude, 'longitude': origin.longitude},
              'radius': radiusMeters,
            },
          },
          'languageCode': 'en',
          'regionCode': 'BD',
        },
        failurePrefix: 'places_nearby_failed',
        timeout: timeout,
      );
      final places = response['places'];
      if (places is! List) return const [];
      final out = <NearbyRefuge>[];
      for (final place in places) {
        if (place is! Map) continue;
        final latLng = place['location'];
        if (latLng is! Map) continue;
        final lat = latLng['latitude'];
        final lng = latLng['longitude'];
        if (lat is! num || lng is! num) continue;
        final kind = _refugeKindFromPlaceType(place['primaryType'] as String?);
        final name = (place['displayName'] as Map?)?['text'] as String?;
        out.add((
          // An unnamed place is still a real place, and being told "a
          // hospital" is usable when the alternative is being told nothing.
          name: (name == null || name.trim().isEmpty) ? kind : name,
          location: LatLng(lat.toDouble(), lng.toDouble()),
          kind: kind,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[Routing] Places nearby search failed: $e');
      return const [];
    }
  }

  /// Normalizes a Places type onto the same three words the Overpass path
  /// produces, so `SafeHavenFinder` and the narrator cannot tell which
  /// backend answered.
  static String _refugeKindFromPlaceType(String? type) => switch (type) {
        'hospital' => 'hospital',
        'police' => 'police',
        'doctor' || 'medical_lab' || 'dental_clinic' => 'clinic',
        _ => 'place',
      };

  /// Overpass rather than Nominatim: Nominatim answers "where is this
  /// name", and the question here is "what of this kind is near this
  /// point", which it has no way to express. Overpass is the OSM service
  /// for exactly that.
  Future<List<NearbyRefuge>> _nearbyRefugesOverpass({
    required LatLng origin,
    required double radiusMeters,
    required Duration timeout,
  }) async {
    final r = radiusMeters.round();
    final lat = origin.latitude;
    final lng = origin.longitude;
    final query = '[out:json][timeout:5];('
        'node["amenity"="hospital"](around:$r,$lat,$lng);'
        'node["amenity"="clinic"](around:$r,$lat,$lng);'
        'node["amenity"="police"](around:$r,$lat,$lng);'
        ');out body 20;';
    try {
      final response = await _client
          .post(
            Uri.https('overpass-api.de', '/api/interpreter'),
            headers: {'User-Agent': _osmUserAgent, 'Content-Type': 'text/plain; charset=utf-8'},
            body: query,
          )
          .timeout(timeout);
      if (response.statusCode != 200) {
        debugPrint('[Routing] overpass returned HTTP ${response.statusCode}');
        return const [];
      }
      final decoded = jsonDecode(response.body);
      final elements = decoded is Map<String, dynamic> ? decoded['elements'] : null;
      if (elements is! List) return const [];
      final out = <({String name, LatLng location, String kind})>[];
      for (final element in elements) {
        if (element is! Map) continue;
        final elementLat = element['lat'];
        final elementLng = element['lon'];
        if (elementLat is! num || elementLng is! num) continue;
        final tags = element['tags'];
        final kind = tags is Map && tags['amenity'] is String ? tags['amenity'] as String : 'place';
        // An unnamed node is still a real place, and being told "a hospital"
        // is usable when the alternative is being told nothing.
        final name = tags is Map && tags['name'] is String ? tags['name'] as String : kind;
        out.add((
          name: name,
          location: LatLng(elementLat.toDouble(), elementLng.toDouble()),
          kind: kind,
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[Routing] nearbyRefuges failed: $e');
      return const [];
    }
  }

  Future<List<GeocodeCandidate>> _geocodeCandidatesOsm(String address, int limit) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': address,
      'format': 'jsonv2',
      'limit': '$limit',
      'countrycodes': 'bd',
      'viewbox': '90.28,23.92,90.52,23.62',
      'bounded': '1',
    });
    final results = await _getList(uri);
    return [
      for (final r in results)
        GeocodeCandidate(
          label: (r as Map<String, dynamic>)['display_name'] as String? ?? address,
          location: LatLng(
            double.parse(r['lat'] as String),
            double.parse(r['lon'] as String),
          ),
        ),
    ];
  }

  Future<GeocodeCandidate?> _reverseGeocodeGoogle(LatLng location) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'latlng': '${location.latitude},${location.longitude}',
      'key': MapsConfig.apiKey,
    });
    final response = await _get(uri, headers: MapsConfig.androidRestrictionHeaders);
    final status = response['status'] as String?;
    if (status == 'ZERO_RESULTS') return null;
    if (status != 'OK') throw RoutingException('reverse_geocode_failed:$status');
    // Google orders reverse results most-specific first, which is the one
    // worth saying: "Road 7, Dhanmondi" rather than "Dhaka Division".
    //
    // Except when the most specific thing it has is a Plus Code. Confirmed
    // live on 16 Sep: "আমি যেখানে আছি" was answered with "আপনি P9V4+452,
    // Dhaka 1209 এর কাছে আছেন" — four times in one session. A Plus Code is a
    // grid reference. Reading one aloud to somebody who cannot see a map is
    // the same failure as reading them coordinates, which is the whole thing
    // `describeLocation` was written to avoid.
    //
    // So the first result that is *not* one wins, and if every result is a
    // Plus Code the code itself is dropped and whatever area name trails it
    // is kept — "Dhaka 1209" is vague but it is an answer a person can use.
    final results = response['results'] as List<dynamic>? ?? const [];
    if (results.isEmpty) return null;
    String? fallback;
    for (final r in results) {
      final label = (r as Map<String, dynamic>)['formatted_address'] as String?;
      if (label == null || label.isEmpty) continue;
      if (!_startsWithPlusCode(label)) {
        return GeocodeCandidate(label: label, location: location);
      }
      fallback ??= _withoutPlusCode(label);
    }
    if (fallback == null || fallback.isEmpty) return null;
    return GeocodeCandidate(label: fallback, location: location);
  }

  /// An Open Location Code — "P9V4+452", "7MQ2+3X Dhaka". Four or more
  /// base-20 characters, a `+`, then two or more.
  ///
  /// Anchored to the start because that is where Google puts it, and a real
  /// address is never shaped this way.
  static final _plusCode = RegExp(r'^[23456789CFGHJMPQRVWX]{4,}\+[23456789CFGHJMPQRVWX]{2,}\b');

  static bool _startsWithPlusCode(String label) => _plusCode.hasMatch(label.trim());

  @visibleForTesting
  static bool debugIsPlusCode(String label) => _startsWithPlusCode(label);

  @visibleForTesting
  static String debugStripPlusCode(String label) => _withoutPlusCode(label);

  /// Drops the code and keeps the rest — "P9V4+452, Dhaka 1209" becomes
  /// "Dhaka 1209".
  static String _withoutPlusCode(String label) =>
      label.trim().replaceFirst(_plusCode, '').replaceFirst(RegExp(r'^[\s,]+'), '').trim();

  Future<GeocodeCandidate?> _reverseGeocodeOsm(LatLng location) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': '${location.latitude}',
      'lon': '${location.longitude}',
      'format': 'jsonv2',
      // Street level. Nominatim's default walks up to the suburb, which is
      // too coarse to be any use to somebody standing on a footpath.
      'zoom': '18',
    });
    try {
      final response = await _get(uri);
      final label = response['display_name'] as String?;
      if (label == null || label.isEmpty) return null;
      return GeocodeCandidate(label: label, location: location);
    } on RoutingException {
      return null;
    }
  }

  /// Google's **Routes API** (`v2:computeRoutes`), not the Directions API.
  ///
  /// Two reasons it has to be this one. The Directions API is now Legacy and
  /// **cannot be enabled at all on a project that never had it**, which is
  /// this project's situation — the earlier `REQUEST_DENIED` was partly that.
  /// And Routes is where the real pedestrian engine lives: `travelMode: WALK`
  /// is a genuine profile, which is the entire point of the migration.
  ///
  /// ### The field mask is a billing decision
  ///
  /// Routes API rejects a request with no `X-Goog-FieldMask`, and the fields
  /// asked for decide which SKU is charged. Everything below is in the
  /// cheapest tier, Compute Routes Essentials. What would leave it is
  /// `routes.travelAdvisory.tollInfo` and traffic-aware routing preferences —
  /// so neither is requested, and neither would mean anything for someone on
  /// foot anyway.
  ///
  /// Note there is deliberately no `routingPreference`: it is only valid for
  /// DRIVE and TWO_WHEELER, and sending it with WALK is a 400.
  Future<List<RouteCandidate>> _walkingRoutesGoogle({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final response = await _postJson(
      Uri.https('routes.googleapis.com', '/directions/v2:computeRoutes'),
      headers: {
        'X-Goog-Api-Key': MapsConfig.apiKey,
        'X-Goog-FieldMask': [
          'routes.distanceMeters',
          'routes.duration',
          'routes.polyline.encodedPolyline',
          'routes.legs.steps.distanceMeters',
          'routes.legs.steps.startLocation',
          'routes.legs.steps.navigationInstruction',
        ].join(','),
      },
      body: {
        'origin': _routesWaypoint(origin),
        'destination': _routesWaypoint(destination),
        'travelMode': 'WALK',
        'computeAlternativeRoutes': true,
        'units': 'METRIC',
        // Affects only the `instructions` prose, which this app never reads
        // aloud — phrasing is `dashboard_strings.dart`'s job, in the user's
        // own language. Pinned so the response shape can't shift with locale.
        'languageCode': 'en-US',
        'polylineEncoding': 'ENCODED_POLYLINE',
        'regionCode': 'BD',
      },
      failurePrefix: 'directions_failed',
    );
    // No route between the two points comes back as a literally empty object,
    // not an error and not an empty array.
    final routes = response['routes'];
    if (routes is! List || routes.isEmpty) return const [];
    return routes
        .whereType<Map<String, dynamic>>()
        .map(_toCandidateGoogle)
        .toList();
  }

  static Map<String, dynamic> _routesWaypoint(LatLng point) => {
        'location': {
          'latLng': {'latitude': point.latitude, 'longitude': point.longitude},
        },
      };

  /// The public OSRM demo server. Its encoded-geometry format
  /// (`geometries=polyline`) is bit-compatible with Google's own polyline
  /// encoding (same precision-5 algorithm), so [decodePolyline] works
  /// unchanged for either backend.
  Future<List<RouteCandidate>> _walkingRoutesOsrm({required LatLng origin, required LatLng destination}) async {
    final uri = Uri.https(
      'router.project-osrm.org',
      '/route/v1/foot/${origin.longitude},${origin.latitude};${destination.longitude},${destination.latitude}',
      {
        'alternatives': 'true',
        'overview': 'full',
        'geometries': 'polyline',
        // Turn-by-turn manoeuvres. Not requested before this module — the
        // overview polyline alone cannot tell a blind user when to turn.
        'steps': 'true',
      },
    );
    final response = await _get(uri);
    final code = response['code'] as String?;
    if (code == 'NoRoute' || code == 'NoSegment') return const [];
    if (code != 'Ok') {
      throw RoutingException('directions_failed:$code');
    }
    final routes = response['routes'] as List<dynamic>;
    return routes.map((r) => _toCandidateOsrm(r as Map<String, dynamic>)).toList();
  }

  RouteCandidate _toCandidateOsrm(Map<String, dynamic> route) {
    final encoded = route['geometry'] as String;
    final points = decodePolyline(encoded);
    final distance = ((route['distance'] as num?) ?? 0).toDouble();
    // Not `route['duration']` — see RoutingConfig's doc comment: the public
    // OSRM demo server's "foot" profile doesn't actually report pedestrian
    // speeds, so a real walking-speed estimate is computed from distance
    // instead of trusting the (car-speed) value the server returns.
    final duration = distance / _walkingSpeedMps;
    final bearing = points.length >= 2 ? _bearingDegrees(points[0], points[1]) : 0.0;
    return RouteCandidate(
      encodedPolyline: encoded,
      points: points,
      distanceMeters: distance,
      durationSeconds: duration,
      initialBearingDegrees: bearing,
      steps: _stepsFromOsrm(route),
      // The whole reason this flag exists. See RouteCandidate's doc comment.
      isPedestrianProfile: false,
    );
  }

  List<RouteStep> _stepsFromOsrm(Map<String, dynamic> route) {
    final legs = route['legs'] as List<dynamic>?;
    if (legs == null) return const [];
    final steps = <RouteStep>[];
    for (final leg in legs) {
      for (final raw in ((leg as Map<String, dynamic>)['steps'] as List<dynamic>? ?? const [])) {
        final step = raw as Map<String, dynamic>;
        final maneuver = step['maneuver'] as Map<String, dynamic>?;
        final location = (maneuver?['location'] as List<dynamic>?) ?? const [];
        if (location.length < 2) continue;
        steps.add(RouteStep(
          // OSRM returns [longitude, latitude], the opposite order to
          // everything else in this file.
          location: LatLng((location[1] as num).toDouble(), (location[0] as num).toDouble()),
          distanceMeters: ((step['distance'] as num?) ?? 0).toDouble(),
          maneuver: maneuverFromOsrm(maneuver?['type'] as String?, maneuver?['modifier'] as String?),
          streetName: (step['name'] as String?)?.trim() ?? '',
          bearingAfter: ((maneuver?['bearing_after'] as num?) ?? 0).toDouble(),
        ));
      }
    }
    return steps;
  }

  Future<List<dynamic>> _getList(Uri uri) async {
    final http.Response response;
    try {
      response = await _client.get(uri, headers: const {'User-Agent': _osmUserAgent});
    } catch (_) {
      throw const RoutingException('network_error');
    }
    if (response.statusCode != 200) {
      throw RoutingException('http_${response.statusCode}');
    }
    return jsonDecode(response.body) as List<dynamic>;
  }

  RouteCandidate _toCandidateGoogle(Map<String, dynamic> route) {
    final encoded = (route['polyline'] as Map?)?['encodedPolyline'] as String? ?? '';
    final points = decodePolyline(encoded);
    final steps = _stepsFromGoogle(route['legs']);
    // Bearing off the decoded geometry rather than the first step, because
    // the field mask does not ask for step end points and a step can be a
    // single location. The polyline always has the real first leg in it.
    final bearing = points.length >= 2 ? _bearingDegrees(points[0], points[1]) : 0.0;
    final distance = ((route['distanceMeters'] as num?) ?? 0).toDouble();
    return RouteCandidate(
      encodedPolyline: encoded,
      points: points,
      distanceMeters: distance,
      // Unlike OSRM's, this duration is a real pedestrian estimate from a
      // real pedestrian profile, so it is trusted. The fallback to
      // walking-speed arithmetic is only for a malformed value.
      durationSeconds: _routesDurationSeconds(route['duration']) ?? distance / _walkingSpeedMps,
      initialBearingDegrees: bearing,
      steps: steps,
    );
  }

  /// Routes API expresses a duration as protobuf `Duration` JSON — a string
  /// of seconds with a trailing `s`, e.g. `"842s"`, sometimes fractional.
  /// Null when it is missing or unparseable, so the caller can substitute
  /// rather than silently record a zero-second walk.
  static double? _routesDurationSeconds(Object? raw) {
    if (raw is num) return raw.toDouble();
    if (raw is! String) return null;
    return double.tryParse(raw.endsWith('s') ? raw.substring(0, raw.length - 1) : raw);
  }

  /// Routes API describes a manoeuvre as an enum on `navigationInstruction`
  /// plus an `instructions` prose string. The prose is never spoken: it is
  /// localized to the *request's* language, not the user's, and reading it
  /// aloud would produce exactly the kind of half-broken sentence a
  /// screen-reader user suffers through elsewhere. Phrasing is this app's job
  /// (see `dashboard_strings.dart`), in the user's own language. The one
  /// thing mined out of it is the road name — see
  /// [streetNameFromGoogleInstruction], which is the only place Routes API
  /// puts one.
  ///
  /// Defensive about shape throughout: a partial `legs` array must yield the
  /// steps it does have rather than throwing, since an empty step list
  /// degrades to distance-and-bearing guidance while an exception loses the
  /// route entirely.
  List<RouteStep> _stepsFromGoogle(Object? legs) {
    if (legs is! List) return const [];
    final steps = <RouteStep>[];
    for (final leg in legs) {
      if (leg is! Map) continue;
      final rawSteps = leg['steps'];
      if (rawSteps is! List) continue;
      for (final raw in rawSteps) {
        if (raw is! Map) continue;
        final latLng = (raw['startLocation'] as Map?)?['latLng'];
        if (latLng is! Map) continue;
        final lat = latLng['latitude'];
        final lng = latLng['longitude'];
        if (lat is! num || lng is! num) continue;
        final instruction = raw['navigationInstruction'];
        steps.add(RouteStep(
          location: LatLng(lat.toDouble(), lng.toDouble()),
          distanceMeters: ((raw['distanceMeters'] as num?) ?? 0).toDouble(),
          maneuver: maneuverFromGoogleRoutes(
            instruction is Map ? instruction['maneuver'] as String? : null,
          ),
          streetName: streetNameFromGoogleInstruction(
            instruction is Map ? instruction['instructions'] as String? : null,
          ),
          // Routes API has no per-step bearing. The narrator only uses this
          // when it exists; 0 means "unknown", the same as it does on the
          // OSRM path for a step with no `bearing_after`.
          bearingAfter: 0,
        ));
      }
    }
    return steps;
  }

  /// POST + JSON, used by the Routes and Places APIs.
  ///
  /// Both authenticate with `X-Goog-Api-Key` rather than a `key=` query
  /// parameter, and both report failure as a non-2xx status with an
  /// `{"error": {"status": ...}}` body rather than the legacy APIs' HTTP 200
  /// with a `"status"` field. The status string is carried into the
  /// [RoutingException] because it is the difference between problems that
  /// look identical from the outside: `PERMISSION_DENIED` means the key or
  /// its restrictions are wrong, `RESOURCE_EXHAUSTED` means the quota cap did
  /// its job, and `INVALID_ARGUMENT` means this code sent something bad.
  /// Without it, all three read as "routing is broken".
  Future<Map<String, dynamic>> _postJson(
    Uri uri, {
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    required String failurePrefix,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'User-Agent': _osmUserAgent,
              // Without these an Android-restricted key refuses every one of
              // these calls — see MapsConfig.androidRestrictionHeaders.
              ...MapsConfig.androidRestrictionHeaders,
              ...headers,
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (_) {
      throw const RoutingException('network_error');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw RoutingException('$failurePrefix:http_${response.statusCode}');
    }

    if (response.statusCode != 200) {
      final error = decoded is Map ? decoded['error'] : null;
      final status = error is Map ? error['status'] as String? : null;
      throw RoutingException('$failurePrefix:${status ?? 'http_${response.statusCode}'}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw RoutingException('$failurePrefix:malformed');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _get(Uri uri, {Map<String, String> headers = const {}}) async {
    final http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: {'User-Agent': _osmUserAgent, ...headers},
      );
    } catch (_) {
      throw const RoutingException('network_error');
    }
    if (response.statusCode != 200) {
      throw RoutingException('http_${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

/// Standard Google encoded-polyline decoder (same algorithm as the Cloud
/// Function's `lib/geo.js:decodePolyline` — kept independent since one runs
/// in Dart and one in Node, but intentionally identical logic).
List<LatLng> decodePolyline(String encoded) {
  final points = <LatLng>[];
  var index = 0;
  var lat = 0;
  var lng = 0;

  while (index < encoded.length) {
    var result = 0;
    var shift = 0;
    int byte;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) != 0 ? ~(result >> 1) : result >> 1;

    result = 0;
    shift = 0;
    do {
      byte = encoded.codeUnitAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) != 0 ? ~(result >> 1) : result >> 1;

    points.add(LatLng(lat / 1e5, lng / 1e5));
  }
  return points;
}

/// Initial great-circle compass bearing (0-360, 0 = north) from `from` to
/// `to` — standard forward-azimuth formula.
double _bearingDegrees(LatLng from, LatLng to) {
  final lat1 = from.latitude * math.pi / 180;
  final lat2 = to.latitude * math.pi / 180;
  final dLng = (to.longitude - from.longitude) * math.pi / 180;
  final y = math.sin(dLng) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
  final bearingDeg = math.atan2(y, x) * 180 / math.pi;
  return (bearingDeg + 360) % 360;
}
