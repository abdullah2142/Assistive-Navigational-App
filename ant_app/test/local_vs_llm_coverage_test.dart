// How much of what users actually say is handled locally?
//
// Every command that falls through to Gemini costs a network round trip
// (seconds, on Dhaka mobile data) and tokens. Every command handled here
// costs neither and works offline. This file is the measurement: a corpus
// of realistic phrasings, asserted to resolve locally — and, just as
// importantly, a corpus of things that MUST still reach the model, because
// a local matcher that grabs those would be guessing at content it cannot
// read.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';

void main() {
  LocalIntent? en(String t) => LocalIntentMatcher.match(t, AppLanguage.english);
  LocalIntent? bn(String t) => LocalIntentMatcher.match(t, AppLanguage.bangla);

  /// Routine commands: high frequency, unambiguous, no free-text content to
  /// extract. These are exactly the ones a language model adds latency to
  /// without adding judgement.
  const routine = <String, String>{
    // Routing — by far the most common thing this app is asked to do.
    'take me to Gulshan': 'request_route',
    'i wanna go to Mirpur': 'request_route',
    "let's go to New Market": 'request_route',
    'how do i get to Dhanmondi': 'request_route',
    'take me home': 'request_route',
    'go to work': 'request_route',
    'directions to the hospital': 'request_route',
    // Appearance / accessibility settings.
    'switch to dark mode': 'update_setting',
    'make the screen darker': 'update_setting',
    'turn on light mode': 'update_setting',
    'make the text bigger': 'update_setting',
    'increase the font size': 'update_setting',
    'smaller text please': 'update_setting',
    'keep your answers short': 'update_setting',
    'give me more detail when you talk': 'update_setting',
    'speak in bangla': 'update_setting',
    'switch to english': 'update_setting',
    'turn on hey ant': 'update_setting',
    'disable the wake word': 'update_setting',
    'enable auto listen': 'update_setting',
    // Overlays and hazards.
    'show my screen': 'open_passerby_helper',
    'show them my screen': 'open_passerby_helper',
    'report a hazard': 'open_hazard_report',
    'report an open manhole': 'open_hazard_report',
    'flag a broken ramp': 'open_hazard_report',
    'report a mugging': 'open_hazard_report',
    "it's fixed": 'resolve_hazard',
    'the ramp is fixed now': 'resolve_hazard',
  };

  const routineBn = <String, String>{
    'গুলশানে যেতে চাই': 'request_route',
    'নারায়ণগঞ্জে যাব': 'request_route',
    'ডার্ক মোড করো': 'update_setting',
    'লেখা বড় করো': 'update_setting',
    'সংক্ষেপে বলো': 'update_setting',
    'স্ক্রিন দেখাও': 'open_passerby_helper',
    'ম্যানহোল খোলা আছে বলে জানাও': 'open_hazard_report',
    'ঠিক হয়ে গেছে': 'resolve_hazard',
  };

  group('routine commands never reach the language model', () {
    routine.forEach((said, expected) {
      test('"$said"', () {
        final intent = en(said);
        expect(intent, isNotNull,
            reason: '"$said" fell through to Gemini — a network round trip for something unambiguous');
        expect(intent!.name, expected);
      });
    });

    routineBn.forEach((said, expected) {
      test('Bangla: "$said"', () {
        final intent = bn(said);
        expect(intent, isNotNull, reason: '"$said" fell through to Gemini');
        expect(intent!.name, expected);
      });
    });

    test('local coverage of the routine corpus is complete', () {
      final missed = [
        ...routine.keys.where((k) => en(k) == null),
        ...routineBn.keys.where((k) => bn(k) == null),
      ];
      expect(missed, isEmpty, reason: 'these still cost a round trip: $missed');
    });
  });

  group('genuinely hard requests still go to the language model', () {
    // Not a gap — a deliberate boundary. Each of these needs free-text
    // content pulled out of an arbitrary sentence, or real comprehension.
    // A local guess here silently corrupts real contact/message data or
    // answers a question it did not understand.
    const mustDefer = [
      'add my sister Ruma on 01712345678 as an emergency contact',
      'remove the message about needing a seat',
      'add a message saying I need help crossing the road',
      'what is the safest way to get to my office in the evening',
      'is it going to rain before I get there',
      'my nephew is picking me up, tell him where I am',
      'I am feeling anxious, can you talk to me',
    ];

    for (final said in mustDefer) {
      test('"$said" defers', () {
        expect(en(said), isNull, reason: 'local matching guessed at something it cannot actually read');
      });
    }
  });

  group('ordinary conversation never triggers an action', () {
    const innocent = [
      "it's getting dark outside",
      'the street light is broken near my house',
      'i know that road',
      'is there a pothole near me',
      'what does dark mode do',
      'should i go to Gulshan tonight',
      'my phone screen is cracked',
      'thanks, that was helpful',
    ];

    for (final said in innocent) {
      test('"$said" does nothing', () {
        final intent = en(said);
        expect(intent, isNull, reason: 'fired ${intent?.name} on an ordinary sentence');
      });
    }
  });
}
