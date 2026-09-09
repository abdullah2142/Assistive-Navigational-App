// The mic button has to be able to close the microphone it opened.
//
// Reported from the device: "clicking on the red mic button after its been
// activated doesnt deactivate it." It never could. One method served both the
// button and wake-word detection, and the reentrancy guard that stops a second
// detection cancelling the first one's session was held for the whole of
// `listenOnce` rather than just the start — so every tap on the red mic hit
// `if (_startingListen) return`, and the branch that would have stopped the
// session was unreachable.
//
// For a user who cannot see that the microphone is open, a mic that will not
// close is worse than a button that does nothing visible.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/features/dashboard/widgets/chat_stream_panel.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  late _HeldOpenStt stt;

  Future<void> pumpPanel(WidgetTester tester) async {
    stt = _HeldOpenStt();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sttServiceProvider.overrideWithValue(stt)],
        child: MaterialApp(
          home: Scaffold(
            body: ChatStreamPanel(
              onOverlayChip: (_, __) {},
              profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder micButton() => find.byIcon(Icons.mic_rounded);
  Finder listeningButton() => find.byIcon(Icons.mic_off_rounded);

  testWidgets('a second tap closes the microphone the first one opened', (tester) async {
    await pumpPanel(tester);

    await tester.tap(micButton());
    await tester.pump();
    expect(listeningButton(), findsOneWidget, reason: 'the mic should be open and showing it');
    expect(stt.listenCount, 1);

    await tester.tap(listeningButton());
    await tester.pump();

    expect(stt.stopCount, 1, reason: 'the tap has to reach SttService.stop()');
    expect(micButton(), findsOneWidget, reason: 'and the button has to go back to idle');
  });

  testWidgets('tapping again does not start a second overlapping session', (tester) async {
    await pumpPanel(tester);

    await tester.tap(micButton());
    await tester.pump();
    await tester.tap(listeningButton());
    await tester.pump();

    expect(stt.listenCount, 1, reason: 'stopping is not starting');
  });

  testWidgets('the mic can be reopened after being closed', (tester) async {
    // The flags have to actually clear, or the button is wedged for the rest
    // of the session — which is how this looked on the device.
    await pumpPanel(tester);

    await tester.tap(micButton());
    await tester.pump();
    await tester.tap(listeningButton());
    await tester.pump();
    await tester.tap(micButton());
    await tester.pump();

    expect(stt.listenCount, 2);
    expect(listeningButton(), findsOneWidget);
  });
}

/// A session that stays open until `stop()` is called — the shape a real
/// listen has while the user is talking, and the one the button could not
/// interrupt.
class _HeldOpenStt extends SttService {
  int listenCount = 0;
  int stopCount = 0;
  Completer<void>? _session;

  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
  }) async {
    listenCount++;
    _session = Completer<void>();
    await _session!.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (_session case final s? when !s.isCompleted) s.complete();
    _session = null;
  }
}
