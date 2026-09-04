// Voice-answer matching for onboarding. These functions decide what goes
// into a user's accessibility profile from a single spoken utterance, so
// a wrong match is a wrong profile — and the profile drives everything
// downstream (theme, narration, routing weights).

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';

void main() {
  final en = Onboarding.of(AppLanguage.english);
  final bn = Onboarding.of(AppLanguage.bangla);

  bool? deafEn(String heard) => classifyTraitYesNo(
        heard,
        presentPhrases: en.deafPresentPhrases,
        absentPhrases: en.deafAbsentPhrases,
      );
  bool? deafBn(String heard) => classifyTraitYesNo(
        heard,
        presentPhrases: bn.deafPresentPhrases,
        absentPhrases: bn.deafAbsentPhrases,
      );

  group('classifyTraitYesNo — clear answers', () {
    test('English', () {
      expect(deafEn('yes'), isTrue);
      expect(deafEn('no'), isFalse);
      expect(deafEn("I can't hear"), isTrue);
      expect(deafEn('I hear fine'), isFalse);
      // The live bug this function exists to fix.
      expect(deafEn('I can hear my assistant'), isFalse);
    });

    test('Bangla', () {
      expect(deafBn('হ্যাঁ'), isTrue);
      expect(deafBn('না'), isFalse);
      expect(deafBn('কানে শুনি না'), isTrue);
      expect(deafBn('ভালো শুনি'), isFalse);
    });

    test('nothing recognizable returns null rather than guessing', () {
      expect(deafEn(''), isNull);
      expect(deafEn('what time is it'), isNull);
    });
  });

  group('classifyTraitYesNo — bare yes/no must match whole words', () {
    // Same family as the already-fixed "male" inside "female": a bare
    // `contains` check finds "no" inside "know", "not", "another"…
    test('"know" is not "no"', () {
      expect(
        deafEn('I know I do'),
        isNot(isFalse),
        reason: '"know" contains "no", so an affirmative answer registered as a refusal',
      );
    });

    test('"another" is not "no"', () {
      expect(deafEn('another one'), isNull);
    });

    test('"yesterday" is not "yes"', () {
      expect(deafEn('yesterday'), isNull);
    });

    test('punctuation around a real yes/no is still understood', () {
      expect(deafEn('No.'), isFalse);
      expect(deafEn('Yes!'), isTrue);
      expect(deafBn('না।'), isFalse);
    });
  });

  group('fuzzyVoiceMatch', () {
    test('exact and near-miss matches', () {
      expect(fuzzyVoiceMatch('no vision', 'No vision'), isTrue);
      expect(fuzzyVoiceMatch('no visions', 'No vision'), isTrue);
    });

    test('"male" does not match "female"', () {
      expect(fuzzyVoiceMatch('male voice', 'Bangla — Female voice'), isFalse);
      expect(fuzzyVoiceMatch('female voice', 'Bangla — Female voice'), isTrue);
    });
  });
}
