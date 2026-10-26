// An alarm that only spoke: nothing was visible during the countdown and
// there was nothing to tap or type, so deaf and mute users could not stop it.
// Found on a phone: typing "cancel" during the window went to the model,
// which called it an emergency.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/widgets/emergency_cancel_banner.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

class _SlowTts extends TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<void> stop() async {}
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
  }) async {
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}

class _NoPlanner implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoAlerts implements AlertService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

UserProfile _profile() => UserProfile(
  uid: 'u1',
  role: UserRole.disabledUser,
  magicButtonContacts: const [
    TrustedContact(name: 'Test', phoneNumber: '01700000000', relationship: 'friend', isPrimary: true),
  ],
);

void main() {
  testWidgets('a tap or typed cancel stops the alarm during the countdown', (tester) async {
    final tts = _SlowTts();
    final service = EmergencyService(tts: tts, stt: _SilentStt(), alerts: _NoAlerts(), planner: _NoPlanner());
    final phases = <EmergencyPhase>[];
    service.phase.addListener(() => phases.add(service.phase.value));

    final run = service.trigger(profile: _profile());
    await tester.pump(const Duration(milliseconds: 50));
    expect(service.phase.value, EmergencyPhase.announcing);
    expect(service.cancelPending(), isTrue);

    await tester.pump(const Duration(milliseconds: 400));
    final outcome = await run.timeout(const Duration(seconds: 5));
    expect(outcome.cancelled, isTrue);
    expect(service.phase.value, EmergencyPhase.idle);
    expect(tts.spoken.last, Dashboard.of(AppLanguage.english).emergencyCancelled);
    expect(phases, contains(EmergencyPhase.announcing));
  });

  testWidgets('cancel is refused once there is nothing pending', (tester) async {
    final service = EmergencyService(tts: _SlowTts(), stt: _SilentStt(), alerts: _NoAlerts(), planner: _NoPlanner());
    expect(service.cancelPending(), isFalse);
  });

  testWidgets('the banner appears with a Cancel button while an alarm is pending', (tester) async {
    final phase = ValueNotifier(EmergencyPhase.idle);
    final service = EmergencyService(
      tts: _SlowTts(), stt: _SilentStt(), alerts: _NoAlerts(), planner: _NoPlanner(), phase: phase,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emergencyServiceProvider.overrideWithValue(service),
          emergencyPhaseProvider.overrideWithValue(phase),
        ],
        child: const MaterialApp(
          home: Scaffold(body: EmergencyCancelBanner(language: AppLanguage.english)),
        ),
      ),
    );
    final d = Dashboard.of(AppLanguage.english);
    expect(find.text(d.emergencyBannerCancel), findsNothing);

    final run = service.trigger(profile: _profile());
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text(d.emergencyBannerCancel), findsOneWidget);

    await tester.tap(find.text(d.emergencyBannerCancel));
    await tester.pump(const Duration(milliseconds: 400));
    final outcome = await run;
    expect(outcome.cancelled, isTrue);
    await tester.pump();
    expect(find.text(d.emergencyBannerCancel), findsNothing);
  });
}
