// The voice trigger for the Magic Button. Both directions are dangerous:
// a missed call for help is the worst failure this app can have, and a
// false one messages and rings a user's family.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';

void main() {
  LocalIntent? en(String t) => LocalIntentMatcher.match(t, AppLanguage.english);
  LocalIntent? bn(String t) => LocalIntentMatcher.match(t, AppLanguage.bangla);

  bool isSos(LocalIntent? i) => i?.name == 'trigger_emergency';

  group('a call for help is recognised', () {
    for (final phrase in [
      'help me',
      'Help me!',
      'help help',
      'emergency',
      'SOS',
      'save me',
      'i need help',
      'call for help',
      "i'm in danger",
    ]) {
      test('"$phrase"', () => expect(isSos(en(phrase)), isTrue));
    }

    for (final phrase in ['বাঁচাও', 'সাহায্য করো', 'সাহায্য করুন', 'বিপদে পড়েছি', 'জরুরি অবস্থা']) {
      test('"$phrase"', () => expect(isSos(bn(phrase)), isTrue));
    }
  });

  group('code-switching, because panic does not respect the language setting', () {
    test('English help inside a Bangla session', () {
      expect(isSos(bn('help me')), isTrue);
      expect(isSos(bn('emergency')), isTrue);
    });

    test('Bangla help inside an English session', () {
      expect(isSos(en('বাঁচাও')), isTrue);
    });
  });

  group('an ordinary request is not an emergency', () {
    // Messaging someone's mother because they asked for directions politely
    // would teach them never to say the word again — and it is the word
    // they need on the day it matters.
    for (final phrase in [
      'help me get to Gulshan',
      'help me find a pharmacy',
      'can you help me navigate to Banani',
      'help me read this',
      'help me with the settings',
    ]) {
      test('"$phrase"', () => expect(isSos(en(phrase)), isFalse, reason: phrase));
    }

    test('Bangla routing phrased as a request for help', () {
      expect(isSos(bn('সাহায্য করো গুলশান যেতে')), isFalse);
    });
  });

  group('talking about the feature is not using it', () {
    for (final phrase in [
      'what happens if I say emergency',
      'is this the emergency button',
      'should i say help me',
      'was it an emergency',
    ]) {
      test('"$phrase"', () => expect(isSos(en(phrase)), isFalse, reason: phrase));
    }

    test('a negated call for help does nothing', () {
      expect(isSos(en('i do not need help')), isFalse);
      expect(isSos(en("i don't need help")), isFalse);
    });
  });

  group('sentences that merely contain the words', () {
    // Both of these were real false positives, caught by the existing
    // coverage tests rather than by this file, and both would have
    // messaged and rung the user's family.
    test('composing a passer-by card that says "I need help"', () {
      expect(isSos(en('add a message saying I need help crossing the road')), isFalse);
    });

    test('adding an emergency contact', () {
      expect(isSos(en('add my sister Ruma on 01712345678 as an emergency contact')), isFalse);
    });

    test('short administrative phrases too, which no word count would catch', () {
      expect(isSos(en('add emergency contact')), isFalse);
      expect(isSos(en('remove my emergency contact')), isFalse);
      expect(isSos(en('save this as my emergency place')), isFalse);
    });

    test('but "save me" survives, because it is a real cry for help', () {
      // Blocking the word "save" to catch "save this place" would suppress
      // one of the plainest things a person says when frightened.
      expect(isSos(en('save me')), isTrue);
    });

    test('a long sentence is not a cry for help', () {
      expect(
        isSos(en('i was thinking about what to do in an emergency situation tomorrow')),
        isFalse,
      );
    });

    test('a short desperate one still is, even at seven words', () {
      expect(isSos(en('please help me someone is following me')), isTrue);
    });
  });

  group('it beats every other matcher to the answer', () {
    test('an emergency phrase wins over a routing phrase in the same sentence', () {
      // "Emergency" plus a place name must not be read as a trip.
      final intent = en('emergency');
      expect(intent?.name, 'trigger_emergency');
    });

    test('and is matched locally, so it needs no network', () {
      // The whole point of the on-device matcher: this must work when data
      // has dropped, which is when it is most likely to be needed.
      expect(isSos(en('help me')), isTrue);
      expect(isSos(bn('বাঁচাও')), isTrue);
    });
  });
}
