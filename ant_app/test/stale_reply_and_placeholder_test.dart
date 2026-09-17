// Three bugs from the 16 Sep device session, all of them code rather than
// prompt — which is why they are worth fixing before the model question is
// settled. A prompt fix is tuned to one model's behaviour; these are not.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('a placeholder is not a destination', () {
    // Confirmed live: "ঘুরতে যাব" ("I want to go out") produced
    // `request_route` with destination "অন্য জায়গা" — literally "another
    // place" — and the app started routing. The user asked where on earth it
    // was taking them.
    //
    // A model asked to fill a required argument will fill it. If it has
    // nothing to fill it with it invents a placeholder rather than declining,
    // so the guard belongs where the argument is *consumed*.
    for (final placeholder in [
      'অন্য জায়গা',
      'another place',
      'somewhere',
      'anywhere else',
      'কোথাও',
      'destination',
      '   ',
    ]) {
      test('"$placeholder" names nowhere', () {
        expect(DestinationClarifier.isPlaceholder(placeholder), isTrue);
      });
    }

    for (final real in ['Gulshan 2', 'Ibn Sina Hospital', 'nearest toilet', 'ধানমন্ডি লেক']) {
      test('"$real" is a real destination', () {
        expect(DestinationClarifier.isPlaceholder(real), isFalse);
      });
    }

    test('the executor refuses to route to one', () async {
      // It reaches no geocoder and plans nothing — the reply asks where they
      // meant, which is the question the model should have asked itself.
      final executor = FunctionCallExecutor(routePlanning: _NoPlanning());
      final turn = await executor.execute(
        name: 'request_route',
        args: const {'destination': 'অন্য জায়গা'},
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        location: _here(),
      );
      expect(turn.route, isNull, reason: 'nothing should have been planned');
      expect(turn.responseText, isNotEmpty);
    });

    test('a real destination still gets past the guard', () async {
      // The guard must not be so wide that it refuses ordinary requests. The
      // two paths produce different replies, so comparing them shows "Gulshan
      // 2" was not treated as a placeholder.
      Future<String> replyFor(String destination) async {
        final turn = await FunctionCallExecutor(routePlanning: _NoPlanning()).execute(
          name: 'request_route',
          args: {'destination': destination},
          profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
          location: _here(),
        );
        return turn.responseText;
      }

      expect(await replyFor('Gulshan 2'), isNot(await replyFor('অন্য জায়গা')));
    });
  });

  group('Plus Codes are not an answer', () {
    // "আপনি P9V4+452, Dhaka 1209 এর কাছে আছেন" — four times in one session.
    // A Plus Code is a grid reference. Reading one to somebody who cannot see
    // a map is the failure `describeLocation` exists to avoid.
    test('a code with an area after it keeps the area', () {
      expect(RoutingService.debugStripPlusCode('P9V4+452, Dhaka 1209'), 'Dhaka 1209');
      expect(RoutingService.debugStripPlusCode('7MQ2+3X Dhaka'), 'Dhaka');
    });

    test('a real address is untouched', () {
      for (final address in [
        'Road 7, Dhanmondi, Dhaka',
        'Ibn Sina Hospital, Dhanmondi',
        '12 Green Road',
      ]) {
        expect(RoutingService.debugIsPlusCode(address), isFalse, reason: address);
      }
    });

    test('a code is recognised', () {
      expect(RoutingService.debugIsPlusCode('P9V4+452, Dhaka 1209'), isTrue);
      expect(RoutingService.debugIsPlusCode('7MQ2+3X Dhaka'), isTrue);
    });
  });
}

class _NoPlanning implements RoutePlanningService {
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
