// Cancelling a trip has to actually cancel it.
//
// Reported: "Cancel the trip to Dhaka" was answered with "Cancelled your trip
// to Dhaka" — while the route stayed active and the map kept drawing it.
// There was no `cancel_route` intent at all, so it fell through to Gemini,
// which described a state change it had no way to make. That is the worst of
// the three possible outcomes: the user is told the thing happened.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';

void main() {
  group('recognised without a language model', () {
    for (final phrase in [
      'cancel the trip',
      'cancel my trip',
      'stop the trip',
      'stop navigation',
      'end the trip',
      "i'm not going",
    ]) {
      test('"$phrase"', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'cancel_route');
      });
    }

    test('Bangla', () {
      expect(LocalIntentMatcher.match('ট্রিপ বাতিল', AppLanguage.bangla)?.name, 'cancel_route');
      expect(LocalIntentMatcher.match('আর যাব না', AppLanguage.bangla)?.name, 'cancel_route');
    });

    test('the reported phrasing, with the destination named', () {
      // "Cancel the trip to Dhaka" — the exact sentence that got an invented
      // answer. The destination in it must not send this to the route matcher.
      expect(
        LocalIntentMatcher.match('cancel the trip to Dhaka', AppLanguage.english)?.name,
        'cancel_route',
      );
    });
  });

  group('not confused with its neighbours', () {
    test('asking for a different route is not cancelling', () {
      expect(
        LocalIntentMatcher.match('give me a different route', AppLanguage.english)?.name,
        'request_alternative_route',
      );
    });

    test('re-routing is not cancelling', () {
      expect(LocalIntentMatcher.match('re-route', AppLanguage.english)?.name, 'replan_route');
    });

    test('asking to go somewhere is still a route request', () {
      expect(
        LocalIntentMatcher.match('take me to Gulshan', AppLanguage.english)?.name,
        'request_route',
      );
    });

    test('cancelling a dictation is not cancelling a trip', () {
      // A bare "cancel" belongs to whatever conversation is open, not to the
      // route — the dictation and destination flows both use it.
      expect(LocalIntentMatcher.match('cancel', AppLanguage.english)?.name, isNot('cancel_route'));
    });
  });

  test('the replies say what happened, in both languages', () {
    for (final language in AppLanguage.values) {
      final d = Dashboard.of(language);
      expect(d.routeCancelled, isNotEmpty);
      expect(d.routeNothingToCancel, isNotEmpty);
      expect(d.routeCancelled, isNot(d.routeNothingToCancel));
    }
    expect(Dashboard.of(AppLanguage.bangla).routeCancelled, matches(RegExp(r'[ঀ-৿]')));
  });
}
