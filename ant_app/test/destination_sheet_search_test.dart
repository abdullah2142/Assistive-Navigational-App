import 'dart:convert';

import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/features/dashboard/widgets/destination_sheet.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'typing shows geocoder candidates and choosing one returns its coordinates',
    (tester) async {
      final routing = RoutingService(
        client: MockClient((request) async {
          expect(request.url.path, '/search');
          expect(request.url.queryParameters['q'], 'City Center');
          return http.Response(
            jsonEncode([
              {
                'display_name': 'City Center, Dhanmondi, Dhaka, Bangladesh',
                'lat': '23.7401',
                'lon': '90.3742',
              },
            ]),
            200,
          );
        }),
        backend: RoutingBackend.openStreetMap,
        allowFallback: false,
      );

      DestinationChoice? choice;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    choice = await showModalBottomSheet<DestinationChoice>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => DestinationSheet(
                        profile: const UserProfile(
                          uid: 'u1',
                          role: UserRole.disabledUser,
                        ),
                        onPickOnMap: () async => null,
                        routing: routing,
                      ),
                    );
                  },
                  child: const Text('Open destination search'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open destination search'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'City Center');
    await tester.pump(const Duration(milliseconds: 1250));
      await tester.pumpAndSettle();

      expect(find.text('City Center, Dhanmondi'), findsOneWidget);
      await tester.tap(find.text('City Center, Dhanmondi'));
      await tester.pumpAndSettle();

      expect(choice, isNotNull);
      expect(choice!.method, DestinationMethod.typed);
      expect(choice!.latitude, 23.7401);
      expect(choice!.longitude, 90.3742);
      expect(choice!.text, 'City Center, Dhanmondi');
    },
  );
}
