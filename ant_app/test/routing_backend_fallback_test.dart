import 'dart:convert';

import 'package:ant_app/core/config/maps_config.dart';
import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// The cascade, and specifically the places where it is deliberately *not*
/// symmetric.
///
/// Geocoding falls back on an empty result; routing does not; discovery never
/// throws at all. Each of those is a judgement call rather than an obvious
/// default, so each is pinned here — an innocent-looking "make the fallback
/// consistent" refactor is exactly how the car-route problem would come back.
void main() {
  const dhaka = LatLng(23.7509, 90.3891);
  const gulshan = LatLng(23.7925, 90.4078);

  /// Routes an intercepted request to a handler chosen by host, so a test can
  /// say "Google fails, OSM succeeds" without matching on full URLs.
  MockClient routeByHost(Map<String, http.Response Function(http.Request)> byHost) {
    return MockClient((request) async {
      for (final entry in byHost.entries) {
        if (request.url.host.contains(entry.key)) return entry.value(request);
      }
      return http.Response('unexpected host ${request.url.host}', 500);
    });
  }

  final osrmOk = http.Response(
    jsonEncode({
      'code': 'Ok',
      'routes': [
        {
          'geometry': '_p~iF~ps|U_ulLnnqC',
          'distance': 900.0,
          'duration': 300.0,
          'legs': [
            {
              'steps': [
                {
                  'distance': 900.0,
                  'name': 'Satmasjid Road',
                  'maneuver': {
                    'location': [90.3891, 23.7509],
                    'type': 'depart',
                    'bearing_after': 10,
                  },
                },
              ],
            },
          ],
        },
      ],
    }),
    200,
  );

  final googleRoutesOk = http.Response(
    jsonEncode({
      'routes': [
        {
          'distanceMeters': 1053,
          'duration': '900s',
          'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC'},
          'legs': const [],
        },
      ],
    }),
    200,
  );

  group('routing falls back only on error', () {
    test('uses Google when Google answers', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'routes.googleapis.com': (_) => googleRoutesOk,
          'router.project-osrm.org': (_) => osrmOk,
        }),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(routes.first.distanceMeters, 1053);
      expect(routes.first.isPedestrianProfile, isTrue);
    });

    test('falls back to OSRM when Google errors', () async {
      var osrmCalled = false;
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'routes.googleapis.com': (_) => http.Response(
                jsonEncode({
                  'error': {'status': 'RESOURCE_EXHAUSTED'},
                }),
                429,
              ),
          'router.project-osrm.org': (_) {
            osrmCalled = true;
            return osrmOk;
          },
        }),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(osrmCalled, isTrue, reason: 'a quota-exhausted key must not mean no navigation');
      expect(routes.first.distanceMeters, 900);
    });

    test('a fallback route is labelled as not a pedestrian route', () async {
      // The whole point of RouteCandidate.isPedestrianProfile. If the fallback
      // came back indistinguishable from Google's, degrading would be silent
      // and a user would be walked down a car route with no warning.
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'routes.googleapis.com': (_) => http.Response('{"error":{}}', 500),
          'router.project-osrm.org': (_) => osrmOk,
        }),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(routes.first.isPedestrianProfile, isFalse);
    });

    test('does NOT fall back when Google finds no walking route', () async {
      // The asymmetry that matters most. OSRM's car profile always finds
      // something, so falling back here would convert every honest "there is
      // no pedestrian route" into a car route — reintroducing precisely the
      // defect this migration exists to remove.
      var osrmCalled = false;
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'routes.googleapis.com': (_) => http.Response('{}', 200),
          'router.project-osrm.org': (_) {
            osrmCalled = true;
            return osrmOk;
          },
        }),
      );

      final routes = await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(routes, isEmpty);
      expect(osrmCalled, isFalse);
    });

    test('rethrows instead of falling back when the fallback is off', () async {
      // How setup proves the Google key really works: with the fallback on, a
      // misconfigured key looks like a working app.
      final service = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        client: routeByHost({
          'routes.googleapis.com': (_) => http.Response(
                jsonEncode({
                  'error': {'status': 'PERMISSION_DENIED'},
                }),
                403,
              ),
          'router.project-osrm.org': (_) => fail('fallback must not run'),
        }),
      );

      await expectLater(
        service.walkingRoutes(origin: dhaka, destination: gulshan),
        throwsA(isA<RoutingException>()
            .having((e) => e.reason, 'reason', contains('PERMISSION_DENIED'))),
      );
    });
  });

  group('geocoding cascade', () {
    http.Response geocodeOk(String label) => http.Response(
          jsonEncode({
            'status': 'OK',
            'results': [
              {
                'formatted_address': label,
                'geometry': {
                  'location': {'lat': 23.75, 'lng': 90.39},
                },
              },
            ],
          }),
          200,
        );

    final geocodeEmpty = http.Response(
      jsonEncode({'status': 'ZERO_RESULTS', 'results': []}),
      200,
    );

    http.Response placesOk(String name) => http.Response(
          jsonEncode({
            'places': [
              {
                'displayName': {'text': name},
                'formattedAddress': 'Dhanmondi, Dhaka',
                'location': {'latitude': 23.74, 'longitude': 90.38},
              },
            ],
          }),
          200,
        );

    test('uses the cheap Geocoding API when it answers, and stops there', () async {
      var placesCalled = false;
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'maps.googleapis.com': (_) => geocodeOk('Road 7, Dhanmondi, Dhaka'),
          'places.googleapis.com': (_) {
            placesCalled = true;
            return placesOk('nope');
          },
        }),
      );

      final results = await service.geocodeCandidates('Road 7 Dhanmondi');

      expect(results.first.label, contains('Road 7'));
      expect(placesCalled, isFalse,
          reason: 'Places is the dearer SKU; it must not run on a geocoder hit');
    });

    test('escalates to Places when the geocoder does not know the name', () async {
      // "Labaid" is a business name, not an address. This is the case the
      // Geocoding API is structurally bad at and Places exists for.
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'maps.googleapis.com': (_) => geocodeEmpty,
          'places.googleapis.com': (_) => placesOk('Labaid Specialized Hospital'),
        }),
      );

      final results = await service.geocodeCandidates('Labaid');

      expect(results, hasLength(1));
      expect(results.first.label, startsWith('Labaid Specialized Hospital'));
      // Name first, then area — this is what the spoken clarification says.
      expect(results.first.spokenLabel, 'Labaid Specialized Hospital, Dhanmondi');
    });

    test('falls back to Nominatim when both Google lookups come up empty', () async {
      // Unlike routing, an empty geocode DOES fall through: one extra request
      // is cheap, and OSM occasionally knows a local Dhaka name Google misses.
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'maps.googleapis.com': (_) => geocodeEmpty,
          'places.googleapis.com': (_) => http.Response('{}', 200),
          'nominatim.openstreetmap.org': (_) => http.Response(
                jsonEncode([
                  {'display_name': 'Kacha Bazar, Mohammadpur', 'lat': '23.76', 'lon': '90.36'},
                ]),
                200,
              ),
        }),
      );

      final results = await service.geocodeCandidates('kacha bazar');

      expect(results.first.label, contains('Kacha Bazar'));
    });

    test('Geocoding and Places carry the Android headers, OSM does not', () async {
      // The headers authenticate this app to Google. Sending an app's signing
      // fingerprint to three volunteer OSM servers would be pointless and rude.
      final seen = <String, Map<String, String>>{};
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: MockClient((request) async {
          seen[request.url.host] = request.headers;
          if (request.url.host.contains('maps.googleapis.com')) return geocodeEmpty;
          if (request.url.host.contains('places.googleapis.com')) {
            return http.Response('{}', 200);
          }
          return http.Response(jsonEncode([]), 200);
        }),
      );

      await service.geocodeCandidates('anywhere');

      expect(seen['maps.googleapis.com']?['x-android-cert'], MapsConfig.androidCertSha1);
      expect(seen['places.googleapis.com']?['x-android-cert'], MapsConfig.androidCertSha1);
      expect(seen['nominatim.openstreetmap.org']?.containsKey('x-android-cert'), isFalse);
    });

    test('geocode() returns the first candidate of the same cascade', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'maps.googleapis.com': (_) => geocodeOk('Gulshan 2, Dhaka'),
        }),
      );

      final point = await service.geocode('Gulshan 2');

      expect(point, isNotNull);
      expect(point!.latitude, closeTo(23.75, 0.001));
    });

    test('an unknown destination is null, not an exception', () async {
      final service = RoutingService(
        backend: RoutingBackend.openStreetMap,
        client: routeByHost({
          'nominatim.openstreetmap.org': (_) => http.Response('[]', 200),
        }),
      );

      expect(await service.geocode('somewhere that does not exist'), isNull);
    });
  });

  group('nearby refuge discovery', () {
    final placesNearbyOk = http.Response(
      jsonEncode({
        'places': [
          {
            'displayName': {'text': 'Ibn Sina Hospital'},
            'location': {'latitude': 23.7512, 'longitude': 90.3895},
            'primaryType': 'hospital',
          },
          {
            'displayName': {'text': 'Dhanmondi Police Station'},
            'location': {'latitude': 23.7488, 'longitude': 90.3872},
            'primaryType': 'police',
          },
        ],
      }),
      200,
    );

    final overpassOk = http.Response(
      jsonEncode({
        'elements': [
          {
            'lat': 23.752,
            'lon': 90.390,
            'tags': {'amenity': 'hospital', 'name': 'Popular Diagnostic'},
          },
        ],
      }),
      200,
    );

    test('prefers Places, and normalizes its types to the Overpass words', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({'places.googleapis.com': (_) => placesNearbyOk}),
      );

      final found = await service.nearbyRefuges(origin: dhaka);

      expect(found, hasLength(2));
      expect(found.first.name, 'Ibn Sina Hospital');
      // SafeHavenFinder and the narrator must not be able to tell which
      // backend answered.
      expect(found.map((f) => f.kind), containsAll(['hospital', 'police']));
    });

    test('falls back to Overpass when Places fails', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'places.googleapis.com': (_) => http.Response('{"error":{}}', 403),
          'overpass-api.de': (_) => overpassOk,
        }),
      );

      final found = await service.nearbyRefuges(origin: dhaka);

      expect(found, hasLength(1));
      expect(found.first.name, 'Popular Diagnostic');
    });

    test('returns empty rather than throwing when everything is down', () async {
      // This runs mid-emergency, after the SMS has gone out. An exception here
      // would discard the steps after it.
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: MockClient((_) async => throw const SocketExceptionStub()),
      );

      expect(await service.nearbyRefuges(origin: dhaka), isEmpty);
    });

    test('an unnamed place is still offered, described by its kind', () async {
      final service = RoutingService(
        backend: RoutingBackend.google,
        client: routeByHost({
          'places.googleapis.com': (_) => http.Response(
                jsonEncode({
                  'places': [
                    {
                      'location': {'latitude': 23.7512, 'longitude': 90.3895},
                      'primaryType': 'hospital',
                    },
                  ],
                }),
                200,
              ),
        }),
      );

      final found = await service.nearbyRefuges(origin: dhaka);

      expect(found.single.name, 'hospital');
    });
  });
}

/// Stands in for a transport-level failure without importing `dart:io`, which
/// would tie this test to a platform it does not need.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
