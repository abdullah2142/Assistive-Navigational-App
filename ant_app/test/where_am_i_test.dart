// "Where am I" — open_bugs item 48.
//
// Reported: "even though location is on, it says it cannot tell me where i am
// when asked".
//
// The triage blamed the map never getting a location fix, on the strength of
// seven `myLocation=null` lines in the tester logs. The rest of those logs say
// otherwise: 529 fixes against those 7 nulls, and every null inside the first
// four seconds of a session — which is just the wait for a first fix, and
// exactly what a cold start looks like. The position was there.
//
// What was not there was any way to say it. The assistant's function list had
// fourteen entries and not one of them reported where the user was, so a model
// asked "where am I" answered from the only thing it had, which was its own
// inability to know. The map was never involved.
//
// The second half is the fix a device has and a test bench does not: every
// chat message is handed `getLastKnownPosition()`, a cached fix that is null
// on a phone that has not had one since it rebooted and stale on one that has
// been in a pocket. Naming the wrong road to somebody who cannot look up and
// check it is worse than saying nothing, so this path asks for a real fix
// when the cached one will not do.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('the question reaches a function at all', () {
    test('the model is given something to call', () {
      // The whole of item 48. Without this declaration there is no answer the
      // model can give except that it cannot know.
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name);
      expect(names, contains('describe_current_location'));
    });

    for (final phrase in [
      'where am i',
      'Where am I?',
      'what road is this',
      'which area is this',
      'tell me where i am',
    ]) {
      test('"$phrase" is matched locally, without a round trip', () {
        // Asked standing still in the street and disoriented. A 1.5-to-29
        // second wait for Gemini is the wrong answer to this question.
        final intent = LocalIntentMatcher.match(phrase, AppLanguage.english);
        expect(intent?.name, 'describe_current_location');
      });
    }

    for (final phrase in ['kothay achi', 'ami kothay achi', 'আমি কোথায় আছি', 'কোন রাস্তায় আছি']) {
      test('"$phrase" is matched too — item 54', () {
        // Romanised Bangla is how this is actually said in Dhaka, and it was
        // in neither vocabulary.
        final intent = LocalIntentMatcher.match(phrase, AppLanguage.bangla);
        expect(intent?.name, 'describe_current_location');
      });
    }

    test('being lost and frightened is still an emergency, not a map query', () {
      // `_distressContext` has carried "where am i" since item 43 precisely
      // because a blind user who does not know where they are is the case
      // this app exists for. Answering that with a street name would be a
      // regression dressed as a feature.
      final intent = LocalIntentMatcher.match(
          'help me i am lost i dont know where i am', AppLanguage.english);
      expect(intent?.name, 'trigger_emergency');
    });

    test('asking to go somewhere is still a route', () {
      final intent = LocalIntentMatcher.match('take me to Gulshan 2', AppLanguage.english);
      expect(intent?.name, 'request_route');
    });
  });

  group('answering it', () {
    test('says the road and the area, not coordinates', () async {
      // Coordinates are not an answer to anyone, and least of all to someone
      // who cannot see a map to put them on.
      final turn = await _executor().execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(5),
      );
      expect(turn.responseText, contains('Road 7, Dhanmondi'));
      expect(turn.responseText, isNot(contains('23.7')));
    });

    test('a recent cached fix is used as it is', () async {
      // Spinning up the GPS for a question the phone can already answer costs
      // battery and seconds, on a path where someone is standing waiting.
      var freshCalls = 0;
      final turn = await _executor(onFresh: () {
        freshCalls++;
        return _fixAgedSeconds(0);
      }).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(5),
      );
      expect(freshCalls, 0);
      expect(turn.responseText, contains('Road 7'));
    });

    test('no cached fix asks for a real one rather than giving up', () async {
      // This is the device behaviour the bench does not have.
      // `getLastKnownPosition()` returns null on a phone that has not had a
      // fix since it was last restarted, and every chat message is handed
      // that. Without this, the fix for item 48 would reproduce item 48.
      var freshCalls = 0;
      final turn = await _executor(onFresh: () {
        freshCalls++;
        return _fixAgedSeconds(0);
      }).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: null,
      );
      expect(freshCalls, 1);
      expect(turn.responseText, contains('Road 7, Dhanmondi'));
    });

    test('a stale cached fix is refused', () async {
      // A walking user covers about 1.4 metres a second. Ten minutes is most
      // of a neighbourhood, and confidently naming the wrong road to somebody
      // who cannot check it is worse than admitting we do not know.
      var freshCalls = 0;
      await _executor(onFresh: () {
        freshCalls++;
        return _fixAgedSeconds(0);
      }).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(600),
      );
      expect(freshCalls, 1);
    });

    test('with no fix anywhere, it says to check location — the actionable thing', () async {
      final turn = await _executor(onFresh: () => null).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: null,
      );
      expect(turn.responseText, contains('location access'));
    });

    test('a fix with no name says so, and does not pretend it is lost', () async {
      // "I know where you are but cannot name this spot" and "I have no idea
      // where you are" are different things to be told, and only one of them
      // sends someone into their settings.
      final turn = await _executor(place: null).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(5),
      );
      expect(turn.responseText, contains("couldn't find a name"));
      expect(turn.responseText, isNot(contains('location access')));
    });

    test('a geocoder that never answers does not leave the user in silence', () async {
      // Bounded like every other network call on a path someone is waiting on.
      final turn = await _executor(place: null, hangs: true).execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(5),
      );
      expect(turn.responseText, isNotEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('nothing about the profile is changed by asking', () async {
      final turn = await _executor().execute(
        name: 'describe_current_location',
        args: const {},
        profile: _profile,
        location: _fixAgedSeconds(5),
      );
      expect(turn.updatedProfile, isNull);
      expect(turn.route, isNull);
      expect(turn.overlayAction, isNull);
    });

    test('it answers in Bangla for a Bangla profile', () async {
      final turn = await _executor().execute(
        name: 'describe_current_location',
        args: const {},
        profile: UserProfile(
          uid: 'u1',
          role: UserRole.disabledUser,
          language: AppLanguage.bangla,
        ),
        location: _fixAgedSeconds(5),
      );
      expect(turn.responseText, contains('কাছে আছেন'));
    });
  });
}

final _profile = UserProfile(uid: 'u1', role: UserRole.disabledUser);

FunctionCallExecutor _executor({
  String? place = 'Road 7, Dhanmondi',
  bool hangs = false,
  Position? Function()? onFresh,
}) =>
    FunctionCallExecutor(
      routePlanning: _StubPlanning(place: place, hangs: hangs),
      freshLocation: () async => onFresh?.call(),
    );

class _StubPlanning implements RoutePlanningService {
  _StubPlanning({required this.place, this.hangs = false});

  final String? place;
  final bool hangs;

  @override
  Future<String?> describeLocation(LatLng location) async {
    // A geocoder that never answers — the failure a `.timeout` exists for,
    // and one a fake returning a plain value can never reproduce.
    if (hangs) return Completer<String?>().future;
    return place;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Position _fixAgedSeconds(int seconds) => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.now().subtract(Duration(seconds: seconds)),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
