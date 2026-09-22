/// Tunables for the Snapshot Vision Engine (`06_module_plan_snapshot_vision.md`).
///
/// Every number here was chosen against a measurement or a stated constraint,
/// and the ones that were not say so. They are `int.fromEnvironment` where a
/// tester might reasonably need to move them without a code change, following
/// `WAKE_WORD_THRESHOLD_PCT`'s precedent.
class VisionConfig {
  VisionConfig._();

  /// What the cloud tier is sent.
  ///
  /// **320x240, and the resolution is not about accuracy.** Measured against
  /// Groq's vision endpoint on 21 September: a 320x240, 448x336, 640x480 and
  /// 800x600 JPEG of the same Bangla signboard all cost **1,821 prompt
  /// tokens** and all produced byte-identical transcriptions. The model bills
  /// a flat tile cost, so resolution buys nothing and costs upload bytes.
  ///
  /// 8 KB instead of 28 KB is ~3.5x less radio-on time per scan, which on a
  /// phone is the difference the battery actually notices — the cellular
  /// radio, not the camera, is the expensive part of a snapshot.
  ///
  /// Raise it only with a measurement showing the model reads something at
  /// 640 that it cannot read at 320. It did not in the one test that exists.
  static const int uploadWidth = 320;
  static const int uploadHeight = 240;
  static const int uploadJpegQuality = 72;

  /// The input the TFLite detector wants: `[1, 300, 300, 3]`, uint8.
  /// Fixed by `assets/vision/ssd_mobilenet_v1.tflite`; changing the model
  /// changes this.
  static const int edgeInputSize = 300;

  /// Maximum boxes the model's built-in NMS emits. Fixed by the model's
  /// `TFLite_Detection_PostProcess` output shape `[1, 10, 4]`.
  static const int edgeMaxDetections = 10;

  /// How long the camera stays open after a capture before it is released.
  ///
  /// A cold camera open costs 300-600 ms on a budget Android phone, which is
  /// a third of the latency budget for "what bus is this". Keeping it warm
  /// makes a follow-up scan feel instant.
  ///
  /// It is also a sensor drawing power and warming the phone, which is the
  /// exact failure mode the Snapshot Architecture exists to prevent — so the
  /// window is short, and *any* app backgrounding releases it immediately
  /// regardless of this timer. See `SnapshotCamera`.
  static const Duration cameraWarmWindow = Duration(seconds: 20);

  /// Frames captured by a sweep, and the gap between them.
  ///
  /// Three over roughly three seconds, per the plan's Stationary Sweep. Only
  /// the sharpest of them is ever uploaded — see [framesUploadedPerScan].
  static const int sweepFrameCount = 3;
  static const Duration sweepFrameGap = Duration(milliseconds: 900);

  /// How long to wait after cueing a sweep position before capturing.
  ///
  /// This is what makes the sweep three *sharp* frames rather than three
  /// smeared ones. The original design captured on a timer during a
  /// continuous pan, which guarantees motion blur — and blur is precisely
  /// what was measured destroying Bangla sign reading (`গুলশান` ->
  /// `ঠানশান`). A person hearing "left" needs roughly this long to turn and
  /// stop.
  ///
  /// Total sweep is therefore about 3 x (cue + 700ms + shutter) ≈ 4 s. Longer
  /// than the old burst, and the frames are usable.
  static const Duration sweepSettleDelay = Duration(milliseconds: 700);

  /// **One.** Never the whole sweep.
  ///
  /// This is the hard constraint the module is built around. Groq's free tier
  /// meters *input tokens per minute*, measured at **7,000 ITPM**, and one
  /// scan costs **2,142** of them — measured against the live endpoint with
  /// this module's actual prompt, not estimated. (The image alone is ~1,821;
  /// the schema and the Dhaka-vehicle instructions are the rest.) Three
  /// uploaded frames is ~6,400 — most of a minute's entire allowance for a
  /// single question, and only about three scans fit in a minute at all.
  ///
  /// That allowance is **shared with the conversational assistant**. So a
  /// three-frame sweep does not merely cost more; it takes away the user's
  /// ability to *talk to the app* for the following minute. For somebody who
  /// cannot see the screen, the voice channel is the only interface there is,
  /// and spending it on redundant views of the same bus stop is the worst
  /// trade available.
  ///
  /// The edge model still looks at all [sweepFrameCount] frames — that is
  /// free and local — and picks the sharpest to send.
  static const int framesUploadedPerScan = 1;

  /// Minimum gap between two cloud vision calls.
  ///
  /// Without it, a user tapping the scan chip repeatedly — which is exactly
  /// what somebody does when they are not sure the app heard them — spends
  /// the shared ITPM allowance in seconds and is then unable to speak to the
  /// assistant at all. The failure would be silent and would look like the
  /// app breaking for no reason.
  ///
  /// A repeat inside this window is answered from the last result rather than
  /// refused, so asking twice gets an answer twice.
  static const Duration cloudScanCooldown = Duration(seconds: 12);

  /// How long a cached scene stays answerable for a repeat question.
  static const Duration sceneCacheLifetime = Duration(seconds: 45);

  /// Wall-clock ceiling on one cloud scan, upload included.
  ///
  /// Measured latency was 0.43-0.70 s wall against a good connection; this is
  /// an order of magnitude of headroom for a Dhaka mobile network. Past it the
  /// app says it could not see rather than leaving a blind user waiting on a
  /// sentence that is not coming.
  static const Duration cloudTimeout = Duration(seconds: 12);

  // ---- Ambient scanning (periodic, edge-only) ------------------------------

  /// How often to look around unprompted while the user is walking.
  ///
  /// **This is the sanctioned architecture, not a deviation from it.**
  /// `claude.md` bans *video* — "Never implement WebRTC or live video
  /// streaming" — and in the same breath prescribes "taking periodic
  /// high-res photos for edge processing". An earlier draft of this module
  /// cut periodic capture on battery grounds; that read the rule backwards.
  ///
  /// 30 seconds is roughly a 3% duty cycle: about one second of camera and
  /// CPU per scan, with the sensor reused inside [cameraWarmWindow] so most
  /// scans skip the 300-600 ms cold open entirely.
  ///
  /// What keeps it affordable is not the interval but the tier: an ambient
  /// scan **never** reaches the cloud. No tokens, no data, no radio. It asks
  /// the one question the local model can answer — is something large and
  /// close — and stays silent otherwise.
  static const Duration ambientInterval = Duration(seconds: 30);

  /// Interval used when the user is near a reported hazard or an approaching
  /// crossing. Still edge-only; just more attentive where the map already
  /// says attention is warranted.
  static const Duration ambientAlertInterval = Duration(seconds: 10);

  /// Interval after several consecutive clear scans.
  ///
  /// A quiet street should cost less than a busy one. Backing off is what
  /// makes a long walk affordable rather than a constant 3%.
  static const Duration ambientCalmInterval = Duration(seconds: 60);

  /// Consecutive clear scans before backing off to [ambientCalmInterval].
  static const int ambientCalmAfter = 4;

  /// Below this battery percentage, ambient scanning stops entirely.
  ///
  /// A blind user cannot see a battery indicator, and the phone is the only
  /// thing standing between them and being lost. Convenience scanning is the
  /// first thing that should go — navigation, the wake word and the Magic
  /// Button all matter more, and all need the same battery.
  static const int ambientMinBatteryPercent = 20;

  /// How far the user must have moved since the last ambient scan.
  ///
  /// A stationary phone re-photographing the same wall is pure drain, and a
  /// blind user standing still at a bus stop is the commonest stationary
  /// case there is. Matches `NavigationController._minMovementMeters`.
  static const double ambientMinMovementMeters = 8;

  /// How close a reported hazard has to be to trigger a look.
  ///
  /// Far enough to stop before reaching it at walking pace (~1.4 m/s), near
  /// enough that the camera is pointed at roughly the right piece of street.
  static const double hazardApproachMeters = 35;

  /// Same, for an approaching crossing — `ManeuverKind.crossing`.
  ///
  /// Tighter than [hazardApproachMeters] because a crossing's position is
  /// known precisely from the route geometry, where a crowdsourced hazard pin
  /// is only as accurate as the phone that dropped it.
  static const double crossingApproachMeters = 25;

  /// Vision model on Groq.
  ///
  /// The same `qwen/qwen3.8-27b` the assistant already talks to — verified
  /// multimodal on 21 September by sending it a rendered Bangla signboard,
  /// which it transcribed exactly (`৬ নং মিরপুর ১০ গুলশান - ফার্মগেট`) and
  /// summarised in Bangla unprompted.
  ///
  /// This is a deliberate deviation from `06_module_plan_snapshot_vision.md`,
  /// which specifies Google Cloud Vision. Reasons, in order of weight:
  ///
  /// 1. **Cloud Vision does OCR, and OCR is not the feature.** It returns the
  ///    text on a bus. It cannot say "that is a CNG auto-rickshaw pulling
  ///    out", "there is an open manhole to your left", or "the footpath ahead
  ///    is blocked by about thirty people" — which is most of what a blind
  ///    user needs from a camera, and all of which a vision-language model
  ///    answers from the same single frame.
  /// 2. **One round trip instead of two.** Cloud Vision returns raw strings
  ///    that then need a language model to become a spoken Bangla sentence.
  /// 3. **No new credential or billing account.** This project deliberately
  ///    moved off Google's billed APIs to Groq's free tier; Cloud Vision
  ///    would reintroduce exactly that dependency for one feature.
  ///
  /// What the deviation costs, stated plainly: Cloud Vision's Bangla OCR is
  /// more accurate on degraded input. Measured on a deliberately blurred,
  /// rotated, low-contrast render of the same sign, Qwen kept the route
  /// number (`৬`) and the first destination but corrupted the second
  /// (`গুলশান` -> `ঠানশান`). [busRouteLookupWins] is the mitigation.
  static const String visionModel = 'qwen/qwen3.8-27b';

  /// Whether a matched Firestore route record overrides the model's reading
  /// of the destination names.
  ///
  /// **It does, and this is the whole reason Step 3.3 of the plan exists.**
  /// The degradation measured above is not uniform: digits survive blur far
  /// better than conjunct Bangla letterforms, because there are ten of them
  /// and they are visually distinct, where `গুলশান` and `ঠানশান` differ by
  /// one stroke. So the route *number* is trustworthy and the destination
  /// *names* are not.
  ///
  /// Reading out a hallucinated destination to somebody who cannot check it
  /// against the sign in front of them is the most damaging thing this module
  /// could do. So the number becomes a key into the known-routes collection,
  /// and the names come from there.
  static const bool busRouteLookupWins = true;
}
