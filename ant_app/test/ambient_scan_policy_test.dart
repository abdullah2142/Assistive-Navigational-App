// How often the app looks around on its own.
//
// This decides how often a camera opens on a blind user's phone for hours at
// a time — so it is arithmetic in a pure class, tested by feeding it a
// synthetic walk, rather than something you find out by carrying a handset
// around Dhaka. Same split `NavigationNarrator` has from
// `NavigationController`, for the same reason.
//
// The two failure directions, both real:
//   Scanning too often is a hot phone and a flat battery, for somebody who
//   cannot see the battery indicator and depends on the phone to get home.
//   Scanning too rarely means an open manhole nobody reported is still
//   invisible, which is the whole thing the ambient tier exists to catch.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/vision/ambient_scan_policy.dart';
import 'package:ant_app/core/services/vision/vision_detection.dart';

final _t0 = DateTime(2026, 9, 22, 9);

HazardVerdict _clear() => const HazardVerdict(level: HazardLevel.clear, detections: []);

HazardVerdict _sawSomething() => const HazardVerdict(
      level: HazardLevel.caution,
      detections: [
        VisionDetection(
          label: 'car',
          confidence: 0.9,
          left: 0.3,
          top: 0.3,
          right: 0.7,
          bottom: 0.8,
        ),
      ],
      threatScore: 0.25,
    );

AmbientScanPolicy _policy() => AmbientScanPolicy(
      interval: const Duration(seconds: 30),
      alertInterval: const Duration(seconds: 15),
      calmInterval: const Duration(seconds: 60),
      calmAfter: 4,
      minMovementMeters: 8,
      minBatteryPercent: 20,
    );

AmbientDecision _decide(
  AmbientScanPolicy p, {
  required DateTime now,
  double moved = 100,
  int? battery = 80,
  bool enabled = true,
}) =>
    p.decide(enabled: enabled, now: now, metersMoved: moved, batteryPercent: battery);

void main() {
  group('the first look', () {
    test('happens immediately rather than after the first 8 metres', () {
      // A user who has just started walking should get a look now. Applying
      // the movement rule to the very first scan would leave them unscanned
      // through the opening stretch.
      expect(_decide(_policy(), now: _t0, moved: 0), AmbientDecision.scan);
    });
  });

  group('pacing', () {
    test('a second look inside the interval is refused', () {
      final p = _policy();
      expect(_decide(p, now: _t0), AmbientDecision.scan);
      p.recordScan(_t0, _clear());
      expect(_decide(p, now: _t0.add(const Duration(seconds: 20))),
          AmbientDecision.tooSoon);
    });

    test('and allowed once the interval has passed', () {
      final p = _policy();
      p.recordScan(_t0, _clear());
      expect(_decide(p, now: _t0.add(const Duration(seconds: 31))),
          AmbientDecision.scan);
    });

    test('backs off after four consecutive clear looks', () {
      // A quiet street should cost less than a busy one — this is what makes
      // a long walk affordable rather than a constant 3% duty cycle.
      final p = _policy();
      for (var i = 0; i < 4; i++) {
        p.recordScan(_t0.add(Duration(seconds: 30 * i)), _clear());
      }
      expect(p.currentInterval, const Duration(seconds: 60));
      expect(_decide(p, now: _t0.add(const Duration(seconds: 90 + 45))),
          AmbientDecision.tooSoon);
    });

    test('anything seen resets the pace to attentive', () {
      // A street that produced one hazard is likely to produce another, and
      // that is the wrong moment to be saving battery.
      final p = _policy();
      for (var i = 0; i < 4; i++) {
        p.recordScan(_t0, _clear());
      }
      expect(p.currentInterval, const Duration(seconds: 60));
      p.recordScan(_t0, _sawSomething());
      expect(p.currentInterval, const Duration(seconds: 30));
      expect(p.consecutiveClear, 0);
    });

    test('an alert raises the pace above everything else', () {
      // Near a reported hazard or a crossing, a calm stretch must not keep
      // the scanner on its 60-second pace.
      final p = _policy();
      for (var i = 0; i < 4; i++) {
        p.recordScan(_t0, _clear());
      }
      expect(p.currentInterval, const Duration(seconds: 60));
      p.alert = true;
      expect(p.currentInterval, const Duration(seconds: 15));
    });
  });

  group('not scanning a wall over and over', () {
    test('a stationary phone is refused', () {
      // The commonest stationary case is a blind user standing at a bus stop,
      // and re-photographing the same scene is pure drain.
      final p = _policy();
      p.recordScan(_t0, _clear());
      expect(
        _decide(p, now: _t0.add(const Duration(seconds: 31)), moved: 2),
        AmbientDecision.stationary,
      );
    });

    test('moving far enough is allowed', () {
      final p = _policy();
      p.recordScan(_t0, _clear());
      expect(
        _decide(p, now: _t0.add(const Duration(seconds: 31)), moved: 12),
        AmbientDecision.scan,
      );
    });

    test('the clock is checked before movement', () {
      // So a stationary user is not re-evaluated on every tick — the cheaper
      // test comes first and short-circuits.
      final p = _policy();
      p.recordScan(_t0, _clear());
      expect(
        _decide(p, now: _t0.add(const Duration(seconds: 5)), moved: 0),
        AmbientDecision.tooSoon,
      );
    });
  });

  group('giving up the feature before the battery', () {
    test('stops under the floor', () {
      // A blind user cannot see a battery indicator, and the phone is what
      // stands between them and being lost. Convenience scanning goes first;
      // navigation, the wake word and the Magic Button all need the same
      // battery and all matter more.
      expect(_decide(_policy(), now: _t0, battery: 15), AmbientDecision.batteryLow);
    });

    test('runs at the floor exactly', () {
      expect(_decide(_policy(), now: _t0, battery: 20), AmbientDecision.scan);
    });

    test('an unreadable battery does not silently kill the feature', () {
      // A device that will not report its level must not lose ambient
      // scanning by default — every other guard still applies.
      expect(_decide(_policy(), now: _t0, battery: null), AmbientDecision.scan);
    });
  });

  group('switched off', () {
    test('a disabled profile never scans, whatever else is true', () {
      expect(
        _decide(_policy(), now: _t0, enabled: false, battery: 100, moved: 500),
        AmbientDecision.notEnabled,
      );
    });
  });

  group('reset', () {
    test('a new journey does not inherit a calm pace', () {
      final p = _policy();
      for (var i = 0; i < 4; i++) {
        p.recordScan(_t0, _clear());
      }
      p.alert = true;
      p.reset();
      expect(p.currentInterval, const Duration(seconds: 30));
      expect(p.consecutiveClear, 0);
      expect(p.alert, isFalse);
      // And the first look after a reset is immediate again.
      expect(_decide(p, now: _t0, moved: 0), AmbientDecision.scan);
    });
  });
}
