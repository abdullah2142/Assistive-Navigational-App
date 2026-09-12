// "Dictate a name that is not a common English word (a relative's real name).
// Check what the read-back says." — Misspellings.
//
// The emergency-contact read-back already spoke the phone number one digit at
// a time, and testers confirmed that half works. The name had no equivalent,
// and a name is no harder for STT to mangle than a number is.
//
// The part that makes it a bug rather than a limitation: the misspelling could
// not be *caught*. The name was only ever pronounced, and "Rahima", "Rohima"
// and "Raheema" are the same sound. Someone who cannot see the screen was
// being asked to confirm something they had no way to check.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/features/onboarding/widgets/spoken_name.dart';

void main() {
  group('spelledOutName', () {
    test('an English name is spelled letter by letter', () {
      expect(spelledOutName('Rahima'), 'R a h i m a');
    });

    test('each word of a full name is spelled separately', () {
      // One unbroken twelve-letter run is not checkable either. The comma is
      // a beat every TTS engine honours.
      expect(spelledOutName('Rahima Khatun'), 'R a h i m a, K h a t u n');
    });

    test('a Bangla name is spelled by syllable, not by code unit', () {
      // This is the whole difficulty. `'রাহিমা'.split('')` gives `র া হ ি ম া` —
      // bare vowel signs, which mean nothing said aloud and are not how any
      // Bangla speaker spells a name. Grapheme clusters give the syllables.
      expect(spelledOutName('রাহিমা'), 'রা হি মা');
      expect('রাহিমা'.split('').join(' '), isNot('রা হি মা'),
          reason: 'the naive split is what this exists to avoid');
    });

    test('conjuncts are not torn apart', () {
      expect(spelledOutName('আব্দুল্লাহ'), 'আ ব্দু ল্লা হ');
      expect(spelledOutName('কৃষ্ণা'), 'কৃ ষ্ণা');
    });

    test('stray whitespace does not become empty letters', () {
      expect(spelledOutName('  Rahima   Khatun  '), 'R a h i m a, K h a t u n');
      expect(spelledOutName(''), '');
    });

    test('two names that sound alike spell differently', () {
      // The point of the whole change: by ear these are identical, and this
      // is what now distinguishes them.
      expect(spelledOutName('Rahima'), isNot(spelledOutName('Rohima')));
      expect(spelledOutName('Rahima'), isNot(spelledOutName('Raheema')));
    });
  });

  group('the read-back actually carries the spelling', () {
    for (final language in AppLanguage.values) {
      test('in ${language.name}', () {
        final s = Onboarding.of(language);
        final line = s.contactsConfirmSpoken('Rahima', spelledOutName('Rahima'), '0 1 7 1 1');

        expect(line, contains('Rahima'), reason: 'said, so it can be recognised');
        expect(line, contains('R a h i m a'), reason: 'and spelled, so it can be checked');
        expect(line, contains('0 1 7 1 1'), reason: 'the number is still spaced out');
      });
    }
  });
}
