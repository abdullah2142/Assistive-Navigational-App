// Enforces the onboarding voice rule the user reversed back to explicitly:
// **every screen narrates its title, subtitle and its full set of options
// BEFORE the microphone opens** — never a brief intro with the options
// available only if the user thinks to ask for "help".
//
// This is a cross-screen rule, and the screens that broke it are exactly
// the ones that bypass `OnboardingScaffold`'s shared `_speakThenListen`
// with a custom `autoSpeak: false` loop of their own. A rule enforced only
// in the shared shell silently stops applying to whoever opts out of it,
// which is how `DeafHearingScreen` and `CognitiveAnxietyScreen` drifted —
// so this test drives the real screens and asserts on what was actually
// spoken, rather than trusting each screen to remember on its own.

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
import 'package:ant_app/features/onboarding/screens/cognitive_anxiety_screen.dart';
import 'package:ant_app/features/onboarding/screens/deaf_hearing_screen.dart';
import 'package:ant_app/features/onboarding/screens/magic_button_contacts_screen.dart';
import 'package:ant_app/features/onboarding/screens/role_selection_screen.dart';
import 'package:ant_app/features/onboarding/screens/safe_havens_screen.dart';
import 'package:ant_app/features/onboarding/screens/snapshot_consent_screen.dart';
import 'package:ant_app/features/onboarding/screens/theme_preference_screen.dart';
import 'package:ant_app/features/onboarding/screens/verbosity_voice_screen.dart';
import 'package:ant_app/features/onboarding/screens/vision_question_screen.dart';

/// Records everything spoken instead of hitting the platform TTS engine.
class _RecordingTts extends TtsService {
  final List<String> spoken = [];

  /// Everything narrated before the mic first opened, as one string.
  String get transcript => spoken.join(' ');

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}

/// A microphone that is never available. Every voice loop in the app checks
/// `ensureAvailable()` before its first `listenOnce`, and gives up quietly
/// when it's false — so each screen speaks exactly its pre-mic narration
/// and then stops, which is precisely what this test wants to inspect.
class _UnavailableStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => false;

  @override
  Future<void> stop() async {}
}

/// Seeds the onboarding state so a screen can be pumped on its own.
class _SeededController extends OnboardingController {
  _SeededController(this._seed);
  final OnboardingState _seed;

  @override
  OnboardingState build() => _seed;
}

void main() {
  /// Pumps [screen] with a profile in [language] and returns everything it
  /// narrated before opening the mic.
  Future<_RecordingTts> narrationOf(
    WidgetTester tester,
    Widget screen, {
    required OnboardingStep step,
    AppLanguage language = AppLanguage.english,
  }) async {
    final tts = _RecordingTts();
    final seed = OnboardingState(
      step: step,
      language: language,
      profile: UserProfile(uid: 'u1', role: UserRole.disabledUser, language: language),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ttsServiceProvider.overrideWithValue(tts),
          sttServiceProvider.overrideWithValue(_UnavailableStt()),
          onboardingControllerProvider.overrideWith(() => _SeededController(seed)),
        ],
        child: MaterialApp(home: screen),
      ),
    );
    // Narration starts in a post-frame callback and awaits each `speak`.
    await tester.pumpAndSettle();
    return tts;
  }

  /// Every screen that drives its own voice loop instead of using
  /// `OnboardingScaffold`'s shared one, with the strings each MUST have
  /// spoken before its microphone opened.
  ///
  /// `expected` is deliberately the option/field text a user needs in order
  /// to answer, not just the title — a title-only intro is exactly the bug.
  void expectNarrates(
    String description, {
    required Widget Function() screen,
    required OnboardingStep step,
    required List<String> Function(Onboarding s) expected,
    AppLanguage language = AppLanguage.english,
  }) {
    testWidgets(description, (tester) async {
      final s = Onboarding.of(language);
      final tts = await narrationOf(tester, screen(), step: step, language: language);

      expect(tts.spoken, isNotEmpty, reason: 'nothing was narrated at all');
      for (final phrase in expected(s)) {
        expect(
          tts.transcript,
          contains(phrase),
          reason: 'was never spoken before the mic opened.\nActually narrated:\n${tts.spoken.join('\n')}',
        );
      }
    });
  }

  group('screens with a custom voice loop (autoSpeak: false)', () {
    expectNarrates(
      'DeafHearingScreen narrates both Yes/No options up front',
      screen: DeafHearingScreen.new,
      step: OnboardingStep.deafHearingQuestion,
      expected: (s) => [
        s.deafTitle,
        s.deafSubtitle,
        s.deafYesLabel,
        s.deafYesDescription,
        s.deafNoLabel,
        s.deafNoDescription,
      ],
    );

    expectNarrates(
      'CognitiveAnxietyScreen narrates both questions and how to answer them',
      screen: CognitiveAnxietyScreen.new,
      step: OnboardingStep.cognitiveAnxietyQuestion,
      expected: (s) => [
        s.cognitiveTitle,
        s.cognitiveSubtitle,
        s.cognitiveSpokenHint,
        s.cognitiveCrowdedQuestion,
        s.voiceAnswerYesOrNo,
      ],
    );

    expectNarrates(
      'SafeHavensScreen narrates which fields exist before asking for one',
      screen: SafeHavensScreen.new,
      step: OnboardingStep.safeHavens,
      expected: (s) => [
        s.safeHavensTitle,
        s.safeHavensSubtitle,
        s.safeHavensSpokenHint,
        s.safeHavensHomePromptSpoken,
      ],
    );

    expectNarrates(
      'VerbosityVoiceScreen narrates the chattiness options up front',
      screen: VerbosityVoiceScreen.new,
      step: OnboardingStep.verbosityAndVoice,
      expected: (s) => [s.verbosityTitle, s.verbositySpokenHint],
    );

    expectNarrates(
      'MagicButtonContactsScreen narrates what it is about to collect',
      screen: MagicButtonContactsScreen.new,
      step: OnboardingStep.magicButtonContacts,
      expected: (s) => [s.contactsTitle, s.contactsSpokenHint],
    );
  });

  group('screens using the shared OnboardingScaffold loop', () {
    expectNarrates(
      'RoleSelectionScreen narrates both roles',
      screen: RoleSelectionScreen.new,
      step: OnboardingStep.roleSelection,
      expected: (s) => [s.roleDisabledUserLabel, s.roleCaretakerLabel],
    );

    expectNarrates(
      'VisionQuestionScreen narrates both vision options',
      screen: VisionQuestionScreen.new,
      step: OnboardingStep.visionQuestion,
      expected: (s) => [s.visionNoneLabel, s.visionLowLabel],
    );

    expectNarrates(
      'ThemePreferenceScreen narrates both themes',
      screen: ThemePreferenceScreen.new,
      step: OnboardingStep.themePreference,
      expected: (s) => [s.themeLightLabel, s.themeDarkLabel],
    );

    expectNarrates(
      'SnapshotConsentScreen narrates both consent options',
      screen: SnapshotConsentScreen.new,
      step: OnboardingStep.snapshotConsent,
      expected: (s) => [s.snapshotAlwaysLabel, s.snapshotAskLabel],
    );
  });

  group('Bangla narration', () {
    // The option numbering was hardcoded English ("Option 1: <Bangla
    // label>") in six screens — jarring mid-sentence for a Bangla listener,
    // and read with an English accent by a bn-BD voice.
    expectNarrates(
      'numbers options in Bangla, not "Option 1"',
      screen: RoleSelectionScreen.new,
      step: OnboardingStep.roleSelection,
      language: AppLanguage.bangla,
      expected: (s) => ['বিকল্প ১', 'বিকল্প ২', s.roleDisabledUserLabel],
    );

    testWidgets('no English "Option N" leaks into Bangla narration', (tester) async {
      final tts = await narrationOf(
        tester,
        const VisionQuestionScreen(),
        step: OnboardingStep.visionQuestion,
        language: AppLanguage.bangla,
      );
      expect(tts.transcript, isNot(contains('Option ')));
    });
  });
}
