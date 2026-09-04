import 'dart:convert';
import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

import '../config/maps_config.dart';
import '../config/routing_config.dart';

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

/// One candidate walking route from Google's Directions API.
class RouteCandidate {
  const RouteCandidate({
    required this.encodedPolyline,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.initialBearingDegrees,
    this.steps = const [],
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
}

/// Thrown for any Directions/Geocoding failure the caller should show a
/// graceful "couldn't plan that route" message for, rather than crash —
/// consistent with the app's offline/degradation philosophy.
class RoutingException implements Exception {
  const RoutingException(this.reason);
  final String reason;
}

/// Wrapper around whichever geocoding/walking-directions backend
/// [RoutingConfig.useOpenStreetMap] selects — Google's Maps Platform REST
/// APIs (the intended long-term backend, called directly from the client
/// same pattern as `MapsConfig`/`GeminiConfig` — see their doc comments,
/// no proxy Cloud Function since the key's already client-embedded for the
/// Maps SDK) or OpenStreetMap's free Nominatim/OSRM services (today's
/// placeholder — see `RoutingConfig`'s doc comment for why and its real
/// limitations). Callers (`RoutePlanningService`) never need to know which.
class RoutingService {
  RoutingService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Resolves free-text like "Gulshan 2, Dhaka" to coordinates. Returns
  /// `null` (not a thrown exception) when nothing matches — a genuinely
  /// unrecognized destination isn't a failure the caller needs to log, just
  /// something to tell the user.
  Future<LatLng?> geocode(String address) =>
      RoutingConfig.useOpenStreetMap ? _geocodeOsm(address) : _geocodeGoogle(address);

  /// Every place the backend thinks [address] might be, best first.
  ///
  /// Used by the clarification loop: more than one distinct answer means
  /// the assistant should ask which, rather than pick. See
  /// [GeocodeCandidate].
  Future<List<GeocodeCandidate>> geocodeCandidates(String address, {int limit = 5}) =>
      RoutingConfig.useOpenStreetMap
          ? _geocodeCandidatesOsm(address, limit)
          : _geocodeCandidatesGoogle(address, limit);

  /// Every walking-mode alternative the backend offers between two points,
  /// ordered fastest-first — `RoutePlanningService` is what actually picks
  /// among these for safety.
  Future<List<RouteCandidate>> walkingRoutes({required LatLng origin, required LatLng destination}) =>
      RoutingConfig.useOpenStreetMap
          ? _walkingRoutesOsrm(origin: origin, destination: destination)
          : _walkingRoutesGoogle(origin: origin, destination: destination);

  Future<List<GeocodeCandidate>> _geocodeCandidatesGoogle(String address, int limit) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': address,
      'region': 'bd',
      'bounds': '23.62,90.28|23.92,90.52',
      'key': MapsConfig.apiKey,
    });
    final response = await _get(uri);
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

  Future<LatLng?> _geocodeGoogle(String address) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/geocode/json', {
      'address': address,
      // Biases (doesn't restrict) results toward Dhaka, since this app has
      // no reason to route anywhere else.
      'region': 'bd',
      'bounds': '23.62,90.28|23.92,90.52',
      'key': MapsConfig.apiKey,
    });
    final response = await _get(uri);
    final status = response['status'] as String?;
    if (status == 'ZERO_RESULTS') return null;
    if (status != 'OK') {
      throw RoutingException('geocode_failed:$status');
    }
    final results = response['results'] as List<dynamic>;
    if (results.isEmpty) return null;
    final location = (results.first as Map<String, dynamic>)['geometry']['location'] as Map<String, dynamic>;
    return LatLng((location['lat'] as num).toDouble(), (location['lng'] as num).toDouble());
  }

  Future<List<RouteCandidate>> _walkingRoutesGoogle({required LatLng origin, required LatLng destination}) async {
    final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
      'origin': '${origin.latitude},${origin.longitude}',
      'destination': '${destination.latitude},${destination.longitude}',
      'mode': 'walking',
      'alternatives': 'true',
      'key': MapsConfig.apiKey,
    });
    final response = await _get(uri);
    final status = response['status'] as String?;
    if (status == 'ZERO_RESULTS') return const [];
    if (status != 'OK') {
      throw RoutingException('directions_failed:$status');
    }
    final routes = response['routes'] as List<dynamic>;
    return routes.map((r) => _toCandidateGoogle(r as Map<String, dynamic>)).toList();
  }

  /// Nominatim, biased (via `viewbox`+`bounded`) to Dhaka's bounding box —
  /// same reasoning as Google's `bounds` param above.
  Future<LatLng?> _geocodeOsm(String address) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': address,
      'format': 'jsonv2',
      'limit': '1',
      'countrycodes': 'bd',
      'viewbox': '90.28,23.92,90.52,23.62',
      'bounded': '1',
    });
    final response = await _getList(uri);
    if (response.isEmpty) return null;
    final first = response.first as Map<String, dynamic>;
    final lat = double.tryParse(first['lat'] as String? ?? '');
    final lon = double.tryParse(first['lon'] as String? ?? '');
    if (lat == null || lon == null) return null;
    return LatLng(lat, lon);
  }

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
    final overview = route['overview_polyline']['points'] as String;
    final points = decodePolyline(overview);
    final legs = route['legs'] as List<dynamic>;
    double distance = 0;
    double duration = 0;
    for (final leg in legs) {
      distance += ((leg['distance']?['value'] as num?) ?? 0).toDouble();
      duration += ((leg['duration']?['value'] as num?) ?? 0).toDouble();
    }
    final firstStep = (legs.first as Map<String, dynamic>)['steps'][0] as Map<String, dynamic>;
    final start = firstStep['start_location'] as Map<String, dynamic>;
    final end = firstStep['end_location'] as Map<String, dynamic>;
    final bearing = _bearingDegrees(
      LatLng((start['lat'] as num).toDouble(), (start['lng'] as num).toDouble()),
      LatLng((end['lat'] as num).toDouble(), (end['lng'] as num).toDouble()),
    );
    return RouteCandidate(
      encodedPolyline: overview,
      points: points,
      distanceMeters: distance,
      durationSeconds: duration,
      initialBearingDegrees: bearing,
      steps: _stepsFromGoogle(legs),
    );
  }

  /// Google describes a manoeuvre with an optional `maneuver` string
  /// ("turn-left", "roundabout-right") and an HTML instruction blob. Only
  /// the former is used: the HTML is localized to the *request's* language,
  /// not the user's, and stripping tags out of it to speak aloud produces
  /// exactly the kind of half-broken sentence a screen-reader user has to
  /// suffer through elsewhere. Phrasing is this app's job (see
  /// `dashboard_strings.dart`), in the user's own language.
  List<RouteStep> _stepsFromGoogle(List<dynamic> legs) {
    final steps = <RouteStep>[];
    for (final leg in legs) {
      for (final raw in ((leg as Map<String, dynamic>)['steps'] as List<dynamic>? ?? const [])) {
        final step = raw as Map<String, dynamic>;
        final start = step['start_location'] as Map<String, dynamic>?;
        if (start == null) continue;
        steps.add(RouteStep(
          location: LatLng((start['lat'] as num).toDouble(), (start['lng'] as num).toDouble()),
          distanceMeters: ((step['distance']?['value'] as num?) ?? 0).toDouble(),
          maneuver: _maneuverFromGoogle(step['maneuver'] as String?),
          bearingAfter: 0,
        ));
      }
    }
    return steps;
  }

  ManeuverKind _maneuverFromGoogle(String? maneuver) => switch (maneuver) {
        'turn-left' || 'ramp-left' || 'fork-left' => ManeuverKind.left,
        'turn-right' || 'ramp-right' || 'fork-right' => ManeuverKind.right,
        'turn-slight-left' || 'keep-left' => ManeuverKind.slightLeft,
        'turn-slight-right' || 'keep-right' => ManeuverKind.slightRight,
        'turn-sharp-left' => ManeuverKind.sharpLeft,
        'turn-sharp-right' => ManeuverKind.sharpRight,
        'uturn-left' || 'uturn-right' => ManeuverKind.uTurn,
        'roundabout-left' || 'roundabout-right' => ManeuverKind.roundabout,
        'straight' => ManeuverKind.straight,
        _ => ManeuverKind.straight,
      };

  Future<Map<String, dynamic>> _get(Uri uri) async {
    final http.Response response;
    try {
      response = await _client.get(uri, headers: const {'User-Agent': _osmUserAgent});
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
