// The command tour is the only place the app ever explains itself. If the
// examples here drift away from what the matcher accepts, we are teaching
// blind users phrases that don't work.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/saved_place_matcher.dart';
import 'package:ant_app/features/onboarding/models/onboarding_step.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';

void main() {
  test('the tour sits between saved places and the final lock-in', () {
    final order = OnboardingStep.values;
    expect(
      order.indexOf(OnboardingStep.commandTour),
      greaterThan(order.indexOf(OnboardingStep.frequentPlaces)),
    );
    expect(
      order.indexOf(OnboardingStep.commandTour),
      lessThan(order.indexOf(OnboardingStep.lockIn)),
      reason: 'it has to come before the settings UI disappears for good',
    );
  });

  for (final language in AppLanguage.values) {
    final s = Onboarding.of(language);

    group('$language tour', () {
      test('stays short enough to be remembered', () {
        final total = s.commandTourGroups.fold<int>(0, (n, g) => n + g.examples.length);
        expect(total, lessThanOrEqualTo(12),
            reason: 'this is an impression, not the full phrasebook');
        expect(s.commandTourGroups, isNotEmpty);
      });

      test('every group is headed and non-empty', () {
        for (final group in s.commandTourGroups) {
          expect(group.heading.trim(), isNotEmpty);
          expect(group.examples, isNotEmpty);
        }
      });

      test('tells the user the examples are not exact', () {
        expect(s.commandTourClosing.trim(), isNotEmpty);
        expect(s.commandTourClosing.length, greaterThan(40));
      });

      test('repeat and continue have distinct spoken answers', () {
        final repeat = s.commandTourRepeatSynonyms.map((w) => w.trim()).toSet();
        final go = s.commandTourContinueSynonyms.map((w) => w.trim()).toSet();
        expect(repeat.intersection(go), isEmpty,
            reason: 'an answer that means both leaves the user stuck on this screen');
        expect(repeat, isNotEmpty);
        expect(go, isNotEmpty);
      });
    });
  }

  test('Bangla examples are actually Bangla', () {
    final bn = Onboarding.of(AppLanguage.bangla);
    for (final group in bn.commandTourGroups) {
      for (final example in group.examples) {
        expect(RegExp(r'[ঀ-৿]').hasMatch(example), isTrue,
            reason: '"$example" is not in Bangla script');
      }
    }
  });

  group('the examples actually work', () {
    // The point of this test: a user is told to say these words, so these
    // words must be recognized locally. Anything here that fails is a
    // promise the app does not keep.
    final places = [
      const SavedPlace(kind: SavedPlaceKind.home, label: 'Home', address: 'Mirpur', lat: 23.8, lng: 90.36),
      const SavedPlace(kind: SavedPlaceKind.work, label: 'Office', address: 'Gulshan', lat: 23.79, lng: 90.41),
    ];

    bool recognized(String phrase, AppLanguage language) {
      final intent = LocalIntentMatcher.match(phrase, language);
      if (intent != null) return true;
      // "Take me home" / "বাসায় যাব" resolve through the saved-place layer.
      return SavedPlaceMatcher.candidates(phrase, places).isNotEmpty;
    }

    for (final language in AppLanguage.values) {
      final s = Onboarding.of(language);
      for (final group in s.commandTourGroups) {
        for (final example in group.examples) {
          test('[$language] "$example"', () {
            expect(recognized(example, language), isTrue,
                reason: 'the tour teaches "$example" but nothing matches it');
          });
        }
      }
    }
  });
}
