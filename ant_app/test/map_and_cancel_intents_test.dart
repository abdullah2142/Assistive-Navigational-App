// Asking for the map, and cancelling a trip through the model — item 51.
//
// Reported: "map on koro doesnt open the map, in fact map does not auto open
// or auto close when route is asked to be cancelled"; "after saying cancel
// trip, ai thinks trip is cancelled, but map still renders previous route".
//
// One report, two independent failures, and the second only reachable through
// the first.
//
// **The map could not be asked for at all.** It opened itself when a route was
// planned and closed when one was cleared, and between those two moments the
// only control was a button on the chat input row — no use to somebody who
// cannot see it, and no intent existed in any language.
//
// **And `cancel_route` was declared to Gemini and handled nowhere.** The
// executor had no case for it, so a model-issued cancellation fell through to
// `default` and came back as 'unknown function' while the route stayed on the
// map. Only the *local* match path ever cancelled anything. That is why this
// had five passing tests and still failed on a device: the tester said "trip
// cancel koro", which the local matcher did not speak (item 54), so it went to
// Gemini — and Gemini's answer was dropped on the floor.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  final profile = UserProfile(uid: 'u1', role: UserRole.disabledUser);
  FunctionCallExecutor executor() => FunctionCallExecutor(routePlanning: _NoPlanning());

  group('cancelling through the model', () {
    test('the executor knows what cancel_route means', () async {
      // The whole of the second failure. This returned
      // {'ok': false, 'error': 'unknown function'} and the map kept the route.
      final turn = await executor().execute(
        name: 'cancel_route',
        args: const {},
        profile: profile,
      );
      expect(turn.cancelsRoute, isTrue);
    });

    test('and says nothing itself, because it cannot know what to say', () async {
      // Whether there was a journey to cancel is chat state. The caller owns
      // the only implementation that can tell "cancelled" from "nothing to
      // cancel", and a confirmation here would pre-empt it.
      final turn = await executor().execute(
        name: 'cancel_route',
        args: const {},
        profile: profile,
      );
      expect(turn.responseText, isEmpty);
    });

    test('it is not confused with an emergency', () async {
      final turn = await executor().execute(
        name: 'cancel_route',
        args: const {},
        profile: profile,
      );
      expect(turn.triggersEmergency, isFalse);
      expect(turn.updatedProfile, isNull);
    });

    test('the model is still told the function exists', () {
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name);
      expect(names, contains('cancel_route'));
    });
  });

  group('the Banglish that sent it down the broken path', () {
    for (final phrase in ['trip cancel koro', 'cancel koro', 'trip bondho koro']) {
      test('"$phrase" cancels locally now — item 54', () {
        // Matched locally, so it never has to reach Gemini at all.
        expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name, 'cancel_route');
      });
    }

    test('the English phrasings still work', () {
      for (final phrase in ['cancel the trip', 'stop navigation', 'cancel my trip']) {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'cancel_route',
            reason: phrase);
      }
    });
  });

  group('asking for the map', () {
    for (final phrase in ['show the map', 'open the map', 'map on koro', 'ম্যাপ দেখাও']) {
      test('"$phrase" opens it', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name, 'open_map');
      });
    }

    for (final phrase in ['hide the map', 'close the map', 'map off koro', 'ম্যাপ বন্ধ করো']) {
      test('"$phrase" closes it', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name, 'close_map');
      });
    }

    test('closing the map is not cancelling the trip', () {
      // "map off koro" and "close the map" both carry words the cancel
      // vocabulary reaches for. Hiding a panel is not abandoning a journey,
      // and getting this backwards would strand somebody mid-route.
      for (final phrase in ['close the map', 'map off koro', 'hide the map']) {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'close_map',
            reason: phrase);
      }
    });

    test('the executor hands the dashboard the right action', () async {
      final open = await executor().execute(name: 'open_map', args: const {}, profile: profile);
      expect(open.overlayAction, SuggestedChipAction.showMap);
      expect(open.responseText, isNotEmpty, reason: 'say so — the user cannot see it happen');

      final close = await executor().execute(name: 'close_map', args: const {}, profile: profile);
      expect(close.overlayAction, SuggestedChipAction.hideMap);
      expect(close.responseText, isNotEmpty);
    });

    test('both are declared to the model', () {
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name).toList();
      // `open_map`/`close_map` are merged into one `set_map` tool with a
      // `visible` argument — three tool declarations became one to claw back
      // input tokens against Groq's daily ceiling. The executor still
      // accepts the old names (the local matcher and the chips emit them),
      // so what matters is that the *capability* is declared, not the name.
      expect(names, contains('set_map'));
    });

    test('asking to go somewhere is still a route, not a map request', () {
      // "show me the way to Gulshan" has "show me" in it.
      expect(LocalIntentMatcher.match('take me to Gulshan 2', AppLanguage.english)?.name,
          'request_route');
    });
  });
}

class _NoPlanning implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
