import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reported failure: the assistant "keyword matched" instead of holding a
/// conversation.
///
/// Two distinct causes, both covered here.
void main() {
  LocalIntent? match(String text, [AppLanguage language = AppLanguage.english]) =>
      LocalIntentMatcher.match(text, language);

  group('rejecting a destination is not a new destination', () {
    // Live report: "take me to work" resolved to the wrong saved place, and
    // every attempt to say so matched as another route request and produced
    // the same answer. In a voice-only app that is an inescapable loop.
    test('"this is not my workplace" is not a route request', () {
      expect(match('this is not my workplace')?.name, isNot('request_route'));
    });

    test('"can you take me somewhere else" is not a route request', () {
      expect(match('can you take me somewhere else')?.name, isNot('request_route'));
    });

    test('"that is the wrong place" is not a route request', () {
      expect(match('that is the wrong place')?.name, isNot('request_route'));
    });

    test('"I don\'t want to go there" is not a route request', () {
      expect(match("i don't want to go there")?.name, isNot('request_route'));
    });

    test('Bangla refusals are covered too', () {
      expect(match('অন্য কোথাও নিয়ে চলো', AppLanguage.bangla)?.name, isNot('request_route'));
    });
  });

  group('genuine route requests still match', () {
    // The refusal list must not swallow the ordinary case — that would be a
    // worse bug than the one it fixes, and a silent one.
    test('"take me to work"', () {
      final intent = match('take me to work');
      expect(intent?.name, 'request_route');
      expect(intent?.args['destination'], 'work');
    });

    test('"go to Dhanmondi"', () {
      expect(match('go to dhanmondi')?.name, 'request_route');
    });

    test('"take me home"', () {
      expect(match('take me home')?.name, 'request_route');
    });

    test('a place whose name contains a refusal word still routes', () {
      // "not" appears inside plenty of ordinary text; the refusal phrases are
      // multi-word for exactly this reason.
      expect(match('take me to notun bazar')?.name, 'request_route');
    });
  });

  group('the emergency trigger is never suppressed', () {
    // Whatever else is true of the conversation, this one has to fire.
    test('a strong emergency phrase still matches', () {
      expect(match('emergency')?.name, 'trigger_emergency');
    });

    test('a distress sentence still matches', () {
      expect(match("help me i can't breathe")?.name, 'trigger_emergency');
    });
  });
}
