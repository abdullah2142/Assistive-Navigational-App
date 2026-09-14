// Telling the recognizer which proper nouns to expect.
//
// Reported directly: a user says a Dhaka location and Cloud STT returns
// something unrelated. That is the normal failure mode for rare proper nouns —
// a general model is weighted towards common vocabulary, and thana names are
// uncommon words that sound like ordinary ones. Google's `speechContexts`
// exists for exactly this, costs nothing per request, and this app never used
// it.
//
// Both scripts are always sent, whichever language the session is in: a bn-BD
// recognizer regularly returns a Bangla-script approximation of a Latin name
// and vice versa, the same reason the emergency vocabulary keeps হেল্প beside
// help.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/dhaka_places.dart';

void main() {
  group('the gazetteer', () {
    test('carries every thana in both scripts', () {
      // The same 41 Module 4 already scores for crime. A thana the router can
      // score is one a user can ask for.
      expect(dhakaThanas, hasLength(41));
      for (final thana in dhakaThanas) {
        expect(thana.en.trim(), isNotEmpty, reason: thana.bn);
        expect(thana.bn.trim(), isNotEmpty, reason: thana.en);
        expect(RegExp(r'[ঀ-৿]').hasMatch(thana.bn), isTrue,
            reason: '${thana.en} has no Bangla script');
      }
    });

    test('carries the places people actually say, not just administrative ones', () {
      // Almost nobody says "take me to Shahbagh Thana". They say a
      // neighbourhood, a market or a roundabout.
      final en = dhakaLandmarks.map((p) => p.en).toList();
      expect(en, contains('Farmgate'));
      expect(en, contains('Mirpur 10'));
      expect(en, contains('Karwan Bazar'));
    });

    test('offers both scripts of every name, deduplicated', () {
      final phrases = dhakaPlacePhrases;
      expect(phrases, contains('গুলশান'));
      expect(phrases, contains('Gulshan'));
      expect(phrases.toSet().length, phrases.length, reason: 'no duplicates');
    });

    test('puts landmarks before thanas', () {
      // A long context is treated as weaker, not stronger — everything being
      // likely is the same as nothing being likely. So the words people
      // actually say come first.
      final phrases = dhakaPlacePhrases;
      expect(phrases.indexOf('ফার্মগেট'), lessThan(phrases.indexOf('আদাবর')));
    });
  });

  group('the hints for a session', () {
    test("the user's own places come first of all", () {
      // What somebody calls their own home is a far stronger hint than any
      // gazetteer entry, and it is the name they will actually say.
      final hints = placeNameHints(
        savedPlaceLabels: const ["আম্মার বাসা", 'work'],
        homeAddress: 'Dhanmondi 27',
      );
      expect(hints.first, "আম্মার বাসা");
      expect(hints.indexOf('work'), lessThan(hints.indexOf('গুলশান')));
      expect(hints, contains('Dhanmondi 27'));
    });

    test('a profile with nothing saved still gets the whole city', () {
      expect(placeNameHints(), contains('মিরপুর ১০'));
    });

    test('empty and duplicate entries are dropped', () {
      // A saved place can be blank, and "Dhanmondi 27" may be both a saved
      // label and a landmark. A repeated phrase wastes the budget.
      final hints = placeNameHints(
        savedPlaceLabels: const ['', '   ', 'Gulshan', 'Gulshan'],
        homeAddress: '',
      );
      expect(hints.where((h) => h.trim().isEmpty), isEmpty);
      expect(hints.where((h) => h == 'Gulshan'), hasLength(1));
    });

    test('the list is capped', () {
      // Not free at the recognizer's end.
      expect(placeNameHints(limit: 10), hasLength(10));
      expect(placeNameHints().length, lessThanOrEqualTo(400));
    });

    test('a cap cannot push out the places the user saved themselves', () {
      final hints = placeNameHints(savedPlaceLabels: const ['school'], limit: 3);
      expect(hints.first, 'school');
      expect(hints, hasLength(3));
    });
  });
}
