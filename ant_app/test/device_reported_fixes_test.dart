// Fixes for bugs reported from a real Redmi 10C session. Each test names
// the symptom the user actually saw, because that is the thing that must
// not come back.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/saved_place_matcher.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';

void main() {
  LocalIntent? bn(String t, {String? recent}) =>
      LocalIntentMatcher.match(t, AppLanguage.bangla, recentSetting: recent);
  LocalIntent? en(String t, {String? recent}) =>
      LocalIntentMatcher.match(t, AppLanguage.english, recentSetting: recent);

  group('"saying i want to go to gulshan — it doesn\'t know where"', () {
    test('Bangla word order no longer drags the pronoun into the destination', () {
      // From the device log: `destination: আমি গুলশান`. Nominatim returns []
      // for that and resolves "গুলশান" instantly — so the user was told the
      // app didn't know a place the geocoder knows perfectly well.
      expect(bn('আমি গুলশান যেতে চাই')?.args['destination'], 'গুলশান');
      expect(bn('আমি অফিসে যাব')?.args['destination'], 'অফিসে');
      expect(bn('আমরা ধানমন্ডি যাব')?.args['destination'], 'ধানমন্ডি');
    });

    test('a destination that is already clean is left alone', () {
      expect(bn('গুলশানে যেতে চাই')?.args['destination'], 'গুলশানে');
      expect(en('take me to Gulshan')?.args['destination'], 'Gulshan');
    });

    test('the stripped Bangla destination still resolves a saved place', () {
      final places = [const SavedPlace(label: 'অফিস', kind: SavedPlaceKind.work, lat: 1, lng: 1)];
      final destination = bn('আমি অফিসে যাব')!.args['destination'] as String;
      expect(SavedPlaceMatcher.resolve(destination, places)?.label, 'অফিস');
    });

    test('a place name that begins with a filler word is not eaten', () {
      // "Islamabad" starts with "i"; stripping requires a following space.
      expect(en('take me to Islamabad')?.args['destination'], 'Islamabad');
    });
  });

  group('"say make text bigger, then even bigger — not recognized"', () {
    test('a bare comparative works as a follow-up to the same setting', () {
      expect(en('make the text bigger')?.args['value'], '_bigger');
      expect(en('even bigger', recent: 'text_size')?.args['value'], '_bigger');
      expect(en('bigger', recent: 'text_size')?.args['value'], '_bigger');
      expect(en('smaller', recent: 'text_size')?.args['value'], '_smaller');
      expect(bn('আরও বড়', recent: 'text_size')?.args['value'], '_bigger');
    });

    test('with nothing recently changed it stays unrecognized', () {
      // The context requirement is what stops ordinary sentences firing
      // settings; the relaxation must not become a general loophole.
      expect(en('even bigger'), isNull);
      expect(en('bigger'), isNull);
    });

    test('it only relaxes the setting that was actually just changed', () {
      expect(en('even bigger', recent: 'theme'), isNull);
      expect(en('shorter', recent: 'text_size'), isNull);
      expect(en('shorter', recent: 'verbosity')?.args['value'], 'minimalist');
    });

    test('a long sentence containing the word is not a follow-up', () {
      expect(en('bigger crowds make me anxious', recent: 'text_size'), isNull);
      expect(en('is it bigger now', recent: 'text_size'), isNull);
      expect(en('not bigger', recent: 'text_size'), isNull);
    });
  });

  group('the onboarding voice introduction', () {
    for (final language in AppLanguage.values) {
      test('${language.name}: explains voice control and the buzz convention', () {
        final s = Onboarding.of(language);
        final intro = s.voiceIntroSpoken;
        expect(intro.trim(), isNotEmpty);
        // The one convention everything else depends on — the mic opening
        // is otherwise invisible and inaudible.
        expect(
          intro.contains('buzz') || intro.contains('কম্পন'),
          isTrue,
          reason: 'must teach that a buzz means "your turn to speak"',
        );
        // Short enough to sit in front of the first question.
        expect(intro.length, lessThan(500));
      });
    }

    test('Bangla intro is actually Bangla', () {
      expect(Onboarding.of(AppLanguage.bangla).voiceIntroSpoken, matches(RegExp(r'[ঀ-৿]')));
    });
  });
  group('speech was being transcribed by an Australian English model', () {
    // The real list this device reported, in the order it reported it. The
    // old code took the first `en*` entry, so every English-speaking user
    // in Dhaka was recognised as Australian.
    const redmi10c = [
      'cmn_CN', 'cmn_TW', 'en_AU', 'en_CA', 'en_IN', 'en_IE', 'en_SG',
      'en_GB', 'en_US', 'fr_FR', 'hi_IN', 'ja_JP', 'ko_KR', 'ru_RU',
    ];

    test('prefers Indian English over whatever happens to sort first', () {
      expect(
        SttService.pickLocaleId(redmi10c, AppLanguage.english),
        'en_IN',
        reason: 'en_AU sorts first but is the worst acoustic match of the set',
      );
    });

    test('falls back down the preference list, not to alphabetical order', () {
      // No en_IN: British English is the next best for Bangladeshi speakers
      // and for the romanisation of Dhaka place names.
      expect(
        SttService.pickLocaleId(['en_AU', 'en_CA', 'en_GB', 'en_US'], AppLanguage.english),
        'en_GB',
      );
      expect(
        SttService.pickLocaleId(['en_AU', 'en_CA', 'en_US'], AppLanguage.english),
        'en_US',
      );
    });

    test('accepts hyphenated ids, which some OS versions report instead', () {
      expect(
        SttService.pickLocaleId(['en-AU', 'en-IN'], AppLanguage.english),
        'en-IN',
        reason: 'the id is returned verbatim so the plugin gets what it gave us',
      );
    });

    test('still takes any English at all when no preferred variant exists', () {
      expect(SttService.pickLocaleId(['en_AU'], AppLanguage.english), 'en_AU');
    });

    test('returns null when the device has no English pack', () {
      expect(SttService.pickLocaleId(['hi_IN', 'ja_JP'], AppLanguage.english), isNull);
    });

    test('Bangla is unaffected — any Bangla pack beats none', () {
      expect(SttService.pickLocaleId(['en_IN', 'bn_IN'], AppLanguage.bangla), 'bn_IN');
      // This device had no Bangla at all; the caller then asks for bn-BD
      // directly so the recognizer can try online recognition.
      expect(SttService.pickLocaleId(redmi10c, AppLanguage.bangla), isNull);
    });
  });
}
