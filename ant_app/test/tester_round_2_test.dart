// The 13 September round.
//
// Three of these are real regardless of which build was tested; the rest were
// already fixed in the build distributed that morning and are noted in
// open_bugs rather than here.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/features/onboarding/providers/onboarding_providers.dart';
import 'package:ant_app/features/onboarding/screens/onboarding_flow_screen.dart';
import 'package:ant_app/features/onboarding/screens/passerby_messages_screen.dart';

void main() {
  bool sos(String phrase, AppLanguage language) =>
      LocalIntentMatcher.match(phrase, language)?.name == 'trigger_emergency';

  // "sentence er moddhe help me thakle trigger korche na"
  group('a call for help wrapped in politeness still fires', () {
    // Measured before changing anything: these missed. They are not sentences,
    // they are the same two-word cry with the padding Bangla puts in separate
    // words — the pronoun and the softener — where English keeps them inside
    // "help me" and "please".
    test('Bangla, with the softeners that actually missed', () {
      for (final phrase in [
        'কেউ আমাকে সাহায্য করো',
        'আমাকে একটু সাহায্য করো',
        'দয়া করে সাহায্য করো',
        'কেউ সাহায্য করো',
      ]) {
        expect(sos(phrase, AppLanguage.bangla), isTrue, reason: phrase);
      }
    });

    test('English keeps working', () {
      for (final phrase in ['help me', 'help me please', 'somebody help me', 'please help me']) {
        expect(sos(phrase, AppLanguage.english), isTrue, reason: phrase);
      }
    });

    test('and an errand is still not an emergency', () {
      // The cap is doing real work, which is why politeness is stripped
      // rather than the cap raised: these are four content words each and
      // every one must stay out.
      for (final phrase in ['help me find a pharmacy', 'help me get to Gulshan', 'help me read this']) {
        expect(sos(phrase, AppLanguage.english), isFalse, reason: phrase);
      }
      expect(sos('সাহায্য করো গুলশান যেতে', AppLanguage.bangla), isFalse);
    });

    test('politeness is politeness, not content', () {
      // A pronoun is not filler. Drop `me` and "help me find a pharmacy"
      // becomes a three-word cry.
      expect(sos('help me find a pharmacy', AppLanguage.english), isFalse);
    });
  });

  // "What might you need to tell a stranger? — can not take 'my own message'"
  group('the passer-by screen takes your own message', () {
    late List<String> saved;

    Future<void> pump(WidgetTester tester) async {
      saved = [];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ttsServiceProvider.overrideWithValue(_SilentTts()),
            sttServiceProvider.overrideWithValue(_UnavailableStt()),
            onboardingControllerProvider.overrideWith(
              () => _Recording(
                const OnboardingState(
                  step: OnboardingStep.passerbyMessages,
                  profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
                ),
                (m) => saved = m,
              ),
            ),
          ],
          child: const MaterialApp(home: PasserbyMessagesScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('typed text reaches the saved list without a separate add step',
        (tester) async {
      // The reported trap. Three suggestions are pre-selected, so Continue was
      // always enabled and looked fine — but `allSelected` was built from
      // `_selected + _custom`, and typing put nothing in either. The message
      // sat visible in the field and was dropped on the floor at Continue. A
      // user who cannot see that field had no way to discover it.
      await pump(tester);
      await tester.enterText(find.byType(TextField), 'Please walk me to the bus stop');
      await tester.pump();

      await tester.tap(find.text(Onboarding.of(AppLanguage.english).continueLabel));
      await tester.pump();

      expect(saved, contains('Please walk me to the bus stop'));
    });

    testWidgets('there is a visible button to add it', (tester) async {
      // Before this the only way to commit typed text was the soft keyboard's
      // submit key — which a screen-reader user may never reach, and a sighted
      // one has no reason to guess at.
      await pump(tester);
      final addButton = find.bySemanticsLabel(Onboarding.of(AppLanguage.english).passerbyAddOwnButton);
      expect(addButton, findsOneWidget);

      await tester.enterText(find.byType(TextField), 'I need help crossing');
      await tester.pump();
      await tester.tap(addButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.tap(find.text(Onboarding.of(AppLanguage.english).continueLabel));
      await tester.pump();
      expect(saved, contains('I need help crossing'));
    });
  });

  // "Backbutton of caretaker code input page doesn't work"
  group('the system back gesture', () {
    testWidgets('goes back a step rather than out of the app', (tester) async {
      // The on-screen arrow always worked. This whole flow is one route that
      // switches on state, so Android's back had nothing to pop but the route
      // — which left the app.
      final container = ProviderContainer(overrides: [
        ttsServiceProvider.overrideWithValue(_SilentTts()),
        sttServiceProvider.overrideWithValue(_UnavailableStt()),
        onboardingControllerProvider.overrideWith(
          () => _Seeded(const OnboardingState(
            step: OnboardingStep.userPairingCodeEntry,
            history: [OnboardingStep.languageSelection, OnboardingStep.roleSelection],
            profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
          )),
        ),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingFlowScreen()),
        ),
      );
      await tester.pumpAndSettle();

      // The root route is deliberately not popped — the app must not exit.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(container.read(onboardingControllerProvider).step, OnboardingStep.roleSelection,
          reason: 'the gesture went back a step instead of leaving the app');
    });

    testWidgets('still lets you leave from the very first screen', (tester) async {
      // Refusing there would trap somebody in an app they cannot exit, which
      // is worse than the bug being fixed.
      final container = ProviderContainer(overrides: [
        ttsServiceProvider.overrideWithValue(_SilentTts()),
        sttServiceProvider.overrideWithValue(_UnavailableStt()),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: OnboardingFlowScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(onboardingControllerProvider).history, isEmpty);
      // Unhandled here, so the OS closes the app as it normally would.
      expect(await tester.binding.handlePopRoute(), isFalse);
      expect(container.read(onboardingControllerProvider).step, OnboardingStep.languageSelection);
    });
  });
}

/// Seeds the step and captures what the screen finally saves.
class _Recording extends OnboardingController {
  _Recording(this._seed, this._onSaved);
  final OnboardingState _seed;
  final void Function(List<String>) _onSaved;

  @override
  OnboardingState build() => _seed;

  @override
  Future<void> setPasserbyHelperMessages(List<String> messages) async => _onSaved(messages);
}

class _Seeded extends OnboardingController {
  _Seeded(this._seed);
  final OnboardingState _seed;
  @override
  OnboardingState build() => _seed;
}

class _SilentTts implements TtsService {
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {}
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
