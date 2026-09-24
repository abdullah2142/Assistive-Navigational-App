// `LocalIntentMatcher` runs *before* Gemini and executes what it matches
// directly, with no language model in the loop to sanity-check it. A wrong
// match here silently changes a real accessibility setting, so its failure
// modes matter more than its coverage.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';

void main() {
  LocalIntent? matchEn(String text) =>
      LocalIntentMatcher.match(text, AppLanguage.english);
  LocalIntent? matchBn(String text) =>
      LocalIntentMatcher.match(text, AppLanguage.bangla);

  group('happy paths still work', () {
    test('theme', () {
      expect(matchEn('switch to dark mode')?.args['value'], 'dark');
      expect(matchBn('ডার্ক মোড করো')?.args['value'], 'dark');
    });
    test('overlays', () {
      expect(matchEn('show my screen')?.name, 'open_passerby_helper');
      expect(matchBn('স্ক্রিন দেখাও')?.name, 'open_passerby_helper');
      expect(matchEn('report a hazard')?.name, 'open_hazard_report');
    });
    test('routing', () {
      expect(matchEn('take me to Gulshan')?.args['destination'], 'Gulshan');
      expect(matchBn('গুলশানে যেতে চাই')?.args['destination'], 'গুলশানে');
    });
    test('pairing needs both a code and a pairing word', () {
      expect(matchEn('my pairing code is 123456')?.args['code'], '123456');
      expect(matchEn('the bus number was 123456'), isNull);
    });
    test('unrelated chat is left for Gemini', () {
      expect(matchEn('what is the weather like')?.name, 'current_weather');
      expect(matchEn("it's getting dark outside"), isNull);
    });
  });

  group('direct actions from the diagnostic sessions', () {
    test('weather phrases use the live local handler', () {
      for (final phrase in [
        "what's weather like",
        'what is the weather today',
        'what is the temperature outside',
        'is it raining',
      ]) {
        expect(matchEn(phrase)?.name, 'current_weather', reason: phrase);
      }
    });

    test(
      'camera opens locally and scene questions choose one-frame or sweep',
      () {
        expect(matchEn('open camera')?.name, 'open_camera');
        expect(matchEn("what's in front of me")?.args['focus'], 'ahead');
        expect(matchEn('what is around me')?.args['focus'], 'surroundings');
      },
    );

    test('urgent toilet and food needs become nearby category routes', () {
      for (final phrase in ['I need to poop', 'need to use the bathroom']) {
        expect(
          matchEn(phrase)?.args['destination'],
          'nearest toilet',
          reason: phrase,
        );
      }
      for (final phrase in [
        'I need to eat',
        'I need to eat something',
        "I'm hungry",
      ]) {
        expect(
          matchEn(phrase)?.args['destination'],
          'nearest restaurant',
          reason: phrase,
        );
      }
    });

    test('cancellation variants also close the map when asked', () {
      expect(matchEn('cancel that trip')?.name, 'cancel_route');
      expect(matchEn('cancel and close')?.name, 'cancel_route_and_close_map');
      expect(
        matchEn('cancel that trip and close the map')?.name,
        'cancel_route_and_close_map',
      );
    });
  });

  group('negation must not invert a setting', () {
    test('Bangla: "I cannot hear" must not turn deaf/text mode OFF', () {
      // "আমি শুনতে পাই না" = "I cannot hear". The "hearing is fine" phrase
      // list contains "শুনতে পাই", which is a literal prefix of it.
      final intent = matchBn('আমি শুনতে পাই না');
      expect(
        intent?.args['value'],
        isNot('false'),
        reason:
            'a Deaf user saying they cannot hear had text mode switched OFF',
      );
    });

    test('Bangla: "crowds do not bother me" must not turn anxiety ON', () {
      final intent = matchBn('ভিড়ে আমার অস্বস্তি লাগে না');
      expect(
        intent?.args['value'],
        isNot('true'),
        reason: 'the negated sentence matched the affirmative phrase list',
      );
    });

    test('English: negated hearing statement does not flip the setting', () {
      expect(matchEn("i can't hear well")?.args['value'], 'true');
    });
  });

  group('Bangla routing negation guard', () {
    test('a genuine refusal is not routed', () {
      expect(matchBn('আমি অফিসে যাব না'), isNull);
      expect(matchBn('গুলশানে যেতে চাই না'), isNull);
    });

    test('a destination whose NAME contains "না" is still routed', () {
      // Narayanganj, Nakhalpara, Narinda — all real places next to/inside
      // Dhaka whose names contain the same two characters as the Bangla
      // negation particle.
      expect(
        matchBn('নারায়ণগঞ্জে যেতে চাই')?.args['destination'],
        'নারায়ণগঞ্জে',
        reason: 'routing to Narayanganj was silently swallowed as a negation',
      );
      expect(matchBn('নাখালপাড়ায় যাব')?.name, 'request_route');
      expect(matchBn('নারিন্দায় যেতে চাই')?.name, 'request_route');
    });
  });

  group(
    'a message naming both options is handed to Gemini, not guessed at',
    () {
      // Local pattern matching has no way to tell which of two mentioned
      // modes is the one being asked for. It used to answer "whichever list
      // I check first", which picked `dark` for a sentence asking to leave
      // dark mode. Returning null falls through to Gemini — the documented
      // contract for anything this matcher isn't confident about — so the
      // user still gets the right result, just not from a coin flip.
      test('theme', () {
        expect(matchEn('switch from dark mode to light mode'), isNull);
        expect(matchEn('switch to light mode')?.args['value'], 'light');
      });
      test('text size', () {
        expect(
          matchEn('should i make the text bigger or make the text smaller'),
          isNull,
        );
        expect(matchEn('make the text bigger')?.args['value'], '_bigger');
      });
      test('language', () {
        expect(matchEn('do you speak bangla or speak english'), isNull);
        expect(matchEn('speak in bangla')?.args['value'], 'bangla');
      });
      test('a boolean setting stated both ways', () {
        expect(matchEn("i am deaf, well actually i can hear fine"), isNull);
      });
    },
  );
}
