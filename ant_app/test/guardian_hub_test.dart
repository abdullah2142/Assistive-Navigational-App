// Widget-level smoke tests for the Guardian Hub (Module 2). A genuine
// two-role live pairing dance needs two independent Firebase Auth sessions,
// which the local dev environment can't produce in one browser (see
// Module 1's task.md testing caveats) and there's no service-account key
// available here to script around it safely. These tests instead override
// the Firestore-backed stream providers directly, so the widget tree itself
// — the part that can't be checked by `flutter analyze` alone — is verified
// without touching the live project.

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;

import 'package:ant_app/core/config/maps_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/models/live_location.dart';
import 'package:ant_app/features/guardian/providers/guardian_providers.dart';
import 'package:ant_app/features/guardian/screens/guardian_hub_screen.dart';
import 'package:ant_app/features/guardian/widgets/communication_hub_panel.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  testWidgets(
    'caretaker composer grows sideways and keeps voicemail separate',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sttServiceProvider.overrideWithValue(_SilentStt()),
            profileStreamProvider('disabled-1').overrideWith(
              (ref) => Stream.value(
                UserProfile(uid: 'disabled-1', role: UserRole.disabledUser),
              ),
            ),
            communicationsStreamProvider('disabled-1').overrideWith(
              (ref) => Stream.value(const <CommunicationMessage>[]),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CommunicationHubPanel(
                  disabledUserUid: 'disabled-1',
                  caretakerUid: 'caretaker-1',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final field = find.byType(TextField);
      expect(find.text('Request snapshot'), findsOneWidget);
      expect(find.text('Send image'), findsOneWidget);
      expect(find.text('Voice message'), findsOneWidget);
      expect(tester.widget<TextField>(field).maxLines, 1);
      final compactWidth = tester.getSize(field).width;

      await tester.enterText(field, 'Checking in');
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.getSize(field).width, greaterThan(compactWidth));
      expect(find.text('Request snapshot'), findsNothing);
      expect(find.text('Send image'), findsNothing);
      expect(find.text('Voice message'), findsNothing);
      expect(find.byTooltip('Speak to compose'), findsNothing);
      expect(find.byTooltip('Stop speech input'), findsNothing);
    },
  );

  testWidgets(
    'Guardian Hub shows a not-paired state when pairedUserId is null',
    (tester) async {
      final profile = UserProfile(uid: 'caretaker-1', role: UserRole.caretaker);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(home: GuardianHubScreen(profile: profile)),
        ),
      );

      expect(find.text('Not paired with anyone yet.'), findsOneWidget);
    },
  );

  testWidgets(
    'Guardian Hub renders Overwatch/Alerts/Communication panels once paired',
    (tester) async {
      const disabledUserUid = 'disabled-1';
      final profile = UserProfile(
        uid: 'caretaker-1',
        role: UserRole.caretaker,
        pairedUserId: disabledUserUid,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            liveLocationStreamProvider(disabledUserUid)
                .overrideWith((ref) => Stream<LiveLocation?>.value(null)),
            alertsStreamProvider(disabledUserUid).overrideWith(
              (ref) => Stream<List<GuardianAlert>>.value(const []),
            ),
            communicationsStreamProvider(disabledUserUid).overrideWith(
              (ref) => Stream<List<CommunicationMessage>>.value(const []),
            ),
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
      expect(
        find.text('Waiting for the first location update…'),
        findsOneWidget,
      );
    },
  );

  // Regression guard for the OpenStreetMap swap: `flutter_map`'s tile
  // provider mutates the headers map it's handed, so a `const` literal
  // there crashed with "Unsupported operation: Cannot modify unmodifiable
  // map" the moment a real location arrived and the map actually rendered.
  // The empty-state test above never reaches that code path.
  testWidgets('Overwatch renders a real map once a location arrives', (
    tester,
  ) async {
    const disabledUserUid = 'disabled-1';
    final profile = UserProfile(
      uid: 'caretaker-1',
      role: UserRole.caretaker,
      pairedUserId: disabledUserUid,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          liveLocationStreamProvider(disabledUserUid).overrideWith(
            (ref) => Stream<LiveLocation?>.value(
              const LiveLocation(
                uid: disabledUserUid,
                lat: 23.8103,
                lng: 90.4125,
                batteryPercent: 72,
              ),
            ),
          ),
          alertsStreamProvider(
            disabledUserUid,
          ).overrideWith((ref) => Stream<List<GuardianAlert>>.value(const [])),
          communicationsStreamProvider(disabledUserUid).overrideWith(
            (ref) => Stream<List<CommunicationMessage>>.value(const []),
          ),
        ],
        child: MaterialApp(home: GuardianHubScreen(profile: profile)),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    // Whichever renderer MapsConfig selects — the panel swaps between them
    // and the caretaker gets a real map either way. Asserting the concrete
    // widget tied this test to a config flag rather than to the behaviour.
    expect(
      MapsConfig.useOsmTiles
          ? find.byType(FlutterMap)
          : find.byType(gmaps.GoogleMap),
      findsOneWidget,
    );
    expect(find.text('72%'), findsOneWidget);
  });
}

class _SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {}

  @override
  Future<void> stop() async {}
}
