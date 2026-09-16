// "The closest one" is an answer, not a question — open_bugs item 55.
//
// Reported: "a lot of times when asked to be taken to the closest, example:
// bathroom, it lists instead of routing to a closest option"; and more
// broadly, "the app shouldnt act like only a assistive map, but also a
// guardian that provides counsel or assistance for ambiguous requests".
//
// The clarification loop was doing exactly what it was built for: three
// bathrooms geocode to three distinct places, so it asked which. But the user
// had already answered that — *the closest* — and reading three options back
// to somebody who has just said they urgently need a toilet is the wrong thing
// to do with having understood them perfectly.
//
// The fix is narrow on purpose. Picking silently for a user who did **not**
// ask for the nearest is precisely the failure the clarification loop exists
// to prevent: walking a blind person to whichever candidate scored highest,
// with no way to notice it went wrong until they arrive somewhere else.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

String _prompt() => GeminiAssistantService.buildPrompt(
      userText: 'i need to poop where should i go',
      profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
    );

void main() {
  // Somewhere in Dhanmondi.
  const origin = LatLng(23.7461, 90.3742);

  GeocodeCandidate at(String label, double lat, double lng) =>
      GeocodeCandidate(label: label, location: LatLng(lat, lng));

  group('recognising the request', () {
    for (final query in [
      'nearest bathroom',
      'the closest toilet',
      'a pharmacy nearby',
      'somewhere close by to sit',
      'take me to the nearest hospital',
    ]) {
      test('"$query" asks for the nearest', () {
        expect(DestinationClarifier.wantsNearest(query), isTrue);
      });
    }

    for (final query in ['kachakachi bathroom', 'সবচেয়ে কাছের হাসপাতাল', 'কাছের টয়লেট']) {
      test('"$query" does too — item 54', () {
        expect(DestinationClarifier.wantsNearest(query), isTrue);
      });
    }

    for (final query in [
      'Ibn Sina Hospital',
      'Gulshan 2',
      'my office',
      'the hospital',
    ]) {
      test('"$query" does not — it still gets asked about', () {
        // The narrowness is the point. Without a "nearest", picking one of
        // several is the exact failure the clarification loop prevents.
        expect(DestinationClarifier.wantsNearest(query), isFalse);
      });
    }
  });

  group('picking it', () {
    test('the closest candidate wins, not the highest-scoring one', () {
      // Geocoders order by relevance, not distance. The first result is
      // routinely the furthest away.
      final chosen = DestinationClarifier.nearestTo(origin, [
        at('Toilet, Uttara', 23.8759, 90.3795), // ~14km
        at('Toilet, Dhanmondi 27', 23.7510, 90.3780), // ~600m
        at('Toilet, Motijheel', 23.7330, 90.4172), // ~4km
      ]);
      expect(chosen!.label, 'Toilet, Dhanmondi 27');
    });

    test('order of the list does not decide it', () {
      final candidates = [
        at('near', 23.7470, 90.3750),
        at('far', 23.8759, 90.3795),
      ];
      expect(DestinationClarifier.nearestTo(origin, candidates)!.label, 'near');
      expect(DestinationClarifier.nearestTo(origin, candidates.reversed.toList())!.label, 'near');
    });

    test('a single candidate is simply that one', () {
      expect(DestinationClarifier.nearestTo(origin, [at('only one', 23.9, 90.5)])!.label,
          'only one');
    });

    test('an empty list gives nothing, so the not-found path still runs', () {
      expect(DestinationClarifier.nearestTo(origin, const []), isNull);
    });

    test('distance is real, not a coordinate subtraction', () {
      // A degree of longitude in Dhaka is about 102km; a degree of latitude
      // about 111km. Treating them as equal would pick the wrong one.
      final metres = DestinationClarifier.metersBetweenPoints(
        const LatLng(23.7461, 90.3742),
        const LatLng(23.7551, 90.3742),
      );
      expect(metres, closeTo(1000, 50), reason: '0.009 degrees of latitude is about 1km');
    });
  });

  group('what the model is told', () {
    test('it is told to act on the need, not the words', () {
      // "I need to poop" is a request for a toilet, not a place called that.
      final prompt = _prompt();
      expect(prompt, contains('Act on the need, not the words'));
      expect(prompt, contains('nearest toilet'));
    });

    test('and that "nearest" is already an answer', () {
      final prompt = _prompt();
      expect(prompt, contains('is an answer, not a question'));
      expect(prompt, contains('Never read a list of options back'));
    });

    test('and to be a guardian rather than only a map', () {
      // Reported in those words: the app "shouldnt act like only a assistive
      // map, but also a guardian that provides counsel".
      final prompt = _prompt();
      expect(prompt, contains('guardian, not only a map'));
    });
  });
}
