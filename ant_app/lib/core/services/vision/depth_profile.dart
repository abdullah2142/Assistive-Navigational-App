import 'dart:math' as math;

/// What the ground does just ahead.
enum GroundChange {
  /// Continues at the same level, as far as can be seen.
  level,

  /// Falls away — a descending step, a kerb, an unguarded edge.
  ///
  /// **The dangerous one.** For a blind pedestrian a drop is a fall, where an
  /// obstacle is a bump, so this is the only value that earns an interruption
  /// on its own.
  dropsAway,

  /// Rises — an ascending step or a kerb up. Worth mentioning so the user
  /// lifts a foot, not worth stopping them for.
  risesUp,

  /// The profile was too noisy to read. **Not** [level] — see
  /// [DropoffVerdict.isTrustworthy].
  unreadable,
}

/// What the depth model saw of the ground.
class DropoffVerdict {
  const DropoffVerdict({
    required this.change,
    required this.score,
    required this.rowsAhead,
    required this.paces,
  });

  final GroundChange change;

  /// Robust z-score of the sharpest discontinuity in the ground profile.
  /// Unitless; see [DepthProfile.analyse].
  final double score;

  /// How far up the sampled strip the discontinuity sat, 0 (at the feet) to
  /// 1 (the far end of the visible ground).
  final double rowsAhead;

  /// [rowsAhead] turned into something speakable. Deliberately coarse — the
  /// model gives *relative* depth, so any number in metres would be invented.
  final int paces;

  bool get isDangerous => change == GroundChange.dropsAway;

  /// False when the reading cannot be relied on. The caller must then say
  /// nothing rather than say "clear" — a blind user hearing an all-clear from
  /// an unreadable frame is the failure this whole module is built to avoid.
  bool get isTrustworthy => change != GroundChange.unreadable;

  static const DropoffVerdict unreadable = DropoffVerdict(
    change: GroundChange.unreadable,
    score: 0,
    rowsAhead: 0,
    paces: 0,
  );
}

/// Finds a step or a drop in a depth map.
///
/// ## How it works
///
/// MiDaS emits *inverse* depth — a larger value means nearer — over a
/// 256x256 grid, relative and unscaled. Walking forward, the ground the user
/// is about to step on is the bottom-centre of the frame, so this takes a
/// vertical strip there and reads the profile from the feet outward.
///
/// On unbroken ground that profile falls smoothly: each row further from the
/// camera is a little further away. A step or kerb breaks the smoothness —
/// the surface beyond the edge is suddenly much further (a drop) or much
/// nearer (a rise) than the trend predicts. So the question is not "what is
/// the depth" but "where does the depth stop behaving".
///
/// Measured against the *median* first difference and the median absolute
/// deviation rather than the mean and standard deviation, because one sharp
/// edge is exactly the outlier that would drag a mean-based threshold up to
/// hide itself.
///
/// ## What it cannot tell you
///
/// The output is relative, so there is no metric height and no step count.
/// "The ground drops away about two paces ahead" is the most that can honestly
/// be said, and [paces] is derived from image geometry rather than measured.
/// Distinguishing stairs from an escalator from a kerb needs the cloud tier.
///
/// ## Pure on purpose
///
/// No TFLite here. Every threshold in this file decides whether a blind
/// person is told to stop, and that has to be testable by feeding in a
/// synthetic profile — the same split `NavigationNarrator` has from
/// `NavigationController`.
class DepthProfile {
  const DepthProfile({
    this.minScore = defaultMinScore,
    this.minProfileRows = 24,
  });

  /// How far a discontinuity must stand out from the surrounding trend.
  ///
  /// **This is a guess and must be measured before it is trusted.** It is the
  /// number that decides whether somebody is told to stop walking, and no
  /// value here has been checked against a real pavement — the model was
  /// verified to load and run, not to be right about a Dhaka kerb.
  ///
  /// Treat it exactly as `WakeWordService.defaultDetectionThreshold` was
  /// treated before somebody sat down with a Redmi and counted 56 windows:
  /// a starting point with a dial on it. `[Depth]` log lines carry the score
  /// of every scan precisely so that walk can be done — see
  /// `DepthDropoffDetector`.
  ///
  /// 6.0 is chosen so that a discontinuity must be six times the typical
  /// row-to-row variation, which on smooth ground is small. Too low and every
  /// paving slab is a cliff; too high and a real kerb is missed.
  static const double defaultMinScore = 6.0;

  final double minScore;

  /// Below this many usable rows the profile is not worth reading.
  final int minProfileRows;

  /// Reads a ground profile, ordered **nearest first**.
  ///
  /// [profile] is one inverse-depth value per image row of the sampled strip,
  /// index 0 nearest the user's feet. The caller builds it; this decides what
  /// it means.
  DropoffVerdict analyse(List<double> profile) {
    if (profile.length < minProfileRows) return DropoffVerdict.unreadable;

    final range = profile.reduce(math.max) - profile.reduce(math.min);
    // A flat-line profile means the model found no structure at all — a wall
    // at arm's length, a lens against a pocket, total darkness. Reading a
    // discontinuity out of noise that small would be inventing one.
    if (range <= 1e-4) return DropoffVerdict.unreadable;

    // Normalised so the threshold means the same thing whatever absolute
    // range the model returned for this scene — it varies a lot between
    // frames, being relative.
    final normalised = [for (final v in profile) (v - profile.reduce(math.min)) / range];

    final diffs = <double>[
      for (var i = 1; i < normalised.length; i++) normalised[i] - normalised[i - 1],
    ];

    final medianDiff = _median(diffs);
    // Floored, not rejected. A profile whose rows step down by exactly the
    // same amount every time has a MAD of zero — and if such a profile also
    // contains one sharp edge, that edge is the *clearest* drop it is
    // possible to see. An earlier version bailed out as "unreadable" there,
    // which threw away the unambiguous case to avoid dividing by zero.
    //
    // The floor is relative to the normalised 0-1 profile, so it means the
    // same thing whatever range the model returned: a deviation smaller than
    // a thousandth of the visible depth span is not a step, it is arithmetic
    // noise.
    final mad = math.max(
      _median([for (final d in diffs) (d - medianDiff).abs()]),
      1e-3,
    );

    var worstIndex = 0;
    var worstZ = 0.0;
    for (var i = 0; i < diffs.length; i++) {
      // The first and last few rows are where depth models put their edge
      // artefacts, and a phantom cliff at the frame boundary is the commonest
      // false positive there is.
      if (i < 2 || i > diffs.length - 3) continue;
      final z = (diffs[i] - medianDiff) / mad;
      if (z.abs() > worstZ.abs()) {
        worstZ = z;
        worstIndex = i;
      }
    }

    if (worstZ.abs() < minScore) {
      return DropoffVerdict(
        change: GroundChange.level,
        score: worstZ.abs(),
        rowsAhead: 0,
        paces: 0,
      );
    }

    final ahead = worstIndex / diffs.length;
    return DropoffVerdict(
      // Inverse depth: **larger is nearer**. So the ground falling away is
      // inverse depth dropping faster than the trend — a negative spike —
      // and a step up is a positive one. Getting this sign backwards would
      // announce every kerb as a drop and every drop as a kerb, which is
      // worse than saying nothing.
      change: worstZ < 0 ? GroundChange.dropsAway : GroundChange.risesUp,
      score: worstZ.abs(),
      rowsAhead: ahead,
      paces: _paces(ahead),
    );
  }

  /// Image position to paces.
  ///
  /// Crude by necessity: the model's depth is relative, so distance can only
  /// come from where the edge sits in the frame, which depends on how the
  /// phone is held. Three bands rather than a number, because "about two
  /// paces" is honest and "1.7 metres" would not be.
  static int _paces(double ahead) {
    if (ahead < 0.33) return 1;
    if (ahead < 0.66) return 2;
    return 4;
  }

  static double _median(List<double> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }
}
