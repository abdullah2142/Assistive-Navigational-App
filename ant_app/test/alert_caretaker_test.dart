// Asking for the caretaker — open_bugs item 57.
//
// Reported: "user asking to alert caretaker doesnt do anything yet."
//
// Exactly right, and the gap was on the sending side only. Module 8 built
// the caretaker's receiving half — the Alert Center watches
// `alerts/{uid}/items`, the Overwatch map watches `liveLocations/{uid}` —
// and the single thing that ever wrote to either was the Magic Button. So
// the app could raise an emergency and could not pass on a calm request to
// be checked on, which is the thing a user actually reaches for most.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('the request is recognised', () {
    test('the model has something to call', () {
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name);
      expect(names, contains('alert_caretaker'));
    });

    for (final phrase in [
      'alert my caretaker',
      'let my caretaker know',
      'tell my carer',
      'notify my guardian',
      'send my location to my caretaker',
    ]) {
      test('"$phrase" is matched locally', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name, 'alert_caretaker');
      });
    }

    for (final phrase in ['caretaker ke janao', 'দেখাশোনাকারীকে জানাও']) {
      test('"$phrase" is matched too — item 54', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name, 'alert_caretaker');
      });
    }

    test('an emergency that names a caretaker is still an emergency', () {
      // "Tell my caretaker I've fallen" must not be downgraded into a
      // notification because it contains the word "tell". Emergency is
      // matched first, and this is the test that keeps it that way.
      final intent = LocalIntentMatcher.match(
          'help me i have fallen tell my caretaker', AppLanguage.english);
      expect(intent?.name, 'trigger_emergency');
    });

    test('pairing is still pairing', () {
      // "Caretaker" on its own is most of what somebody says while pairing.
      final intent =
          LocalIntentMatcher.match('pair with my caretaker', AppLanguage.english);
      expect(intent?.name, isNot('alert_caretaker'));
    });
  });

  group('what the caretaker receives', () {
    test('an alert, marked as a request rather than an emergency', () async {
      // A caretaker who cannot tell the two apart learns to discount both.
      final alerts = _RecordingAlerts();
      await _executor(alerts).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: _here(),
      );
      expect(alerts.created, hasLength(1));
      expect(alerts.created.single.type, GuardianAlertType.userRequested);
      expect(alerts.created.single.type, isNot(GuardianAlertType.magicButton));
    });

    test('and where the user is, so the message is a whole one', () async {
      final alerts = _RecordingAlerts();
      await _executor(alerts).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: _here(),
      );
      expect(alerts.created.single.lat, 23.7461);
      expect(alerts.published, hasLength(1),
          reason: 'the Overwatch map needs somewhere to point when it opens');
    });

    test('the user is told it went', () async {
      final turn = await _executor(_RecordingAlerts()).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: _here(),
      );
      expect(turn.responseText, contains('caretaker know'));
    });

    test('with no location it still goes, rather than failing silently', () async {
      // Being told somebody wants you is worth having even without a map
      // reference. Withholding the whole alert for want of a fix would be
      // the wrong trade.
      final alerts = _RecordingAlerts();
      final turn = await _executor(alerts).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: null,
      );
      expect(alerts.created, hasLength(1));
      expect(alerts.created.single.lat, isNull);
      expect(turn.responseText, contains('caretaker know'));
    });
  });

  group('when there is nobody to tell', () {
    test('it says so, and says what to do about it', () async {
      // "Sorry, I couldn't do that" while standing in the street is worthless.
      final alerts = _RecordingAlerts();
      final turn = await _executor(alerts).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        location: _here(),
      );
      expect(alerts.created, isEmpty);
      expect(turn.responseText, contains('pair with my caretaker'));
    });

    test('a failed write points at the Magic Button', () async {
      // The one path that does not need the network to have worked.
      final turn = await _executor(_RecordingAlerts(succeed: false)).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: _here(),
      );
      expect(turn.responseText, contains('Magic Button'));
    });

    test('nothing about the profile changes either way', () async {
      final turn = await _executor(_RecordingAlerts()).execute(
        name: 'alert_caretaker',
        args: const {},
        profile: _paired,
        location: _here(),
      );
      expect(turn.updatedProfile, isNull);
      expect(turn.triggersEmergency, isFalse);
    });
  });
}

final _paired = UserProfile(
  uid: 'u1',
  role: UserRole.disabledUser,
  pairedUserId: 'caretaker-1',
);

FunctionCallExecutor _executor(AlertService alerts) =>
    FunctionCallExecutor(routePlanning: _NoPlanning(), alertService: alerts);

class _NoPlanning implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecordingAlerts implements AlertService {
  _RecordingAlerts({this.succeed = true});

  final bool succeed;
  final created = <({GuardianAlertType type, double? lat, double? lng})>[];
  final published = <String>[];

  @override
  Future<bool> createAlert({
    required String disabledUserUid,
    required GuardianAlertType type,
    double? lat,
    double? lng,
    int? batteryPercent,
    List<String> notifiedContacts = const [],
  }) async {
    if (!succeed) return false;
    created.add((type: type, lat: lat, lng: lng));
    return true;
  }

  @override
  Future<bool> publishLocation({
    required String disabledUserUid,
    required double lat,
    required double lng,
  }) async {
    published.add(disabledUserUid);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Position _here() => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
