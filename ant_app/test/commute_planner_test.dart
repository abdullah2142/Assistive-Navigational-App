import 'package:ant_app/core/services/commute_planner.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backlog: jam-based ETA, and transport suggestion. They turn out to be one
/// feature — the option and its cost are the same question — and neither is
/// answerable from walking distance, which is what every estimate used to be.
void main() {
  const planner = CommutePlanner();

  List<CommuteMode> modesFor(double m, {int? driving, DateTime? at}) => planner
      .optionsFor(distanceMeters: m, drivingMinutes: driving, at: at)
      .map((o) => o.mode)
      .toList();

  group('which options are worth offering', () {
    test('a short hop is walking only', () {
      // Hailing a rickshaw, agreeing a fare and getting in costs minutes on
      // its own — for 300m it is slower than walking as well as dearer.
      expect(modesFor(300), [CommuteMode.walk]);
    });

    test('a middling trip offers both', () {
      final modes = modesFor(2000);
      expect(modes, contains(CommuteMode.walk));
      expect(modes, contains(CommuteMode.rickshaw));
      expect(modes, contains(CommuteMode.cng));
    });

    test('a long trip drops walking', () {
      // Not a comfort judgement: 6km through Dhaka traffic on a cane is not
      // an option a planner should put on the list.
      expect(modesFor(6000), isNot(contains(CommuteMode.walk)));
      expect(modesFor(6000), contains(CommuteMode.bus));
    });
  });

  group('the numbers', () {
    test('are ordered fastest first', () {
      // The question behind this is "when do I leave", and the fastest
      // option is what answers it.
      final options = planner.optionsFor(distanceMeters: 5000, drivingMinutes: 20);
      for (var i = 1; i < options.length; i++) {
        expect(options[i].minutes, greaterThanOrEqualTo(options[i - 1].minutes));
      }
    });

    test('a bus is slower than a CNG over the same traffic', () {
      final options = planner.optionsFor(distanceMeters: 5000, drivingMinutes: 20);
      final cng = options.firstWhere((o) => o.mode == CommuteMode.cng);
      final bus = options.firstWhere((o) => o.mode == CommuteMode.bus);
      expect(bus.minutes, greaterThan(cng.minutes));
    });

    test('live traffic is marked as such, an average is not', () {
      // The hedge is not politeness. A user told "twenty minutes" who
      // arrives in forty has a reason to stop trusting every other number
      // this app gives them.
      final live = planner.optionsFor(distanceMeters: 5000, drivingMinutes: 20);
      expect(live.firstWhere((o) => o.mode == CommuteMode.cng).isTrafficAware, isTrue);

      final guessed = planner.optionsFor(distanceMeters: 5000);
      expect(guessed.firstWhere((o) => o.mode == CommuteMode.cng).isTrafficAware, isFalse);
    });

    test('walking is always exact, because traffic does not slow it', () {
      final options = planner.optionsFor(distanceMeters: 2000);
      expect(options.firstWhere((o) => o.mode == CommuteMode.walk).isTrafficAware, isTrue);
    });

    test('a rickshaw is not slowed by a jam that stops a car', () {
      // It filters, and on a bad evening it genuinely beats one — which is
      // the whole reason it is worth suggesting.
      final evening = planner.optionsFor(
        distanceMeters: 4000,
        at: DateTime(2026, 9, 23, 18),
      );
      final morning = planner.optionsFor(
        distanceMeters: 4000,
        at: DateTime(2026, 9, 23, 2),
      );
      final eveningRickshaw = evening.firstWhere((o) => o.mode == CommuteMode.rickshaw);
      final morningRickshaw = morning.firstWhere((o) => o.mode == CommuteMode.rickshaw);
      expect(eveningRickshaw.minutes, morningRickshaw.minutes);
    });
  });

  group('time of day, when there is no live figure', () {
    test('the evening peak is slower than the small hours', () {
      final peak = planner.optionsFor(
        distanceMeters: 6000,
        at: DateTime(2026, 9, 23, 18),
      ).firstWhere((o) => o.mode == CommuteMode.cng);
      final quiet = planner.optionsFor(
        distanceMeters: 6000,
        at: DateTime(2026, 9, 23, 3),
      ).firstWhere((o) => o.mode == CommuteMode.cng);
      expect(peak.minutes, greaterThan(quiet.minutes));
    });

    test('a live figure overrides the time of day entirely', () {
      final a = planner.optionsFor(
        distanceMeters: 6000,
        drivingMinutes: 15,
        at: DateTime(2026, 9, 23, 18),
      ).firstWhere((o) => o.mode == CommuteMode.cng);
      final b = planner.optionsFor(
        distanceMeters: 6000,
        drivingMinutes: 15,
        at: DateTime(2026, 9, 23, 3),
      ).firstWhere((o) => o.mode == CommuteMode.cng);
      expect(a.minutes, b.minutes);
    });
  });

  test('no option is ever zero minutes', () {
    // A rounded-down estimate that says "0 minutes" reads as broken.
    for (final m in [50.0, 700.0, 1500.0, 20000.0]) {
      for (final o in planner.optionsFor(distanceMeters: m)) {
        expect(o.minutes, greaterThan(0), reason: '$m m, ${o.mode}');
      }
    }
  });
}
