// Whether a screen reads its choices out before listening, or waits to be
// asked — now the user's decision rather than ours.
//
// This has shipped both ways and each reverted the other, because each was
// right for a different person. `OnboardingScaffold` first deferred the option
// list until somebody said "options", so a user who already knew their answer
// did not sit through a read-out. Live testing reverted that: a microphone
// opening in silence reads as the app "just recording", with no idea what to
// say. Both findings are real. So it is asked.
//
// The default stays "read them": it is the previous behaviour, and it is the
// safer answer for someone who cannot see the screen — a user who finds it
// slow can say so, while a user left in silence has nothing to say it to.

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
import 'package:ant_app/features/onboarding/screens/mobility_question_screen.dart';
import 'package:ant_app/features/onboarding/screens/option_narration_screen.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';

void main() {
  final en = Onboarding.of(AppLanguage.english);

  Future<_RecordingTts> narrationOf(
    WidgetTester tester,
    Widget screen, {
    required OnboardingStep step,
    required bool narrateOptionsFirst,
  }) async {
    final tts = _RecordingTts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ttsServiceProvider.overrideWithValue(tts),
          sttServiceProvider.overrideWithValue(_UnavailableStt()),
          onboardingControllerProvider.overrideWith(
            () => _SeededController(
              OnboardingState(
                step: step,
                profile: UserProfile(
                  uid: 'u1',
                  role: UserRole.disabledUser,
                  narrateOptionsFirst: narrateOptionsFirst,
                ),
              ),
            ),
          ),
        ],
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pumpAndSettle();
    return tts;
  }

  group('the preference decides what a screen says before it listens', () {
    testWidgets('"read them every time" reads the options out', (tester) async {
      final tts = await narrationOf(tester, const MobilityQuestionScreen(),
          step: OnboardingStep.mobilityQuestion, narrateOptionsFirst: true);

      expect(tts.transcript, contains(en.mobilityTitle));
      expect(tts.transcript, contains(en.mobilityWhiteCaneLabel));
      expect(tts.transcript, contains(en.mobilityUnassistedLabel));
    });

    testWidgets('"only when I ask" holds them back', (tester) async {
      final tts = await narrationOf(tester, const MobilityQuestionScreen(),
          step: OnboardingStep.mobilityQuestion, narrateOptionsFirst: false);

      expect(tts.transcript, contains(en.mobilityTitle), reason: 'the question is still asked');
      expect(tts.transcript, isNot(contains(en.mobilityWhiteCaneLabel)));
      expect(tts.transcript, isNot(contains(en.mobilityUnassistedLabel)));
    });

    testWidgets('but never opens the mic in silence', (tester) async {
      // The silence itself is what got the deferred version reverted the first
      // time. Holding the list back must not mean saying nothing — it means
      // saying the one thing that brings the list back.
      final tts = await narrationOf(tester, const MobilityQuestionScreen(),
          step: OnboardingStep.mobilityQuestion, narrateOptionsFirst: false);

      expect(tts.transcript, contains(en.optionNarrationKeywordHint));
    });

    testWidgets('and the keyword it names is one the matcher actually knows',
        (tester) async {
      // A hint that tells the user a word `isHelpRequest` does not recognise
      // would be worse than no hint: they would say it and get nothing.
      expect(isHelpRequest('options'), isTrue);
      expect(isHelpRequest('বিকল্প'), isTrue);
    });
  });

  group('the question about narration narrates itself', () {
    testWidgets('even for a user who has already asked for quiet', (tester) async {
      // Going back to change your mind must not hand you a silent microphone
      // and two options you cannot hear — unable to answer by voice the very
      // question about answering by voice.
      final tts = await narrationOf(tester, const OptionNarrationScreen(),
          step: OnboardingStep.optionNarrationQuestion, narrateOptionsFirst: false);

      expect(tts.transcript, contains(en.optionNarrationAlwaysLabel));
      expect(tts.transcript, contains(en.optionNarrationOnRequestLabel));
    });
  });

  group('the setting itself', () {
    test('defaults to reading them out, which is the old behaviour', () {
      expect(const UserProfile(uid: 'u1', role: UserRole.disabledUser).narrateOptionsFirst, isTrue);
    });

    test('survives a Firestore round trip', () {
      final profile = const UserProfile(
          uid: 'u1', role: UserRole.disabledUser, narrateOptionsFirst: false);
      expect(UserProfile.fromJson(profile.toJson()).narrateOptionsFirst, isFalse);
    });

    test('a profile written before the question existed keeps hearing them', () {
      final json = const UserProfile(uid: 'u1', role: UserRole.disabledUser).toJson()
        ..remove('narrateOptionsFirst');
      expect(UserProfile.fromJson(json).narrateOptionsFirst, isTrue);
    });
  });

  group('who gets asked', () {
    test('a hearing user does', () {
      expect(shouldAskAboutOptionNarration(isDeafOrHardOfHearing: false), isTrue);
    });

    test('a Deaf user does not', () {
      // Spoken guidance is switched off for them the moment they say so, so
      // this would be a question about something that does not happen.
      expect(shouldAskAboutOptionNarration(isDeafOrHardOfHearing: true), isFalse);
    });
  });
}

class _RecordingTts extends TtsService {
  final List<String> spoken = [];
  String get transcript => spoken.join(' ');

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);

  @override
  Future<void> stop() async {}
}

/// Never available, so every screen speaks exactly its pre-mic narration and
/// then stops — which is the thing under inspection here.
class _UnavailableStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => false;

  @override
  Future<void> stop() async {}
}

class _SeededController extends OnboardingController {
  _SeededController(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}
