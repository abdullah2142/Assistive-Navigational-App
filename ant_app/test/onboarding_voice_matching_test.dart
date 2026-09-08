import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Voice answers that onboarding refused to accept.
///
/// Three reports, two causes:
///
///  - "how to talk to the app doesn't take 'I am ready'"
///  - "anywhere you go often doesn't take a place name, but does take skip"
///  - "a few more questions doesn't take no, but does take yes"
///
/// The first two were the same crash. The third was classification.
void main() {
  final en = Onboarding.of(AppLanguage.english);

  group('fuzzyVoiceMatch survives short words', () {
    // `.clamp(3, word.length)` throws when the word is shorter than 3 — a
    // lower limit above the upper one. The exception escaped through
    // `matches()` into the STT `onResult` callback, so the whole recognition
    // attempt died and the screen looked like it was ignoring the user.
    test('a two-letter word in the target does not throw', () {
      expect(() => fuzzyVoiceMatch('i am ready', 'I am ready'), returnsNormally);
      expect(() => fuzzyVoiceMatch('anything', 'no thanks'), returnsNormally);
      expect(() => fuzzyVoiceMatch('go', 'ok'), returnsNormally);
    });

    test('a two-letter word in the spoken text does not throw', () {
      expect(() => fuzzyVoiceMatch('ok', 'continue'), returnsNormally);
    });

    test('short words still require an exact hit, not a near miss', () {
      // The reason the near-miss path is skipped for them rather than
      // widened: there is no room in a three-letter word for a miss that is
      // not simply a different word.
      expect(fuzzyVoiceMatch('cat', 'car'), isFalse);
      expect(fuzzyVoiceMatch('car', 'car'), isTrue);
    });

    test('the male/female lesson still holds', () {
      // "male" must not near-miss its way into "female" — the original bug
      // this function was rewritten to fix. (The full labels "male voice"
      // and "female voice" do still match each other, on the shared word
      // "voice"; the options are told apart by the gendered word, which is
      // what this guards.)
      expect(fuzzyVoiceMatch('male', 'female'), isFalse);
    });
  });

  group('command tour accepts "I am ready"', () {
    OnboardingVoiceChoice continueChoice() => OnboardingVoiceChoice(
          label: en.commandTourContinueLabel,
          synonyms: en.commandTourContinueSynonyms,
          onSelect: () {},
        );

    test('the label itself, said back verbatim', () {
      // The app reads "I am ready" out as the option; saying it back is the
      // single most likely thing a user does.
      expect(continueChoice().matches('i am ready'), isTrue);
    });

    test('natural variants', () {
      expect(continueChoice().matches("i'm ready"), isTrue);
      expect(continueChoice().matches('ready'), isTrue);
    });

    test('the repeat option is not matched by a readiness answer', () {
      final repeat = OnboardingVoiceChoice(
        label: en.commandTourRepeatLabel,
        synonyms: en.commandTourRepeatSynonyms,
        onSelect: () {},
      );
      expect(repeat.matches('i am ready'), isFalse);
    });
  });

  group('a place name is not a skip command', () {
    // The skip list contains "no thanks", so the crash fired against every
    // dictated name before it could be accepted — skip worked, names did not.
    bool readsAsSkip(String heard) =>
        en.placesSkipSynonyms.any((w) => fuzzyVoiceMatch(heard, w));

    test('ordinary place names are kept', () {
      for (final name in ['college', 'my office', 'gulshan', 'notun bazar', 'school']) {
        expect(readsAsSkip(name), isFalse, reason: name);
      }
    });

    test('actual skip words still skip', () {
      for (final word in ['skip', 'done', 'later', 'nothing']) {
        expect(readsAsSkip(word), isTrue, reason: word);
      }
    });
  });

  group('yes/no answers that are not bare particles', () {
    bool? crowded(String heard) => classifyTraitYesNo(
          heard,
          presentPhrases: en.cognitiveCrowdedPresentPhrases,
          absentPhrases: en.cognitiveCrowdedAbsentPhrases,
        );

    test('overlapping phrases resolve to the more specific one', () {
      // "bother me" is a present phrase and "don't bother me" an absent one,
      // and the second contains the first. Scoring both as equal made this
      // an unresolvable tie, so the question was asked over and over.
      expect(crowded("they don't bother me"), isFalse);
      expect(crowded('crowds bother me'), isTrue);
    });

    test('common negative openers are understood', () {
      expect(crowded('not really'), isFalse);
      expect(crowded('not at all'), isFalse);
      expect(crowded('never'), isFalse);
    });

    test('a long answer that opens with yes or no is decided by it', () {
      // The length guard exists for a sentence that merely mentions "yes"
      // somewhere. One that starts with it is answering the question.
      expect(crowded("no it doesn't bother me at all"), isFalse);
      expect(crowded('yes they make me very uncomfortable'), isTrue);
    });

    test('bare answers still work', () {
      expect(crowded('no'), isFalse);
      expect(crowded('yes'), isTrue);
      expect(crowded('nope'), isFalse);
    });

    test('a genuinely unclear answer still returns null rather than guessing', () {
      // Re-prompting is correct here. Guessing commits an accessibility
      // setting the user did not choose.
      expect(crowded('a little bit'), isNull);
    });
  });
}
