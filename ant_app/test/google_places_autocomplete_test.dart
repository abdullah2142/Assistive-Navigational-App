import 'dart:convert';

import 'package:ant_app/core/config/maps_config.dart';
import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/core/services/api_budget.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _AllowingBudget implements ApiBudget {
  final spent = <BillableApi>[];

  @override
  Future<bool> tryConsume(BillableApi api) async {
    spent.add(api);
    return true;
  }

  @override
  Future<Map<String, int>> usage() async => const {};
}

void main() {
  test(
    'autocomplete is location-biased and resolves only a selected result',
    () async {
      final requests = <http.Request>[];
      final budget = _AllowingBudget();
      final routing = RoutingService(
        backend: RoutingBackend.google,
        allowFallback: false,
        budget: budget,
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'POST') {
            return http.Response(
              jsonEncode({
                'suggestions': [
                  {
                    'placePrediction': {
                      'placeId': 'place-123',
                      'text': {'text': 'Square Hospitals Ltd, Dhaka'},
                      'structuredFormat': {
                        'mainText': {'text': 'Square Hospitals Ltd'},
                        'secondaryText': {'text': 'Dhaka'},
                      },
                    },
                  },
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'displayName': {'text': 'Square Hospitals Ltd'},
              'formattedAddress': 'West Panthapath, Dhaka',
              'location': {'latitude': 23.7516, 'longitude': 90.3811},
            }),
            200,
          );
        }),
      );
      final token = newPlacesSessionToken();

      final suggestions = await routing.autocompletePlaces(
        'Square Hospital',
        sessionToken: token,
        origin: const LatLng(23.75, 90.39),
        languageCode: 'en',
      );
      expect(suggestions.single.mainText, 'Square Hospitals Ltd');
      expect(suggestions.single.secondaryText, 'Dhaka');
      expect(requests, hasLength(1));
      expect(requests.first.url.path, '/v1/places:autocomplete');
      expect(
        requests.first.headers['X-Android-Package'],
        MapsConfig.androidPackageName,
      );
      final body = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(body['sessionToken'], token);
      expect(body['locationBias']['circle']['center']['latitude'], 23.75);
      expect(
        requests.first.headers['X-Goog-FieldMask'],
        contains('structuredFormat'),
      );

      final selected = await routing.resolvePlacePrediction(
        suggestions.single,
        sessionToken: token,
      );
      expect(selected?.label, 'Square Hospitals Ltd, West Panthapath, Dhaka');
      expect(selected?.location.latitude, 23.7516);
      expect(requests.last.method, 'GET');
      expect(requests.last.url.path, '/v1/places/place-123');
      expect(requests.last.url.queryParameters['sessionToken'], token);
      expect(budget.spent, [BillableApi.places, BillableApi.places]);
    },
  );

  test('session tokens are URL-safe and unique', () {
    final first = newPlacesSessionToken();
    final second = newPlacesSessionToken();
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(first, isNot(second));
  });
}
