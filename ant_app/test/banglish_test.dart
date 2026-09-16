// Romanised Bangla — open_bugs item 54.
//
// Reported: "it cant handle a lot of banglish terms like 'trip cancel koro'".
//
// The first answer to that was to add literal Banglish phrases to each
// vocabulary as each intent was touched. An audit of nineteen realistic
// utterances against that approach matched ten, and the misses were not
// random — they were one grammatical rule and one whole missing vocabulary.
//
// **The rule.** Bangla makes a command by attaching a verb meaning "do it" to
// a content word: `cancel koro`, `lekha boro koro`, `sahajjo koro`. The
// auxiliary carries no intent — it is the Bangla equivalent of "please" —
// so stripping it lets `X koro` match whatever `X` already matched, for every
// vocabulary in the app at once, including ones written later that never
// think about Banglish. See `banglish.dart`.
//
// **The vocabulary.** The emergency words had no romanised forms at all,
// which is the one place in this file where a miss is not merely slow.
// Everything else falls through to Gemini and works a few seconds later;
// `bachao` fell through to nothing, and with no signal it still would have,
// because `OfflineIntentMatcher` had no romanised forms either.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/banglish.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/offline_intent_matcher.dart';

void main() {
  String? intentOf(String said) =>
      LocalIntentMatcher.match(said, AppLanguage.bangla)?.name;

  group('the "do it" auxiliary is not part of the command', () {
    test('it is stripped as a whole word', () {
      expect(stripBanglishImperatives('trip cancel koro'), 'trip cancel');
      expect(stripBanglishImperatives('lekha boro korun'), 'lekha boro');
    });

    test('never as a substring', () {
      // `kor` lives inside a great many ordinary words, and this codebase has
      // been bitten three times by substring matching — "no" in "know",
      // "male" in "female", "না" in নারায়ণগঞ্জ.
      expect(stripBanglishImperatives('korea te jabo'), 'korea te jabo');
      expect(stripBanglishImperatives('record koro'), 'record');
    });

    test('an utterance that is only an auxiliary is left alone', () {
      // "koro" on its own is half a command. Handing back an empty string
      // would have every matcher evaluate nothing.
      expect(stripBanglishImperatives('koro'), 'koro');
    });

    test('a sentence with no auxiliary is not touched', () {
      expect(hasBanglishImperative('hospital e jabo'), isFalse);
      expect(stripBanglishImperatives('hospital e jabo'), 'hospital e jabo');
    });
  });

  group('the rule pays off across vocabularies it never knew about', () {
    const cases = {
      'trip cancel koro': 'cancel_route',
      'map on koru': 'open_map',
      'map bondo koro': 'close_map',
      'dark mode koro': 'update_setting',
      'lekha boro koro': 'update_setting',
      'bipod report koro': 'open_hazard_report',
      'screen dekhao': 'open_passerby_helper',
      'caretaker ke janao': 'alert_caretaker',
      'voice message pathao': 'record_caretaker_voice_memo',
      'ami kothay achi': 'describe_current_location',
    };
    cases.forEach((said, want) {
      test('"$said" -> $want', () => expect(intentOf(said), want));
    });
  });

  group('routing, which had no Banglish at all', () {
    test('destination before the verb', () {
      // Bangla puts the verb last, so the English prefix regex ("take me
      // to X") cannot reach these no matter how many phrasings it lists.
      final intent = LocalIntentMatcher.match('hospital e jabo', AppLanguage.bangla);
      expect(intent?.name, 'request_route');
      expect(intent?.args['destination'], 'hospital');
    });

    test('the carry-me form', () {
      final intent =
          LocalIntentMatcher.match('amake Gulshan niye chalo', AppLanguage.bangla);
      expect(intent?.name, 'request_route');
      expect(intent?.args['destination'], 'gulshan');
    });

    test('it works with the app set to English too', () {
      // Banglish is Latin script, so it reaches the matcher from an English
      // recognizer session as readily as a Bangla one, and somebody with the
      // app in English still says "hospital e jabo".
      expect(LocalIntentMatcher.match('hospital e jabo', AppLanguage.english)?.name,
          'request_route');
    });

    test('"I am NOT going there" does not start a journey', () {
      // Bangla negates after the verb, so the refusal sits at the end and
      // "jabo na" is a literal prefix-match of "jabo".
      expect(intentOf('office e jabo na'), isNot('request_route'));
    });

    test('and does not cancel a live one either', () {
      // It did. "jabo na" was strong-listed in the cancel vocabulary, so
      // "office e jabo na" — a statement about a journey nobody started —
      // cancelled whatever route was running. Its English twin "i am not
      // going" has always been weak, and bounded by sentence length.
      expect(intentOf('office e jabo na'), isNull);
      expect(intentOf('jabo na'), 'cancel_route', reason: 'said bare, it is a cancellation');
    });
  });

  group('the emergency vocabulary, which is the part that mattered', () {
    for (final cry in [
      'bachao',
      'bachao amake',
      'bachaw',
      'sahajjo koro',
      'bipode porechi',
    ]) {
      test('"$cry" raises an SOS', () => expect(intentOf(cry), 'trigger_emergency'));
    }

    for (final refusal in ['sahajjo lagbe na', 'ami thik achi', 'bipod nei']) {
      test('"$refusal" does not', () {
        // Adding the cries without the refusals would mean "I don't need
        // help" newly firing an SOS — the one direction this vocabulary must
        // never move in.
        expect(intentOf(refusal), isNull);
      });
    }

    test('it also works with no connection at all', () {
      // The offline matcher is the last thing standing when there is no
      // signal, so a word missing there is missing with no Gemini behind it.
      expect(OfflineIntentMatcher.match('bachao', AppLanguage.bangla), isNotNull);
      expect(OfflineIntentMatcher.match('sahajjo', AppLanguage.bangla), isNotNull);
      expect(OfflineIntentMatcher.match('ami kothay achi', AppLanguage.bangla), isNotNull);
    });
  });

  group('and none of it fires on ordinary sentences', () {
    // The whole risk of loosening a matcher that triggers real actions.
    for (final said in [
      'what is the weather like',
      "it's getting dark outside",
      'the bus number was 123456',
      'korea te jabo na',
    ]) {
      test('"$said"', () => expect(intentOf(said), isNull));
    }

    test('an empty target list never matches everything', () {
      // It did, briefly, and every utterance in the app became a hazard
      // report: `[].every(...)` is vacuously true, so a recall-pass entry
      // with no Bangla spelling matched unconditionally. Caught by the
      // existing tests, but the trap was set for whoever added the next
      // entry rather than for the one that found it.
      expect(intentOf('hello there how are you'), isNull);
      expect(intentOf('tell me a joke'), isNull);
    });
  });
}
