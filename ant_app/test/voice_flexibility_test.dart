// The user's requirement, stated directly: voice commands must "support
// different sentence structures" rather than demanding "strict coherence".
//
// These are written as the *phrasings a person actually uses*, not as the
// phrasings the implementation happens to contain — that distinction is the
// whole point. Every case here is a sentence a real user could reasonably
// say for an entirely unambiguous request.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/saved_place_matcher.dart';
import 'package:ant_app/core/services/voice_matching.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/widgets/voice_confirm.dart';

void main() {
  LocalIntent? en(String t) => LocalIntentMatcher.match(t, AppLanguage.english);
  LocalIntent? bn(String t) => LocalIntentMatcher.match(t, AppLanguage.bangla);

  group('word matching never falls back to substrings', () {
    test('a term must be a whole word', () {
      expect(containsTerm(voiceWords('i know it'), 'no'), isFalse);
      expect(containsTerm(voiceWords('say no'), 'no'), isTrue);
      expect(containsTerm(voiceWords('female voice'), 'male'), isFalse);
      expect(containsTerm(voiceWords('নারায়ণগঞ্জে যাব'), 'না'), isFalse);
    });

    test('multi-word terms match as a contiguous run', () {
      expect(containsTerm(voiceWords('turn on hey ant please'), 'hey ant'), isTrue);
      expect(containsTerm(voiceWords('hey there ant'), 'hey ant'), isFalse);
    });

    test('punctuation and case do not matter', () {
      expect(containsTerm(voiceWords('Dark, please!'), 'dark'), isTrue);
      expect(containsTerm(voiceWords('হ্যাঁ।'), 'হ্যাঁ'), isTrue);
    });
  });

  group('routing accepts however the user phrases it', () {
    // Every one of these missed before, and cost a full language-model
    // round trip to understand something completely unambiguous.
    const phrasings = {
      'take me to Gulshan': 'Gulshan',
      'i wanna go to Gulshan': 'Gulshan',
      'I want to go to Gulshan': 'Gulshan',
      "let's go to Gulshan": 'Gulshan',
      'bring me to Gulshan': 'Gulshan',
      'how do i get to Gulshan': 'Gulshan',
      'directions to Gulshan': 'Gulshan',
      'navigate me to Gulshan': 'Gulshan',
      'i need to go to Gulshan': 'Gulshan',
      'the way to Gulshan': 'Gulshan',
      'head to Gulshan': 'Gulshan',
      'guide me to Gulshan': 'Gulshan',
    };

    phrasings.forEach((said, expected) {
      test('"$said"', () {
        final intent = en(said);
        expect(intent?.name, 'request_route', reason: '"$said" was not understood as a route request');
        expect(intent?.args['destination'], expected);
      });
    });

    test('trailing politeness is not part of the destination', () {
      expect(en('take me to Gulshan please')?.args['destination'], 'Gulshan');
      expect(en('take me to New Market, thanks!')?.args['destination'], 'New Market');
      expect(en('i wanna go to Uttara now')?.args['destination'], 'Uttara');
    });

    test('multi-word destinations survive intact', () {
      expect(en('take me to Gulshan 2 circle')?.args['destination'], 'Gulshan 2 circle');
      expect(en('navigate to the eye hospital in Mirpur')?.args['destination'],
          'the eye hospital in Mirpur');
    });

    test('a bare saved-place name is understood', () {
      expect(en('take me home')?.args['destination'], 'home');
      expect(en('take me back home')?.args['destination'], 'home');
      expect(en('go to work')?.args['destination'], 'work');
    });

    test('asking *about* a journey does not start one', () {
      // Starting to walk a blind user somewhere they were only wondering
      // about is a real failure, not a harmless over-trigger.
      expect(en('should i go to Gulshan tonight'), isNull);
      expect(en('how far is it to go to Uttara'), isNull);
      expect(en('is it safe to go to Mirpur at night'), isNull);
    });

    test('Bangla refusals still do not route, but real places do', () {
      expect(bn('আমি অফিসে যাব না'), isNull);
      expect(bn('নারায়ণগঞ্জে যেতে চাই')?.name, 'request_route');
    });
  });

  group('saved places', () {
    final places = [
      const SavedPlace(label: 'work', kind: SavedPlaceKind.work, lat: 23.79, lng: 90.40),
      const SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'Dhanmondi 27'),
      const SavedPlace(label: 'school', kind: SavedPlaceKind.school, lat: 23.73, lng: 90.39),
    ];

    test('resolves the exact label', () {
      expect(SavedPlaceMatcher.resolve('take me to work', places)?.label, 'work');
      expect(SavedPlaceMatcher.resolve('school', places)?.label, 'school');
    });

    test('resolves a synonym the user did not use as the label', () {
      // Someone who saved "work" says "office" weeks later. Being told
      // "I don't know where that is" about a place you saved yourself is a
      // particularly bad failure.
      expect(SavedPlaceMatcher.resolve('take me to the office', places)?.label, 'work');
      expect(SavedPlaceMatcher.resolve('i need to get to my job', places)?.label, 'work');
      expect(SavedPlaceMatcher.resolve('go to college', places)?.label, 'school');
    });

    test('resolves a shortened label', () {
      expect(SavedPlaceMatcher.resolve("take me to ma's", places)?.label, "Ma's house");
    });

    test('an exact label beats a category synonym', () {
      final ambiguous = [
        const SavedPlace(label: 'school', kind: SavedPlaceKind.school),
        const SavedPlace(label: 'the university', kind: SavedPlaceKind.school),
      ];
      expect(SavedPlaceMatcher.resolve('take me to school', ambiguous)?.label, 'school');
    });

    test('a genuinely ambiguous reference is refused, not guessed', () {
      // Walking someone to the wrong relative's house is a failure they
      // may not notice until they arrive.
      final houses = [
        const SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family),
        const SavedPlace(label: "Bhai's house", kind: SavedPlaceKind.family),
      ];
      expect(SavedPlaceMatcher.resolve('take me to my relative', houses), isNull);
      expect(SavedPlaceMatcher.candidates('take me to my relative', houses), hasLength(2));
    });

    test('an unknown place resolves to nothing rather than the nearest guess', () {
      expect(SavedPlaceMatcher.resolve('take me to the airport', places), isNull);
    });

    test('Bangla synonyms work', () {
      final bnPlaces = [const SavedPlace(label: 'অফিস', kind: SavedPlaceKind.work)];
      expect(SavedPlaceMatcher.resolve('অফিসে নিয়ে চলো', bnPlaces)?.label, 'অফিস');
      expect(SavedPlaceMatcher.resolve('কাজে যাব', bnPlaces)?.label, 'অফিস');
    });

    test('a place with neither address nor coordinates is not routable', () {
      expect(const SavedPlace(label: 'somewhere').isRoutable, isFalse);
      expect(const SavedPlace(label: 'x', address: 'Road 5').isRoutable, isTrue);
      expect(const SavedPlace(label: 'x', lat: 23.8, lng: 90.4).isRoutable, isTrue);
    });
  });

  group('read-back for confirmation', () {
    test('digits are spaced and grouped so they can be checked by ear', () {
      // "01712345678" read as one number is unverifiable, which defeats
      // the entire purpose of reading it back.
      final spoken = spokenDigitsForReadback('01712345678');
      expect(spoken, isNot(contains('01712345678')));
      expect(spoken.replaceAll(RegExp(r'[^0-9]'), ''), '01712345678');
      expect(spoken, contains(' '), reason: 'digits must be separated');
    });

    test('grouping survives odd lengths', () {
      expect(spokenDigitsForReadback('12').replaceAll(RegExp(r'[^0-9]'), ''), '12');
      expect(spokenDigitsForReadback('1234').replaceAll(RegExp(r'[^0-9]'), ''), '1234');
      expect(spokenDigitsForReadback(''), '');
    });
  });

  group('settings commands tolerate rephrasing', () {
    test('theme', () {
      for (final said in [
        'switch to dark mode',
        'dark mode please',
        'make the screen darker',
        "i'd like the theme dark",
        'turn on dark mode',
      ]) {
        expect(en(said)?.args['value'], 'dark', reason: '"$said" was not understood');
      }
    });

    test('an incidental mention still does not flip a setting', () {
      expect(en("it's getting dark outside"), isNull);
      expect(en('the street light is broken'), isNot(predicate(
        (i) => i is LocalIntent && i.args['setting'] == 'theme',
      )));
    });
  });
}
