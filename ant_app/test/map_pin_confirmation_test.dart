import 'dart:convert';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/dashboard/screens/map_pin_picker_screen.dart';
import 'package:ant_app/features/dashboard/widgets/destination_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('a picked point is named and confirmed before it is returned', (
    tester,
  ) async {
    final routing = RoutingService(
      client: MockClient((request) async {
        expect(request.url.path, '/reverse');
        return http.Response(
          jsonEncode({'display_name': 'Road 12, Dhanmondi, Dhaka, Bangladesh'}),
          200,
        );
      }),
      backend: RoutingBackend.openStreetMap,
      allowFallback: false,
    );

    DestinationChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              choice = await Navigator.of(context).push<DestinationChoice>(
                MaterialPageRoute(
                  builder: (_) => MapPinPickerScreen(
                    language: AppLanguage.english,
                    initialCentre: const LatLng(23.74, 90.37),
                    routing: routing,
                  ),
                ),
              );
            },
            child: const Text('Pick a point'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Pick a point'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go here'));
    await tester.pumpAndSettle();

    expect(
      find.text('I found Road 12, Dhanmondi. Is this the right place?'),
      findsOneWidget,
    );
    expect(choice, isNull);
    await tester.tap(find.text('Use this point'));
    await tester.pumpAndSettle();

    expect(choice, isNotNull);
    expect(choice!.text, 'Road 12, Dhanmondi');
    expect(choice!.latitude, 23.74);
    expect(choice!.longitude, 90.37);
  });
}
