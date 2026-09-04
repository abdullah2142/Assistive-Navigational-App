// Every command in this app is spoken and every reply is heard, so which
// regional model the device picks is not cosmetic. On a real device both
// sides independently chose Australian English for users in Dhaka.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/locale_preference.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';

void main() {
  // Verbatim from the Redmi 10C, in the order it reported them.
  const deviceLocales = [
    'cmn_CN', 'cmn_TW', 'en_AU', 'en_CA', 'en_IN', 'en_IE', 'en_SG', 'en_GB',
    'en_US', 'fr_FR', 'de_DE', 'hi_IN', 'it_IT', 'ja_JP', 'ko_KR', 'ru_RU',
  ];

  // Verbatim shape of what flutter_tts returned on the same device.
  const deviceVoices = [
    {'name': 'en-AU-language', 'locale': 'en-AU'},
    {'name': 'en-GB-language', 'locale': 'en-GB'},
    {'name': 'en-IN-language', 'locale': 'en-IN'},
    {'name': 'en-US-language', 'locale': 'en-US'},
    {'name': 'bn-BD-language', 'locale': 'bn-BD'},
  ];

  group('recognition', () {
    test('prefers Indian English over whatever sorts first', () {
      expect(SttService.pickLocaleId(deviceLocales, AppLanguage.english), 'en_IN');
    });

    test('walks down the preference list', () {
      expect(SttService.pickLocaleId(['en_AU', 'en_CA', 'en_GB', 'en_US'], AppLanguage.english), 'en_GB');
      expect(SttService.pickLocaleId(['en_AU', 'en_CA', 'en_US'], AppLanguage.english), 'en_US');
    });

    test('takes any English when no preferred region exists', () {
      expect(SttService.pickLocaleId(['en_AU'], AppLanguage.english), 'en_AU');
    });

    test('returns the id verbatim, hyphens and all', () {
      expect(SttService.pickLocaleId(['en-AU', 'en-IN'], AppLanguage.english), 'en-IN');
    });

    test('no English pack at all means fall back to the system default', () {
      expect(SttService.pickLocaleId(['hi_IN', 'ja_JP'], AppLanguage.english), isNull);
    });

    test('Bangladeshi Bangla is preferred over Indian Bangla', () {
      expect(SttService.pickLocaleId(['bn_IN', 'bn_BD'], AppLanguage.bangla), 'bn_BD');
    });

    test('this device had no Bangla, so the caller asks for bn-BD directly', () {
      expect(SttService.pickLocaleId(deviceLocales, AppLanguage.bangla), isNull);
    });
  });

  group('speech output', () {
    test('does not speak to Dhaka in an Australian accent', () {
      expect(TtsService.pickVoice(deviceVoices, 'en-US')?['name'], 'en-IN-language');
    });

    test('picks Bangla when Bangla is asked for', () {
      expect(TtsService.pickVoice(deviceVoices, 'bn-BD')?['name'], 'bn-BD-language');
    });

    test('is stable when a locale has several voices', () {
      // getVoices has no documented ordering, and a voice that changes
      // between launches sounds broken to someone who only ever hears it.
      const many = [
        {'name': 'en-IN-x-cxx-network', 'locale': 'en-IN'},
        {'name': 'en-IN-language', 'locale': 'en-IN'},
        {'name': 'en-AU-language', 'locale': 'en-AU'},
      ];
      expect(TtsService.pickVoice(many, 'en-US')?['name'], 'en-IN-language');
      expect(
        TtsService.pickVoice(many.reversed.toList(), 'en-US')?['name'],
        'en-IN-language',
        reason: 'the choice must not depend on the order the engine listed them',
      );
    });

    test('no voice for the language leaves the engine default alone', () {
      expect(TtsService.pickVoice(const [{'name': 'ja', 'locale': 'ja-JP'}], 'en-US'), isNull);
    });
  });

  group('the two sides cannot drift apart', () {
    test('both read the same ordering', () {
      // The whole reason the ordering was extracted: this was one bug
      // written twice, and fixing only one half would have made the other
      // harder to find.
      final english = kRegionPreference['en']!;
      expect(english.first, 'in');
      expect(english.indexOf('gb'), lessThan(english.indexOf('us')));

      final sttChoice = SttService.pickLocaleId(deviceLocales, AppLanguage.english)!;
      final ttsChoice = TtsService.pickVoice(deviceVoices, 'en-US')!['locale']!;
      expect(regionOf(sttChoice), regionOf(ttsChoice),
          reason: 'listening and speaking must agree on the same variant');
    });
  });
}
