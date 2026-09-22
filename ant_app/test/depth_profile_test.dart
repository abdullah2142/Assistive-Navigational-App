// Reading a step or a drop out of a depth profile.
//
// ## What this file can and cannot check
//
// It checks the **arithmetic**: given a ground profile shaped like a drop, a
// step up, or unbroken pavement, does the analyser call it correctly, in the
// right direction, and refuse to answer when the input is noise.
//
// It does **not** check that MiDaS produces those shapes for a real Dhaka
// kerb. That cannot be checked here and was tried: a depth model shown a
// *drawing* of stairs estimates the depth of a drawing, and the profiles came
// back indistinguishable from flat ground. The thresholds need a calibration
// walk with a real phone past a real kerb — see `DepthDropoffDetector`, which
// logs every score so that walk produces usable data.
//
// So: the sign convention, the refusal behaviour and the band edges are
// pinned here. The number itself is not, and is documented as a guess.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/vision/depth_profile.dart';

const _analyser = DepthProfile();

/// Unbroken ground: inverse depth falls smoothly with distance (larger =
/// nearer, so the nearest row is highest).
List<double> _flat({int rows = 120, double noise = 0}) {
  final rand = math.Random(3);
  return [
    for (var i = 0; i < rows; i++)
      1.0 - i / rows + (noise == 0 ? 0 : (rand.nextDouble() - 0.5) * noise),
  ];
}

/// Ground that falls away at [at]: beyond the edge the surface is suddenly
/// much further, so inverse depth plunges.
List<double> _drop({double at = 0.5, double size = 0.4, int rows = 120, double noise = 0.01}) {
  final p = _flat(rows: rows, noise: noise);
  final edge = (rows * at).round();
  for (var i = edge; i < rows; i++) {
    p[i] -= size;
  }
  return p;
}

/// A step up: the surface beyond is suddenly nearer.
List<double> _riseUp({double at = 0.5, double size = 0.4, int rows = 120}) {
  final p = _flat(rows: rows);
  final edge = (rows * at).round();
  for (var i = edge; i < rows; i++) {
    p[i] += size;
  }
  return p;
}

void main() {
  group('unbroken ground', () {
    test('a smooth slope is level, not a hazard', () {
      final v = _analyser.analyse(_flat(noise: 0.01));
      expect(v.change, GroundChange.level);
      expect(v.isDangerous, isFalse);
      expect(v.isTrustworthy, isTrue);
    });

    test('ordinary paving texture does not become a cliff', () {
      // The false-positive direction. A warning on every paving slab is a
      // warning the user learns to walk through, which costs the real one.
      for (final noise in [0.005, 0.01, 0.02]) {
        expect(_analyser.analyse(_flat(noise: noise)).isDangerous, isFalse,
            reason: 'noise=$noise should not read as a drop');
      }
    });
  });

  group('ground that stops', () {
    test('a drop is detected and called a drop', () {
      final v = _analyser.analyse(_drop());
      expect(v.change, GroundChange.dropsAway);
      expect(v.isDangerous, isTrue);
      expect(v.score, greaterThan(DepthProfile.defaultMinScore));
    });

    test('a step up is detected and is not called a drop', () {
      // The sign convention, which is the single easiest thing to get
      // backwards here — inverse depth means larger is *nearer*. Reversed,
      // every kerb would be announced as a hole and every hole as a kerb.
      final v = _analyser.analyse(_riseUp());
      expect(v.change, GroundChange.risesUp);
      expect(v.isDangerous, isFalse);
    });

    test('a nearer drop is reported as fewer paces', () {
      final near = _analyser.analyse(_drop(at: 0.15));
      final far = _analyser.analyse(_drop(at: 0.8));
      expect(near.paces, lessThan(far.paces));
      expect(near.change, GroundChange.dropsAway);
      expect(far.change, GroundChange.dropsAway);
    });

    test('a bigger drop scores higher than a shallow one', () {
      final shallow = _analyser.analyse(_drop(size: 0.15));
      final deep = _analyser.analyse(_drop(size: 0.6));
      expect(deep.score, greaterThan(shallow.score));
    });
  });

  group('refusing to answer', () {
    test('a profile too short to read is unreadable, not level', () {
      // The safety contract: "I could not see" must never be delivered as
      // "the ground is fine". A blind user hearing an all-clear from a scan
      // that did not run keeps walking.
      final v = _analyser.analyse(List.filled(5, 0.5));
      expect(v.change, GroundChange.unreadable);
      expect(v.isTrustworthy, isFalse);
    });

    test('a flat-line profile is unreadable', () {
      // A lens against a pocket, a wall at arm's length, darkness. There is
      // no structure to read and inventing one would be the worst outcome.
      expect(_analyser.analyse(List.filled(120, 0.4)).change,
          GroundChange.unreadable);
    });

    test('an empty profile is unreadable', () {
      expect(_analyser.analyse(const []).change, GroundChange.unreadable);
    });

    test('unreadable is never dangerous and never trustworthy', () {
      const v = DropoffVerdict.unreadable;
      expect(v.isDangerous, isFalse);
      expect(v.isTrustworthy, isFalse);
    });
  });

  group('frame edges', () {
    test('a discontinuity at the very edge is ignored', () {
      // Depth models put artefacts at the frame boundary, and a phantom cliff
      // there is the commonest false positive this class can produce.
      final p = _flat();
      p[0] -= 0.9;
      p[p.length - 1] += 0.9;
      expect(_analyser.analyse(p).isDangerous, isFalse);
    });

    test('but a real drop just inside the edge is still caught', () {
      expect(_analyser.analyse(_drop(at: 0.06)).change, GroundChange.dropsAway);
    });
  });

  group('the threshold is a dial', () {
    test('a stricter threshold reports fewer drops', () {
      // Deliberately a *noisy* profile, because the dial only means anything
      // against real row-to-row variation. On perfectly smooth synthetic
      // ground the median absolute deviation is floored, scores run into the
      // hundreds, and any threshold below that looks equally permissive —
      // which would make this test agree with itself rather than with a
      // pavement.
      final shallow = _drop(size: 0.12, noise: 0.02);
      final lenient = const DepthProfile(minScore: 3).analyse(shallow);
      final strict = const DepthProfile(minScore: 400).analyse(shallow);
      expect(lenient.isDangerous, isTrue);
      expect(strict.isDangerous, isFalse);
      expect(strict.change, GroundChange.level);
    });

    test('the shipped default is documented as unmeasured', () {
      // Pinned so a future change is deliberate. 6.0 has never met a real
      // kerb — see this file's header and `DepthDropoffDetector`.
      expect(DepthProfile.defaultMinScore, 6.0);
    });
  });
}
