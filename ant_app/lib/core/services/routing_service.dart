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

/// One candidate walking route from Google's Directions API.
class RouteCandidate {
  const RouteCandidate({
    required this.encodedPolyline,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.initialBearingDegrees,
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

  /// Every walking-mode alternative the backend offers between two points,
  /// ordered fastest-first — `RoutePlanningService` is what actually picks
  /// among these for safety.
  Future<List<RouteCandidate>> walkingRoutes({required LatLng origin, required LatLng destination}) =>
      RoutingConfig.useOpenStreetMap
          ? _walkingRoutesOsrm(origin: origin, destination: destination)
          : _walkingRoutesGoogle(origin: origin, destination: destination);

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
      {'alternatives': 'true', 'overview': 'full', 'geometries': 'polyline'},
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
    );
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
    );
  }

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
