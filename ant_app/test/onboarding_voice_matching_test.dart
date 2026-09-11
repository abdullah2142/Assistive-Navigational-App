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

  group('the best-matching choice wins, not the first', () {
    // Observed on device: saying "Low vision." selected "No vision" — the
    // opposite answer — because both share the word "vision", the matcher
    // accepts half a target's words, and "No vision" was listed first. The
    // discriminating word was the whole content of the answer.
    List<OnboardingVoiceChoice> visionChoices() => [
          OnboardingVoiceChoice(label: en.visionNoneLabel, synonyms: en.visionNoneSynonyms, onSelect: () {}),
          OnboardingVoiceChoice(label: en.visionLowLabel, synonyms: en.visionLowSynonyms, onSelect: () {}),
          OnboardingVoiceChoice(label: en.visionFullLabel, synonyms: en.visionFullSynonyms, onSelect: () {}),
        ];

    String? bestLabel(List<OnboardingVoiceChoice> choices, String heard) {
      var best = 0.0;
      String? winner;
      for (final choice in choices) {
        final score = choice.matchScore(heard);
        if (score > best) {
          best = score;
          winner = choice.label;
        }
      }
      return winner;
    }

    test('"low vision" does not select "no vision"', () {
      expect(bestLabel(visionChoices(), 'Low vision.'), isNot(en.visionNoneLabel));
    });

    test('each vision answer selects itself', () {
      expect(bestLabel(visionChoices(), 'No vision.'), en.visionNoneLabel);
      expect(bestLabel(visionChoices(), 'Full vision.'), en.visionFullLabel);
    });

    test('trailing punctuation does not weaken a match', () {
      // Cloud STT punctuates, so "vision." never equalling "vision" was the
      // common case rather than an edge one.
      expect(fuzzyVoiceMatch('White cane.', 'White cane'), isTrue);
      expect(fuzzyVoiceMatch('white cane', 'White cane'), isTrue);
    });

    test('a misheard "I walk unassisted" still reaches its synonym', () {
      // Heard on device as "I work. An assisted." three times in a row. The
      // synonym "unassisted" contains "assisted" — but the heard word carried
      // a full stop, so the containment check compared against "assisted."
      // and failed.
      final unassisted = OnboardingVoiceChoice(
        label: en.mobilityUnassistedLabel,
        synonyms: en.mobilityUnassistedSynonyms,
        onSelect: () {},
      );
      expect(unassisted.matches('I work. An assisted.'), isTrue);
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

    test('"know" alone is the misheard "no" it almost always is', () {
      // Observed on device, three times running: answering "no" produced
      // interim results of "No." and a final of "Know." from Cloud STT's
      // command_and_search model. Whole-word matching — which exists so the
      // "no" inside "know" cannot fire — then found nothing and the question
      // repeated. "Yes" matched first time, every time, which is exactly how
      // it was reported: takes yes, will not take no.
      expect(crowded('Know.'), isFalse);
      expect(crowded('know'), isFalse);
    });

    test('"know" inside a sentence is left alone', () {
      // "I know" and "you know" are ordinary speech, not refusals. Only a
      // bare one-word utterance is treated as a misheard "no".
      expect(crowded('i know they do'), isNot(false));
      expect(crowded('you know how it is'), isNot(false));
    });

    test('a genuinely unclear answer still returns null rather than guessing', () {
      // Re-prompting is correct here. Guessing commits an accessibility
      // setting the user did not choose.
      expect(crowded('a little bit'), isNull);
    });
  });

  // Item 33 — a tester answered the mobility question `আমি একাই হাঁটি` ("I walk
  // alone") and it was not accepted.
  //
  // The phrase does score against the label, but only by accident: on the one
  // word `হাঁটি` it happens to share with it. Nothing in the vocabulary knew
  // the word for *alone*, so the entire answer rested on that single verb, and
  // every ordinary variation of it fell off a cliff.
  group('the mobility question understands "alone"', () {
    final bn = Onboarding.of(AppLanguage.bangla);

    OnboardingVoiceChoice choiceFor(Onboarding s, String label, List<String> synonyms) =>
        OnboardingVoiceChoice(label: label, synonyms: synonyms, onSelect: () {});

    /// Which of the three mobility options an utterance actually lands on —
    /// best score wins, exactly as `listenForVoiceChoice` does it.
    String? pick(Onboarding s, String heard) {
      final choices = {
        'whiteCane': choiceFor(s, s.mobilityWhiteCaneLabel, s.mobilityWhiteCaneSynonyms),
        'wheelchair': choiceFor(s, s.mobilityWheelchairLabel, s.mobilityWheelchairSynonyms),
        'unassisted': choiceFor(s, s.mobilityUnassistedLabel, s.mobilityUnassistedSynonyms),
      };
      String? best;
      var bestScore = 0.0;
      choices.forEach((key, choice) {
        final score = choice.matchScore(heard);
        if (score > bestScore) {
          bestScore = score;
          best = key;
        }
      });
      return best;
    }

    test('the exact phrase the tester used', () {
      expect(pick(bn, 'আমি একাই হাঁটি'), 'unassisted');
    });

    test('and the same answer said any other way', () {
      // `হাটি` without its chandrabindu is how the verb is commonly
      // transcribed; `চলি` ("I get about") is as natural as `হাঁটি` here; and
      // a bare `আমি একা` is a complete answer to the question asked.
      for (final heard in [
        'আমি একাই হাটি',
        'একা হাঁটি',
        'একা হাটি',
        'আমি একা চলি',
        'একাই চলি',
        'আমি একা',
        'নিজেই হাঁটি',
      ]) {
        expect(pick(bn, heard), 'unassisted', reason: '"$heard" is the same answer');
      }
    });

    test('in English too', () {
      for (final heard in ['i walk alone', 'alone', 'by myself', 'walk on my own']) {
        expect(pick(en, heard), 'unassisted', reason: '"$heard" is the same answer');
      }
    });

    test('without stealing answers that name an aid', () {
      // The risk of a one-word synonym: `একা` must not outrank a sentence
      // that actually says which aid is used.
      expect(pick(bn, 'আমি ছড়ি নিয়ে হাঁটি'), 'whiteCane',
          reason: 'walking *with a cane* is not walking unassisted');
      expect(pick(bn, 'সাদা ছড়ি'), 'whiteCane');
      expect(pick(bn, 'আমি হুইলচেয়ার ব্যবহার করি'), 'wheelchair');
      expect(pick(en, 'i use a white cane'), 'whiteCane');
      expect(pick(en, 'wheelchair'), 'wheelchair');
    });
  });
}
