// Choosing whether the options get read out — open_bugs item 62.
//
// Reported: "turn on narration of choices, do not postpone narration of
// choices."
//
// The triage read this as the profile resuming with the setting off, or as
// the question being heard as an offer to postpone, and said the wording was
// worth a look. The wording was fine. **The tester's own sentence selected the
// opposite option**, and so did every other natural way of saying "enable
// this":
//
//   "turn on narration of choices"  ->  Only when I ask
//   "turn it on"                    ->  Only when I ask
//   "keep it on"                    ->  Only when I ask
//
// `on request` was a synonym for the quiet option, `fuzzyMatchScore` accepts
// half a target's words, and "turn **on**" is half of "**on** request" — so
// the enable-phrase scored 0.5 for disabling and 0.0 for enabling. The
// distinctive word in "on request" is "request"; "on" carries none of the
// meaning and is the most common enable-word in English.
//
// Exactly the defect that made "Low vision" select "No vision": a half-match
// on a word shared by both answers.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';

void main() {
  for (final language in AppLanguage.values) {
    final s = Onboarding.of(language);

    OnboardingVoiceChoice always() => OnboardingVoiceChoice(
          label: s.optionNarrationAlwaysLabel,
          synonyms: s.optionNarrationAlwaysSynonyms,
          onSelect: () {},
        );
    OnboardingVoiceChoice onRequest() => OnboardingVoiceChoice(
          label: s.optionNarrationOnRequestLabel,
          synonyms: s.optionNarrationOnRequestSynonyms,
          onSelect: () {},
        );

    /// Which option an utterance actually selects, decided the same way the
    /// screen decides it — best score wins.
    String chosen(String heard) {
      final a = always().matchScore(heard);
      final r = onRequest().matchScore(heard);
      if (a == 0 && r == 0) return 'neither';
      return a >= r ? 'always' : 'onRequest';
    }

    group('${language.name}: asking for narration turns it on', () {
      final wantsItOn = language == AppLanguage.bangla
          ? const ['চালু করো', 'প্রতিবার পড়ে শোনাও', 'হ্যাঁ', 'শোনাও']
          : const [
              // The reported sentence, verbatim.
              'turn on narration of choices',
              'turn it on',
              'keep it on',
              'read them every time',
              'read the choices out',
              'yes',
              'always read the options',
            ];
      for (final said in wantsItOn) {
        test('"$said"', () => expect(chosen(said), 'always'));
      }
    });

    group('${language.name}: asking for quiet still turns it off', () {
      // The fix must not simply make one option unreachable.
      final wantsItOff = language == AppLanguage.bangla
          ? const ['না', 'শুধু চাইলে', 'দরকার নেই']
          : const ['no', 'only when i ask', 'when i ask', 'stay quiet'];
      for (final said in wantsItOff) {
        test('"$said"', () => expect(chosen(said), 'onRequest'));
      }
    });
  }

  test('no synonym of one option is a partial match for the other', () {
    // The general form of this bug, checked rather than fixed case by case:
    // every synonym must select its own option outright. A synonym that ties
    // or loses is one the list order decides, which is how "Low vision"
    // selected "No vision".
    for (final language in AppLanguage.values) {
      final s = Onboarding.of(language);
      final always = OnboardingVoiceChoice(
        label: s.optionNarrationAlwaysLabel,
        synonyms: s.optionNarrationAlwaysSynonyms,
        onSelect: () {},
      );
      final onRequest = OnboardingVoiceChoice(
        label: s.optionNarrationOnRequestLabel,
        synonyms: s.optionNarrationOnRequestSynonyms,
        onSelect: () {},
      );

      for (final synonym in [s.optionNarrationAlwaysLabel, ...s.optionNarrationAlwaysSynonyms]) {
        expect(always.matchScore(synonym), greaterThan(onRequest.matchScore(synonym)),
            reason: '"$synonym" (${language.name}) should read the options out');
      }
      for (final synonym in [
        s.optionNarrationOnRequestLabel,
        ...s.optionNarrationOnRequestSynonyms
      ]) {
        expect(onRequest.matchScore(synonym), greaterThan(always.matchScore(synonym)),
            reason: '"$synonym" (${language.name}) should keep the options quiet');
      }
    }
  });

  test('"on request" is not a synonym, because "on" is not about requesting', () {
    // Guards the specific string this bug was made of.
    for (final language in AppLanguage.values) {
      expect(Onboarding.of(language).optionNarrationOnRequestSynonyms,
          isNot(contains('on request')));
    }
  });
}
