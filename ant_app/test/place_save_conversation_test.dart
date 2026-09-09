// Saving a place is a conversation, not a single command.
//
// Reported twice from the device, as two symptoms of one failure — the
// answer to the assistant's own question was read as a *fresh command*:
//
//   "i say add a new place, it asks where and what to call it, i only say
//    hospital ... it then gives me list of places with hospital keyword"
//
//   "it asks me to tell the name of the place id like to add, i say it, and
//    it goes back to routing me straight to that place on the map"
//
// So the conversation could be entered but never finished, and it degraded
// silently into `request_route`.

import 'package:flutter_test/flutter_test.dart';

import 'package:geolocator/geolocator.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/pending_place_save.dart';

void main() {
  group('the pending save', () {
    test('asks for a name while it has none', () {
      expect(const PendingPlaceSave().nextQuestion, PlaceSaveQuestion.name);
    });

    test('stops asking once it has one', () {
      expect(const PendingPlaceSave().withLabel('the clinic').nextQuestion, isNull);
    });

    test('keeps the address it was already given', () {
      final pending = const PendingPlaceSave(address: '12 Green Road').withLabel('the clinic');
      expect(pending.address, '12 Green Road');
      expect(pending.label, 'the clinic');
    });

    test('gives up rather than interrogating somebody on a footpath', () {
      var pending = const PendingPlaceSave();
      for (var i = 0; i < PendingPlaceSave.maxAttempts; i++) {
        pending = pending.asked();
      }
      expect(pending.isExhausted, isTrue);
    });

    test('is not exhausted after a single question', () {
      expect(const PendingPlaceSave().asked().isExhausted, isFalse);
    });
  });

  group('cancelling', () {
    // Shared with the destination conversation so the two cannot drift —
    // a user who says "never mind" means it in both.
    for (final phrase in ['cancel', 'never mind', 'forget it', 'stop']) {
      test('"$phrase" stops the save', () {
        expect(DestinationClarifier.isCancellation(phrase), isTrue);
      });
    }

    test('a place name is not a cancellation', () {
      expect(DestinationClarifier.isCancellation('the clinic'), isFalse);
      expect(DestinationClarifier.isCancellation('Ma\'s house'), isFalse);
    });
  });

  test('the give-up message says what does work', () {
    // Being told "sorry, I failed" while standing on a footpath is worthless;
    // the way that always works is worth a sentence.
    final d = Dashboard.of(AppLanguage.english);
    expect(d.savedPlaceGaveUp, contains('save this place'));
    expect(d.savedPlaceNeedsName, contains('What should I call'));
  });

  test('rejecting the request-as-a-name opens the conversation', () async {
    // The refusal is only half a fix — without a pending save, the answer to
    // "what should I call it?" goes straight back to the destination matcher,
    // which is the reported failure.
    final executor = FunctionCallExecutor(routePlanning: _NoPlanning());

    final turn = await executor.execute(
      name: 'save_place',
      args: const {'label': 'a new place I go to frequently'},
      profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
      location: _here(),
    );

    expect(turn.updatedProfile, isNull);
    expect(turn.placeSave, isNotNull, reason: 'the next message is an answer, not a command');
    expect(turn.placeSave!.nextQuestion, PlaceSaveQuestion.name);
  });
}

/// `save_place` never touches routing; this exists only to keep the executor
/// off `FirebaseFunctions.instance`.
class _NoPlanning implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Position _here() => Position(
      latitude: 23.7461,
      longitude: 90.3742,
      timestamp: DateTime.utc(2026, 9, 10),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
