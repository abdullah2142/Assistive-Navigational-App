import 'dart:convert';

import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// These tests exist because the Google path **cannot be run**.
///
/// It needs a billing-attached project with three APIs enabled, which did not
/// exist when this code was written. So every claim about the wire format —
/// what Routes API is POSTed, what shape comes back, which fields are asked
/// for — is an assertion made from documentation, and the only honest thing
/// to do is pin those assertions where a wrong one fails loudly instead of
/// showing up as "routing is broken" on somebody's phone in Dhaka.
///
/// The recorded response bodies below are the documented `v2:computeRoutes`
/// and `places:searchText` shapes. If Google changes them, these tests are
/// what will say so.
void main() {
  const dhaka = LatLng(23.7509, 90.3891);
  const gulshan = LatLng(23.7925, 90.4078);

  /// A minimal but structurally complete Routes API response.
  String routesBody({String duration = '1500s'}) => jsonEncode({
        'routes': [
          {
            'distanceMeters': 1053,
            'duration': duration,
            // "Two points near Dhaka" — enough to decode and take a bearing.
            'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC'},
            'legs': [
              {
                'steps': [
                  {
                    'distanceMeters': 120,
                    'startLocation': {
                      'latLng': {'latitude': 23.7509, 'longitude': 90.3891},
                    },
                    'navigationInstruction': {
                      'maneuver': 'DEPART',
                      'instructions': 'Head north',
                    },
                  },
                  {
                    'distanceMeters': 430,
                    'startLocation': {
                      'latLng': {'latitude': 23.7551, 'longitude': 90.3902},
                    },
                    'navigationInstruction': {
                      'maneuver': 'TURN_LEFT',
                      'instructions': 'Turn left onto Satmasjid Road',
                    },
                  },
                ],
              },
            ],
          },
        ],
      });

  group('Routes API request', () {
    test('posts to v2:computeRoutes with WALK mode', () async {
      late http.Request captured;
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((request) async {
          captured = request;
          return http.Response(routesBody(), 200);
        }),
      );

      await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(captured.method, 'POST');
      expect(captured.url.host, 'routes.googleapis.com');
      expect(captured.url.path, '/directions/v2:computeRoutes');

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['travelMode'], 'WALK',
          reason: 'the entire point of migrating off OSRM is a real pedestrian profile');
      expect(body['computeAlternativeRoutes'], isTrue,
          reason: 'RoutePlanningService picks among alternatives for safety; '
              'with one route there is nothing to pick');
    });

    test('never sends routingPreference, which is invalid for WALK', () async {
      // Sending it is a 400 from Google, i.e. every route request fails and
      // silently falls through to the car-profile fallback.
      late http.Request captured;
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((request) async {
          captured = request;
          return http.Response(routesBody(), 200);
        }),
      );

      await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(jsonDecode(captured.body), isNot(contains('routingPreference')));
    });

    test('authenticates by header, and asks only for Essentials-tier fields', () async {
      late http.Request captured;
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((request) async {
          captured = request;
          return http.Response(routesBody(), 200);
        }),
      );

      await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(captured.headers['X-Goog-Api-Key'], isNotEmpty);
      final mask = captured.headers['X-Goog-FieldMask']!;
      expect(mask, contains('routes.polyline.encodedPolyline'));
      expect(mask, contains('routes.legs.steps.navigationInstruction'));
      // Requesting either of these re-prices the call on a dearer SKU, and
      // neither means anything to somebody on foot.
      expect(mask, isNot(contains('tollInfo')));
      expect(mask, isNot(contains('travelAdvisory')));
    });
  });

  group('Routes API response', () {
    test('parses distance, duration, geometry and steps', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response(routesBody(), 200)),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(routes, hasLength(1));
      expect(routes.first.distanceMeters, 1053);
      // "1500s" — protobuf Duration JSON, not a number. Deliberately far
      // from 1053/1.25 = 842.4s, so this also proves the value came from the
      // response rather than from the walking-speed fallback.
      expect(routes.first.durationSeconds, 1500);
      expect(routes.first.points.length, greaterThanOrEqualTo(2));
      expect(routes.first.steps, hasLength(2));
      expect(routes.first.steps[0].maneuver, ManeuverKind.depart);
      expect(routes.first.steps[1].maneuver, ManeuverKind.left);
      expect(routes.first.steps[1].distanceMeters, 430);
    });

    test('trusts the duration, unlike OSRM', () async {
      // OSRM's is car speed wearing a walking label, so RoutingService throws
      // it away. Routes API's comes from a real pedestrian profile, and
      // recomputing it from distance would discard better information.
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response(routesBody(), 200)),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      const walkingSpeedEstimate = 1053 / 1.25;
      expect(routes.first.durationSeconds, isNot(closeTo(walkingSpeedEstimate, 1)));
    });

    test('substitutes a walking estimate for an unparseable duration', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient(
          (_) async => http.Response(routesBody(duration: 'not-a-duration'), 200),
        ),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      // Not zero. A zero-second walk would be announced as an arrival.
      expect(routes.first.durationSeconds, greaterThan(0));
      expect(routes.first.durationSeconds, closeTo(1053 / 1.25, 1));
    });

    test('marks Google routes as real pedestrian routes', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response(routesBody(), 200)),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(routes.first.isPedestrianProfile, isTrue);
    });

    test('reads no-route-found as an empty list, not an error', () async {
      // Routes API returns a literally empty object, not an empty array.
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response('{}', 200)),
      );

      expect(
        await service.walkingRoutes(origin: dhaka, destination: gulshan),
        isEmpty,
      );
    });

    test('survives a response with legs but no steps', () async {
      final body = jsonEncode({
        'routes': [
          {
            'distanceMeters': 500,
            'duration': '400s',
            'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC'},
            'legs': [<String, dynamic>{}],
          },
        ],
      });
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response(body, 200)),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      // Degrades to distance-and-bearing guidance rather than losing the route.
      expect(routes, hasLength(1));
      expect(routes.first.steps, isEmpty);
      expect(routes.first.distanceMeters, 500);
    });
  });

  group('failure reporting', () {
    test('carries Google\'s status so the three causes stay distinguishable', () async {
      // PERMISSION_DENIED (key/restrictions wrong), RESOURCE_EXHAUSTED (quota
      // cap worked), INVALID_ARGUMENT (this code sent something bad) look
      // identical from outside unless the status survives.
      for (final status in ['PERMISSION_DENIED', 'RESOURCE_EXHAUSTED', 'INVALID_ARGUMENT']) {
        final service = RoutingService(
          backend: RoutingBackend.google,
          allowFallback: false,
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': {'code': 403, 'status': status, 'message': 'nope'},
              }),
              403,
            ),
          ),
        );

        await expectLater(
          service.walkingRoutes(origin: dhaka, destination: gulshan),
          throwsA(
            isA<RoutingException>().having((e) => e.reason, 'reason', contains(status)),
          ),
        );
      }
    });

    test('an HTML error page does not crash the parser', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: MockClient((_) async => http.Response('<html>502</html>', 502)),
      );

      // The point is that a non-JSON body surfaces as a RoutingException the
      // caller can degrade on, not a FormatException out of the decoder.
      await expectLater(
        service.walkingRoutes(origin: dhaka, destination: gulshan),
        throwsA(isA<RoutingException>()),
      );
    });
  });

  group('maneuver vocabulary', () {
    test('maps every Routes API maneuver this app can act on', () {
      expect(maneuverFromGoogleRoutes('TURN_LEFT'), ManeuverKind.left);
      expect(maneuverFromGoogleRoutes('TURN_RIGHT'), ManeuverKind.right);
      expect(maneuverFromGoogleRoutes('TURN_SLIGHT_LEFT'), ManeuverKind.slightLeft);
      expect(maneuverFromGoogleRoutes('TURN_SHARP_RIGHT'), ManeuverKind.sharpRight);
      expect(maneuverFromGoogleRoutes('TURN_U_TURN_LEFT'), ManeuverKind.uTurn);
      expect(maneuverFromGoogleRoutes('ROUNDABOUT_RIGHT'), ManeuverKind.roundabout);
      expect(maneuverFromGoogleRoutes('DEPART'), ManeuverKind.depart);
      expect(maneuverFromGoogleRoutes('DESTINATION'), ManeuverKind.arrive);
    });

    test('is total — an unknown maneuver becomes a step, not a dropped one', () {
      // A dropped step makes the narrator think the next turn is further
      // away than it is, i.e. tells a blind user to walk through the turn.
      expect(maneuverFromGoogleRoutes('SOMETHING_NEW_IN_2027'), ManeuverKind.straight);
      expect(maneuverFromGoogleRoutes(null), ManeuverKind.straight);
    });

    test('agrees with the OSRM vocabulary, so narration is backend-blind', () {
      expect(
        maneuverFromGoogleRoutes('TURN_LEFT'),
        maneuverFromOsrm('turn', 'left'),
      );
      expect(
        maneuverFromGoogleRoutes('ROUNDABOUT_LEFT'),
        maneuverFromOsrm('roundabout', null),
      );
    });
  });
}
