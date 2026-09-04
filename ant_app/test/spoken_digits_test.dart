// Unit tests for dictated-number parsing (phone numbers, pairing codes).
//
// Covers the live-reported bug: "saying triple 3, 1 0 writes 333111000
// instead of 33310" — the "double"/"triple" multiplier leaking onto every
// digit of a token the recognizer merged into one ("310"), instead of
// applying only to the digit immediately after the multiplier word.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/onboarding/widgets/spoken_digits.dart';

void main() {
  group('double/triple multiplier', () {
    test('applies only to the first digit of a recognizer-merged token', () {
      // The exact live repro.
      expect(spokenTextToDigits('triple 3, 1 0'), '33310');
      expect(spokenTextToDigits('triple 310'), '33310');
      expect(spokenTextToDigits('double 310'), '3310');
    });

    test('works when the recognizer emits separate digit words', () {
      expect(spokenTextToDigits('triple three one zero'), '33310');
      expect(spokenTextToDigits('double three one zero'), '3310');
    });

    test('resets after each consumed token', () {
      expect(spokenTextToDigits('double one two double three four'), '11233 4'.replaceAll(' ', ''));
      expect(spokenTextToDigits('triple 7 8 9'), '77789');
    });

    test('"oh"/"o"/"nil" all read as zero', () {
      expect(spokenTextToDigits('double oh seven'), '007');
      expect(spokenTextToDigits('o one seven'), '017');
      expect(spokenTextToDigits('nil nil one'), '001');
    });

    test('Bangla multiplier words and digit words', () {
      expect(spokenTextToDigits('ট্রিপল তিন এক শূন্য'), '33310');
      expect(spokenTextToDigits('ডাবল তিন এক শূন্য'), '3310');
      expect(spokenTextToDigits('শূন্য এক সাত এক দুই'), '01712');
    });
  });

  group('general parsing', () {
    test('passes an already-numeric transcript straight through', () {
      expect(spokenTextToDigits('01712345678'), '01712345678');
      expect(spokenTextToDigits('017 1234 5678'), '01712345678');
    });

    test('strips punctuation and filler words without corrupting the number', () {
      expect(spokenTextToDigits('um, zero one seven... uh, one two'), '01712');
      expect(spokenTextToDigits('my number is 0171-234'), '0171234');
    });

    test('empty and junk input yield an empty string, not a crash', () {
      expect(spokenTextToDigits(''), '');
      expect(spokenTextToDigits('   '), '');
      expect(spokenTextToDigits('hello there'), '');
    });
  });

  group('Bangla (Bengali) numerals', () {
    // Google Cloud STT with a bn-BD language code returns Bengali numerals
    // (০-৯), not ASCII ones, when a Bangla speaker reads a number aloud.
    test('Bengali numeral characters are read as digits', () {
      expect(spokenTextToDigits('০১৭১২৩৪৫৬৭৮'), '01712345678');
      expect(spokenTextToDigits('০১৭ ১২৩৪ ৫৬৭৮'), '01712345678');
    });

    test('multipliers apply to Bengali numerals the same way', () {
      expect(spokenTextToDigits('ট্রিপল ৩ ১ ০'), '33310');
      expect(spokenTextToDigits('ট্রিপল ৩১০'), '33310');
    });

    test('mixed Bangla words and Bengali numerals', () {
      expect(spokenTextToDigits('শূন্য ১ ৭ এক ২'), '01712');
    });
  });
}
