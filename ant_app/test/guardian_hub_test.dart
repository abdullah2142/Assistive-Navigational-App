// Widget-level smoke tests for the Guardian Hub (Module 2). A genuine
// two-role live pairing dance needs two independent Firebase Auth sessions,
// which the local dev environment can't produce in one browser (see
// Module 1's task.md testing caveats) and there's no service-account key
// available here to script around it safely. These tests instead override
// the Firestore-backed stream providers directly, so the widget tree itself
// — the part that can't be checked by `flutter analyze` alone — is verified
// without touching the live project.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/models/live_location.dart';
import 'package:ant_app/features/guardian/providers/guardian_providers.dart';
import 'package:ant_app/features/guardian/screens/guardian_hub_screen.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  testWidgets('Guardian Hub shows a not-paired state when pairedUserId is null', (tester) async {
    final profile = UserProfile(uid: 'caretaker-1', role: UserRole.caretaker);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(home: GuardianHubScreen(profile: profile)),
      ),
    );

    expect(find.text('Not paired with anyone yet.'), findsOneWidget);
  });

  testWidgets('Guardian Hub renders Overwatch/Alerts/Communication panels once paired', (tester) async {
    const disabledUserUid = 'disabled-1';
    final profile = UserProfile(uid: 'caretaker-1', role: UserRole.caretaker, pairedUserId: disabledUserUid);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveLocationStreamProvider(disabledUserUid).overrideWith((ref) => Stream<LiveLocation?>.value(null)),
          alertsStreamProvider(disabledUserUid).overrideWith((ref) => Stream<List<GuardianAlert>>.value(const [])),
          communicationsStreamProvider(disabledUserUid)
              .overrideWith((ref) => Stream<List<CommunicationMessage>>.value(const [])),
        ],
        child: MaterialApp(home: GuardianHubScreen(profile: profile)),
      ),
    );
    await tester.pump();

    expect(find.text('Overwatch'), findsOneWidget);
    expect(find.text('Alerts'), findsOneWidget);
    expect(find.text('Communication'), findsOneWidget);
    expect(find.text('No active alerts.'), findsOneWidget);
    expect(find.text('No messages yet.'), findsOneWidget);
    expect(find.text('Waiting for the first location update…'), findsOneWidget);
  });
}
