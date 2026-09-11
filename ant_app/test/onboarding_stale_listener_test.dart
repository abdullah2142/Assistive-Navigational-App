// Reproduction + regression guard for the "duplicate Welcome to ANT screen"
// class of bug: an onboarding screen's voice loop re-narrating and
// reopening the microphone *after* the user has already answered, while
// the navigation that answer triggered is still in flight.
//
// Every navigating `OnboardingController` method awaits a Firestore write
// before it calls `_goTo`, and calls `_stopCurrentScreenVoice()` first to
// cut the outgoing screen's mic off. But stopping the mic does not stop
// the *loop*. `listenOnce` simply returns with nothing captured, which the
// loop reads as "the user said something I couldn't match" — so it speaks
// the retry hint, re-reads the full option list after two such misses, and
// opens the mic again. Its only cancel signal is `stepGeneration`, which
// `_goTo` has not bumped yet because it is still behind the await.
//
// To a user who can't see the screen, a screen they already answered
// reading its title and options out at them again *is* that screen coming
// back.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';
import 'package:ant_app/features/onboarding/services/profile_service.dart';

class _RecordingTts extends TtsService {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}

/// A microphone that never hears anything and only ends its session when
/// it is explicitly stopped — exactly what the real recognizer does when
/// the user answers by *tapping* rather than speaking.
class _SilentUntilStoppedStt extends SttService {
  int listenCount = 0;
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
    if (_session != null && !_session!.isCompleted) _session!.complete();
    _session = null;
  }
}

/// The Firestore round trip every navigating controller method awaits.
/// `implements`, not `extends` — `ProfileService`'s constructor reaches for
/// `FirebaseFirestore.instance`, which throws with no initialized app.
class _SlowProfileService implements ProfileService {
  _SlowProfileService({this.fails = false});

  /// Stands in for an offline/permission-denied write.
  final bool fails;
  int saveCount = 0;

  @override
  Future<void> saveProfile(UserProfile profile) async {
    saveCount++;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (fails) throw StateError('network unreachable');
  }

  @override
  Future<UserProfile?> fetchProfile(String uid) async => null;

  /// Recorded rather than ignored — step writes are fire-and-forget, so a
  /// test that cared about ordering would have nothing else to look at.
  final List<OnboardingStep> stepsRecorded = [];

  @override
  Future<void> saveOnboardingStep({required String uid, required OnboardingStep step}) async {
    stepsRecorded.add(step);
    if (fails) throw StateError('network unreachable');
  }

  @override
  Stream<UserProfile?> watchProfile(String uid) => const Stream.empty();
}

class _SeededController extends OnboardingController {
  _SeededController(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

void main() {
  testWidgets(
    'answering by tap does not make the screen re-narrate or reopen the mic '
    'while the save is in flight',
    (tester) async {
      final tts = _RecordingTts();
      final stt = _SilentUntilStoppedStt();
      final profiles = _SlowProfileService();
      final s = Onboarding.of(AppLanguage.english);

      final seed = OnboardingState(
        step: OnboardingStep.visionQuestion,
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ttsServiceProvider.overrideWithValue(tts),
            sttServiceProvider.overrideWithValue(stt),
            profileServiceProvider.overrideWithValue(profiles),
            onboardingControllerProvider.overrideWith(() => _SeededController(seed)),
          ],
          child: const MaterialApp(home: VisionQuestionScreen()),
        ),
      );

      // Intro narration finishes and the mic opens.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(stt.listenCount, 1, reason: 'the screen should be listening by now');
      final narrationBeforeAnswer = tts.spoken.length;

      // The user answers by tapping, not speaking.
      await tester.tap(find.text(s.visionNoneLabel));
      // Mid-flight: the save has NOT resolved yet, so `_goTo` has not run.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        stt.listenCount,
        1,
        reason: 'the voice loop reopened the microphone after the question '
            'was already answered, because stopping the mic reads to it as '
            'an unmatched attempt rather than a cancellation',
      );
      expect(
        tts.spoken.length,
        narrationBeforeAnswer,
        reason: 'the screen narrated again after being answered:\n'
            '${tts.spoken.skip(narrationBeforeAnswer).join('\n')}',
      );

      // Let the save land and the real navigation happen.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(profiles.saveCount, 1);
    },
  );

  // The other half of the fix above: cancelling the screen's voice on every
  // navigating action must not become permanent when the navigation fails
  // and the user is left sitting on that same screen. Onboarding errors are
  // only ever drawn as red text, so without this a blind user hits a silent
  // dead end with nothing to hear and no working microphone.
  testWidgets('a step that fails speaks the error and gives the screen its voice back',
      (tester) async {
    final tts = _RecordingTts();
    final stt = _SilentUntilStoppedStt();
    final profiles = _SlowProfileService(fails: true);
    final s = Onboarding.of(AppLanguage.english);

    final seed = OnboardingState(
      step: OnboardingStep.visionQuestion,
      profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
    );

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ttsServiceProvider.overrideWithValue(tts),
          sttServiceProvider.overrideWithValue(stt),
          profileServiceProvider.overrideWithValue(profiles),
          onboardingControllerProvider.overrideWith(() => _SeededController(seed)),
        ],
        child: Builder(builder: (context) {
          container = ProviderScope.containerOf(context);
          return const MaterialApp(home: VisionQuestionScreen());
        }),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(stt.listenCount, 1);

    await tester.tap(find.text(s.visionNoneLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // We are still on the same step...
    expect(container.read(onboardingControllerProvider).step, OnboardingStep.visionQuestion);
    // ...the user was actually told what went wrong...
    expect(
      tts.spoken.join(' '),
      contains('network unreachable'),
      reason: 'the failure was never spoken — it is only ever drawn as red '
          'text, which this app\'s primary user cannot read',
    );
    // ...and the screen is listening again.
    expect(
      stt.listenCount,
      greaterThan(1),
      reason: 'the screen was left permanently mute after a failed step',
    );
  });
}
