// Commands matched against what the recognizer *returned*, not what was said.
//
// Measured, and the reason this exists: "report a hazard" came back from Cloud
// STT as "People of the hazard" on a real device. A matcher built on exact
// substrings had nothing to offer that, so the command took the 1.5-to-29
// second round trip to Gemini — which has no better chance with it than the
// matcher did — when the local path costs 17ms.
//
// This pass runs last, only once every exact matcher has declined. It trades
// precision for recall, so it must never pre-empt one that is certain.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/voice_matching.dart';

void main() {
  String? intentOf(String text, [AppLanguage language = AppLanguage.english]) =>
      LocalIntentMatcher.match(text, language)?.name;

  group('boundedEditDistance', () {
    test('counts the edits it should', () {
      expect(boundedEditDistance('hazard', 'hazard'), 0);
      expect(boundedEditDistance('hazard', 'hazad'), 1);
      expect(boundedEditDistance('screen', 'scren'), 1);
    });

    test('gives up rather than counting past the limit', () {
      // A command matcher runs this on every utterance; it must not do the
      // full matrix to discover two words are unrelated.
      expect(boundedEditDistance('hazard', 'elephant', limit: 1), greaterThan(1));
      expect(boundedEditDistance('a', 'zzzzzzzz', limit: 1), greaterThan(1));
    });
  });

  group('containsNearWord', () {
    test('a short word must match exactly', () {
      // At three letters an edit is a different word, not a mis-hearing.
      expect(containsNearWord(['cap'], 'cab'), isFalse);
      expect(containsNearWord(['off'], 'of'), isFalse);
    });

    test('a longer word tolerates a slip', () {
      expect(containsNearWord(['hazad'], 'hazard'), isTrue);
      expect(containsNearWord(['scren'], 'screen'), isTrue);
    });

    test('and still refuses an unrelated one', () {
      expect(containsNearWord(['weather'], 'screen'), isFalse);
      expect(containsNearWord(['hospital'], 'hazard'), isFalse);
    });
  });

  group('a mis-transcribed command still reaches its intent', () {
    for (final heard in [
      'People of the hazard.', // what the device actually returned
      'report a hazad',
      'reporter hazard',
    ]) {
      test('"$heard" opens the hazard report', () {
        expect(intentOf(heard), 'open_hazard_report');
      });
    }

    for (final heard in ['show me screen', 'shou my screen', 'show my scren']) {
      test('"$heard" opens the passer-by helper', () {
        expect(intentOf(heard), 'open_passerby_helper');
      });
    }
  });

  group('and a coincidence does not', () {
    test('a sentence that merely contains the word is not a command', () {
      // Somebody describing their day. Length is what separates it from a
      // request once exactness has been given up.
      expect(intentOf('the pavement here is a real hazard for me every morning'), isNull);
    });

    test('asking about a command is not the command', () {
      // This one was a live bug of its own: `_matchOverlay` was the single
      // matcher in the file with no question guard, so asking what the feature
      // did put the user inside it.
      expect(intentOf('what happens if i report a hazard'), isNull);
      expect(intentOf('how do i report a hazard'), isNull);
      expect(intentOf('what does show my screen do'), isNull);
    });

    test('one loose word is not enough on its own', () {
      // "show" without "screen" is how a passer-by helper opens on the
      // brightness setting.
      expect(intentOf('turn up the screen brightness'), isNot('open_passerby_helper'));
      expect(intentOf('show me the weather'), isNot('open_passerby_helper'));
    });

    test('the exact matchers still win, and are untouched', () {
      expect(intentOf('take me to Gulshan'), 'request_route');
      expect(intentOf('cancel the trip'), 'cancel_route');
      expect(intentOf('help me'), 'trigger_emergency');
      expect(intentOf('report a hazard'), 'open_hazard_report');
    });
  });

  group('Bangla is matched exactly, not fuzzily', () {
    test('the real phrases still work', () {
      expect(intentOf('বিপদ জানাও', AppLanguage.bangla), 'open_hazard_report');
      expect(intentOf('স্ক্রিন দেখাও', AppLanguage.bangla), 'open_passerby_helper');
    });

    test('a single word carries the hazard report', () {
      expect(intentOf('বিপদ', AppLanguage.bangla), 'open_hazard_report');
    });

    // An edit-distance rule tuned on Latin letters does not transfer to a
    // script where one code point is a vowel sign — a "near miss" there would
    // be a command the user never gave. So Bangla gets recall from its own
    // phrase lists, and nothing is invented for it here.
  });
}
