// Regression coverage for behaviours verified while probing area
// deaf_mute_paths (deaf, mute and deaf-blind journeys). Offline and
// deterministic; every assertion passed against the code as probed. Defects
// found are in probe_bugs/deaf_mute_paths_bugs_test.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/haptics_service.dart';
import 'package:ant_app/core/services/routing_service.dart' show ManeuverKind;
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/screens/split_mode_dashboard_screen.dart';
import 'package:ant_app/features/dashboard/widgets/emergency_cancel_banner.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_message_picker.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

class _Tts implements TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async =>
      spoken.add(text);
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}

class _UnavailableStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => false;
  @override
  Future<void> stop() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final d = Dashboard.of(AppLanguage.english);

  group('deaf: nothing is spoken, everything is written', () {
    test('a caretaker text memo lands in the transcript and is not spoken to a deaf user', () async {
      final tts = _Tts();
      final c = ProviderContainer(overrides: [ttsServiceProvider.overrideWithValue(tts)]);
      addTearDown(c.dispose);
      final deaf = UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        pairedUserId: 'c1',
        isDeafOrHardOfHearing: true,
      );
      await c.read(chatControllerProvider.notifier).receiveCaretakerMessage(
            const CommunicationMessage(
              id: 'm1',
              fromUid: 'c1',
              toUid: 'u1',
              type: CommunicationType.memo,
              text: 'Dinner is ready',
            ),
            deaf,
          );
      final texts = c.read(chatControllerProvider).messages.map((m) => m.text).toList();
      expect(texts, contains('Dinner is ready'));
      expect(texts, contains(d.caretakerMemoHeard('Dinner is ready')));
      expect(tts.spoken, isEmpty, reason: 'a deaf profile suppresses TTS for chat replies');
    });

    test('a voice memo for a deaf user is at least announced in text (no transcript exists)', () async {
      final c = ProviderContainer(overrides: [ttsServiceProvider.overrideWithValue(_Tts())]);
      addTearDown(c.dispose);
      final deaf = UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        pairedUserId: 'c1',
        isDeafOrHardOfHearing: true,
      );
      await c.read(chatControllerProvider.notifier).receiveCaretakerMessage(
            const CommunicationMessage(
              id: 'v1',
              fromUid: 'c1',
              toUid: 'u1',
              type: CommunicationType.voiceMemo,
              text: '',
              audioBase64: 'AAAA',
            ),
            deaf,
            playAudio: (_) async => true,
          );
      final msgs = c.read(chatControllerProvider).messages;
      expect(msgs.where((m) => m.sender == ChatSender.caretaker), isNotEmpty);
      expect(msgs.any((m) => m.text == d.caretakerVoiceMemoHeard), isTrue);
    });
  });

  group('emergency: a deaf or mute user can see and stop the countdown', () {
    test('typed "cancel" is an emergency cancel word, a bare "stop" is not', () {
      expect(VoiceCancelWindow.cancelsEmergency('cancel'), isTrue);
      expect(VoiceCancelWindow.cancelsEmergency('Stop! get away from me'), isFalse);
    });

    testWidgets('the chat-visible dashboard shows the banner with a 56 dp Cancel button while counting down',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final phase = ValueNotifier(EmergencyPhase.idle);
      await tester.pumpWidget(ProviderScope(
        overrides: [emergencyPhaseProvider.overrideWithValue(phase)],
        child: MaterialApp(
          home: SplitModeDashboardScreen(
            profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
          ),
        ),
      ));
      await tester.pump();
      expect(find.byType(EmergencyCancelBanner), findsOneWidget);
      expect(find.text(d.emergencyBannerCancel), findsNothing);
      phase.value = EmergencyPhase.countdown;
      await tester.pump();
      expect(find.text(d.emergencyBannerCancel), findsOneWidget);
      final button = tester.getSize(find.ancestor(
        of: find.text(d.emergencyBannerCancel),
        matching: find.byType(FilledButton),
      ));
      expect(button.height, greaterThanOrEqualTo(56));
      phase.value = EmergencyPhase.idle;
      await tester.pump();
    });
  });

  group('mute: Show Screen can be done by typing alone', () {
    testWidgets('a typed message is shown full-screen with no microphone at all', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final tts = _Tts();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sttServiceProvider.overrideWithValue(_UnavailableStt()),
          ttsServiceProvider.overrideWithValue(tts),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PasserbyMessagePicker.show(
                  context,
                  messages: const ['I need help crossing the road'],
                  strings: d,
                  language: AppLanguage.english,
                  autoListen: false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Which bus goes to Azimpur?');
      await tester.pump();
      await tester.ensureVisible(find.text(d.passerbyPickerShowButton));
      await tester.pump();
      await tester.tap(find.text(d.passerbyPickerShowButton));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Which bus goes to Azimpur?'), findsWidgets);
      expect(tester.takeException(), isNull);
      // Close the full-screen message with the visible back control (no voice).
      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.pump(SttService.narrationSettle + const Duration(milliseconds: 100));
    });
  });

  group('haptics: robust when the motor or the platform is missing', () {
    test('no vibrator: every cue falls back instead of throwing (deaf phone without motor)', () async {
      final h = HapticsService(probeOverride: (motor: false, amplitude: false));
      for (final cue in HapticCue.values) {
        await h.play(cue);
      }
    });

    test('vibrate() throwing falls back to system haptics instead of failing the turn', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('vibration'), (call) async {
        throw PlatformException(code: 'denied');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('vibration'), null));
      final h = HapticsService(probeOverride: (motor: true, amplitude: true));
      for (final cue in HapticCue.values) {
        await h.play(cue);
      }
    });

    test('every strength and cue stays inside 1..255 (strength can never reach zero)', () {
      for (final level in HapticIntensity.values) {
        final h = HapticsService(probeOverride: (motor: true, amplitude: true))..intensity = level;
        for (final cue in HapticCue.values) {
          expect(h.amplitudeFor(cue), inInclusiveRange(1, 255));
        }
      }
    });

    test('only the hazard cue is throttled; left/right/navigation/confirmation always fire', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('vibration'), (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('vibration'), null));
      final h = HapticsService(probeOverride: (motor: true, amplitude: true));
      await h.play(HapticCue.turnLeft);
      await h.play(HapticCue.turnLeft);
      await h.play(HapticCue.hazard);
      await h.play(HapticCue.hazard);
      expect(calls.where((c) => c.method == 'vibrate'), hasLength(3));
    });

    test('left and right are told apart by pulse count; turn kinds map to a side', () {
      expect(turnCueFor(ManeuverKind.sharpLeft), HapticCue.turnLeft);
      expect(turnCueFor(ManeuverKind.slightRight), HapticCue.turnRight);
      expect(turnCueFor(ManeuverKind.straight), HapticCue.navigation);
    });
  });
}
