import 'dart:math' as math;

/// What the edge detector believes it saw, in one frame.
///
/// Deliberately a plain value type with no TFLite in it: every decision this
/// module makes about *whether to stop the user walking* is made from these
/// numbers, and that decision has to be testable by constructing detections
/// by hand rather than only by pointing a phone at a bus.
class VisionDetection {
  const VisionDetection({
    required this.label,
    required this.confidence,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  /// COCO class name, exactly as it appears in `assets/vision/labelmap.txt`.
  final String label;

  /// 0-1, as reported by the model.
  final double confidence;

  /// Normalized box edges, 0-1, origin top-left.
  ///
  /// The model emits `[ymin, xmin, ymax, xmax]`; this reorders to something a
  /// reader can keep straight, because getting the pair order wrong produces
  /// boxes that are *plausible* rather than obviously broken — they still
  /// land on screen, just rotated into the wrong quadrant, which is the kind
  /// of bug that survives a casual look at a debug overlay.
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => (right - left).clamp(0.0, 1.0);
  double get height => (bottom - top).clamp(0.0, 1.0);

  /// Fraction of the frame this object covers.
  double get area => width * height;

  /// Horizontal centre, 0 (hard left) to 1 (hard right).
  double get centerX => (left + right) / 2;

  /// Whether the box sits in the middle third of the frame — the part of the
  /// scene the user is walking into, as opposed to the part they are walking
  /// past.
  ///
  /// A bus filling the left edge of the frame is a bus at the kerb beside
  /// them; the same bus in the centre is a bus in front of them. Treating
  /// those identically is what would make the alarm fire constantly on a
  /// Dhaka street and teach the user to ignore it.
  bool get isAhead => centerX > 0.33 && centerX < 0.67;
}

/// The classes the *safety* tier reacts to, and how much each one matters.
///
/// ## Why this list is short
///
/// COCO has 90 classes and almost none of them can hurt a pedestrian. A
/// `teddy bear` or a `potted plant` detected at high confidence is not a
/// reason to interrupt somebody mid-step, and an alarm that fires on
/// furniture is an alarm that gets ignored by the time it matters.
///
/// ## Why rickshaws and CNGs are not in it
///
/// They cannot be. No off-the-shelf COCO detector has a class for either,
/// and training one needs a labelled Dhaka dataset that is out of scope for
/// this module. In practice a cycle-rickshaw is detected as `bicycle` and a
/// CNG auto-rickshaw as `car` or `truck`, which is *wrong as a name* and
/// *right as a hazard* — and this tier only decides whether to say stop, not
/// what to call the thing. Naming it correctly is the cloud tier's job; see
/// `cloud_vision_service.dart`.
///
/// The weights are relative danger, not size: a bus and a truck kill a
/// pedestrian in a way a bicycle does not, so they clear the alarm threshold
/// at a smaller apparent size.
const Map<String, double> kHazardClassWeights = {
  'bus': 1.0,
  'truck': 1.0,
  'train': 1.0,
  'car': 0.9,
  'motorcycle': 0.85,
  'bicycle': 0.6,
  // A person is a hazard only when they are extremely close — a wall of
  // people is a blocked footpath, and one person at arm's length is somebody
  // about to be walked into. Weighted low so ordinary pavement traffic does
  // not trip the alarm.
  'person': 0.4,
};

/// How sure the model has to be before a detection is considered at all.
///
/// SSD MobileNet is a small quantized model and its low-confidence tail is
/// mostly noise. 0.45 is not tuned against a Dhaka street — it is the
/// conventional operating point for this model, and it should be re-measured
/// on real footage before anyone claims a number for it.
const double kMinDetectionConfidence = 0.45;

/// What the app should do about one frame.
///
/// Three states rather than a bool, because "nothing dangerous" and "could
/// not tell" are different answers and collapsing them is how a blind user
/// ends up trusting silence that means the camera failed.
enum HazardLevel {
  /// Nothing close enough to act on.
  clear,

  /// Something worth mentioning in the spoken description, but not worth
  /// interrupting a step for.
  caution,

  /// Stop now. Long buzz, spoken abort, sweep aborted before any upload.
  imminent,
}

/// The edge tier's verdict on a frame.
class HazardVerdict {
  const HazardVerdict({
    required this.level,
    required this.detections,
    this.nearest,
    this.threatScore = 0,
  });

  final HazardLevel level;

  /// Everything above [kMinDetectionConfidence], nearest first.
  final List<VisionDetection> detections;

  /// The detection that drove [level], or null when nothing did.
  final VisionDetection? nearest;

  /// The winning proximity score, for logs and tests. Unitless.
  final double threatScore;

  bool get isImminent => level == HazardLevel.imminent;

  /// How many people are in frame — the cheap, offline half of "is there a
  /// crowd". The cloud tier gives a real count and a description; this is
  /// what is available with no network at all.
  int get personCount => detections.where((d) => d.label == 'person').length;

  static const HazardVerdict empty =
      HazardVerdict(level: HazardLevel.clear, detections: []);
}

/// Turns raw detections into a stop-or-go decision.
///
/// ## Why bounding-box geometry and not a distance model
///
/// Monocular depth estimation is a second model, a second asset, and a
/// second inference per frame — real battery and latency for an answer this
/// tier does not need. The question here is not "how many metres away is the
/// bus", it is "is the bus big enough in frame that I should not take
/// another step", and apparent size answers that directly.
///
/// What it costs: the score is confounded by the object's real size. A
/// pedestrian at two metres and a bus at fifteen can produce similar boxes.
/// [kHazardClassWeights] is the correction — a bus is allowed to be smaller
/// in frame before it counts, because a bus that looks small is still a bus
/// that is moving.
///
/// ## Why it is biased toward the bottom of the frame
///
/// A phone held by a walking person points slightly down. Things near the
/// bottom of the frame are near the user's feet; things near the top are far
/// away or overhead. Without this, a bus half a block up the road scores the
/// same as one at the kerb.
class HazardAssessor {
  const HazardAssessor({
    this.imminentThreshold = 0.42,
    this.cautionThreshold = 0.18,
  });

  /// Score at which the alarm fires. See [assess] for what a score is.
  ///
  /// **Not measured against real Dhaka footage.** It is set so that a bus
  /// occupying roughly a third of the frame's width, centred, low in frame,
  /// crosses it — which is approximately "close enough to touch" for a
  /// vehicle. Treat it as a starting point with a dial on it, exactly like
  /// `WakeWordService.defaultDetectionThreshold` was before it was measured.
  final double imminentThreshold;

  /// Score at which something is worth mentioning but not worth stopping for.
  final double cautionThreshold;

  HazardVerdict assess(List<VisionDetection> raw) {
    final considered = raw
        .where((d) => d.confidence >= kMinDetectionConfidence)
        .where((d) => kHazardClassWeights.containsKey(d.label))
        .toList();

    if (considered.isEmpty) {
      // Detections that are not hazards still belong in the verdict — the
      // spoken description uses them ("a traffic light and two people"), and
      // dropping them here would mean the offline description is emptier
      // than it needs to be.
      final others =
          raw.where((d) => d.confidence >= kMinDetectionConfidence).toList();
      return HazardVerdict(level: HazardLevel.clear, detections: others);
    }

    VisionDetection? worst;
    var worstScore = 0.0;
    for (final d in considered) {
      final score = _threatScore(d);
      if (score > worstScore) {
        worstScore = score;
        worst = d;
      }
    }

    final sorted = considered..sort((a, b) => _threatScore(b).compareTo(_threatScore(a)));

    final level = switch (worstScore) {
      final s when s >= imminentThreshold => HazardLevel.imminent,
      final s when s >= cautionThreshold => HazardLevel.caution,
      _ => HazardLevel.clear,
    };

    return HazardVerdict(
      level: level,
      detections: sorted,
      nearest: worst,
      threatScore: worstScore,
    );
  }

  /// Unitless, monotonic in "how much should I care about this right now".
  ///
  /// Uses the square root of area rather than area itself so the score tracks
  /// *linear* apparent size. Area grows with the square of closeness, which
  /// makes a raw-area threshold behave like a cliff — an object is ignorable
  /// and then, one step later, catastrophic — where a blind user needs the
  /// caution band to actually be reachable.
  double _threatScore(VisionDetection d) {
    final weight = kHazardClassWeights[d.label] ?? 0;
    if (weight == 0) return 0;

    final apparentSize = math.sqrt(d.area);

    // 1.0 at the bottom edge, 0.55 at the top. Never zero: a bus at the top
    // of the frame is further away, not harmless.
    final lowness = 0.55 + 0.45 * d.bottom.clamp(0.0, 1.0);

    // Something directly ahead matters more than something passing at the
    // edge of vision, but the edge is not discounted to nothing — Dhaka
    // traffic arrives from the side.
    final ahead = d.isAhead ? 1.0 : 0.72;

    return apparentSize * weight * lowness * ahead * d.confidence;
  }
}
