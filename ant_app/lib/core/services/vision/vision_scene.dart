/// What a scan was asked to look for.
///
/// One enum rather than four separate assistant tools, because every tool
/// declaration is input tokens on a budget measured at 7,000 per minute and
/// shared with the conversation itself — see `VisionConfig.framesUploadedPerScan`.
/// The focus changes the prompt and the spoken framing, not the plumbing.
enum ScanFocus {
  /// "What bus is this?" — one frame, immediately, no stand-still prompt.
  /// The plan's own example, and the case its 3-second sweep is too slow for:
  /// a bus that has been asked about for three seconds has gone.
  vehicle,

  /// "What does that sign say?" — reads and translates any text in frame.
  sign,

  /// "What's directly in front of me?" — **one** frame, straight ahead, no
  /// sweep and no stand-still prompt.
  ///
  /// Split out from [surroundings] after the 23 September session, where
  /// every single scan came back `frames=3 focus=surroundings` — including
  /// "can you tell me whats in front of me", which is a question about one
  /// direction. The sweep cost the user seventeen seconds of standing still
  /// and three cloud frames to answer a question about the view they were
  /// already facing. Reported directly: "whats in front of me should only
  /// take one frame in front of me".
  ahead,

  /// "What's around me?" — the plan's Stationary Sweep. Three frames, wide
  /// description.
  surroundings,

  /// "Is it safe to cross?" / "Is there anything in my way?" — biased toward
  /// obstacles and ground hazards rather than description.
  hazard,

  /// Ground underfoot and just ahead — stairs, escalators, ramps, kerb drops.
  ///
  /// Separate from [hazard] because it asks about a different *plane*. The
  /// hazard focus looks at what is in the way at body height; this looks at
  /// whether the ground continues at all.
  ///
  /// It is the most dangerous class of hazard for a blind pedestrian and the
  /// one the edge tier is least able to see: a descending stairwell is a fall
  /// rather than a bump, and COCO has no class for stairs, escalator, ramp or
  /// kerb. So it is asked proactively rather than only on request.
  terrain,

  /// "Is there a rickshaw?" — find the user a ride.
  ///
  /// Necessarily a cloud question and not an edge one: COCO has no class for
  /// a cycle-rickshaw or a CNG auto-rickshaw, so the on-device detector calls
  /// them `bicycle` and `car`. Those are the two vehicles most Dhaka trips
  /// actually use, and the two a blind person cannot hail unaided, so getting
  /// the *name* right is the entire feature rather than a nicety.
  ride,
}

/// One thing the cloud tier saw and thinks the user should know about.
class SceneHazard {
  const SceneHazard({required this.kind, required this.description, this.severity = 1});

  /// A stable English key where one of the known kinds matched — `manhole`,
  /// `construction`, `fire`, `crowd`, `broken_pavement`, `open_drain`,
  /// `flooding`, `vehicle`, `step` — or `other`.
  ///
  /// Stable because it is what maps onto a `HazardReport` if the user chooses
  /// to file one, and a Firestore key must not depend on the language the
  /// model happened to answer in.
  final String kind;

  /// The model's own words, in the user's language. Spoken as-is.
  final String description;

  /// 1 (mention it) to 3 (stop walking). The model's judgement, not a
  /// measurement — the edge tier owns the actual stop decision.
  final int severity;
}

/// A bus, rickshaw, CNG or other vehicle the cloud tier identified.
///
/// Separate from [SceneHazard] because these are the classes the edge
/// detector structurally cannot name — COCO has no rickshaw and no CNG — and
/// naming them is the reason the cloud tier exists at all for transit.
class SceneVehicle {
  const SceneVehicle({
    required this.kind,
    this.routeNumber,
    this.destination,
    this.rawText = '',
  });

  /// `bus`, `rickshaw`, `cng`, `car`, `motorcycle`, `truck`, `van`, `other`.
  final String kind;

  /// Route number as digits, Bangla numerals already normalised to ASCII.
  ///
  /// Trustworthy in a way [destination] is not — see
  /// `VisionConfig.busRouteLookupWins`.
  final String? routeNumber;

  /// Where the model read the vehicle as going. **Unverified.** Replaced by
  /// the Firestore route record whenever one matches [routeNumber].
  final String? destination;

  /// Everything the model read on the vehicle, verbatim.
  final String rawText;
}

/// The cloud tier's answer about one frame.
class VisionScene {
  const VisionScene({
    required this.focus,
    required this.spoken,
    this.hazards = const [],
    this.vehicles = const [],
    this.textFound = '',
    this.peopleEstimate,
    this.capturedAt,
    this.fromCache = false,
    this.degraded = false,
  });

  final ScanFocus focus;

  /// The sentence to say out loud, already in the user's language.
  ///
  /// The model writes this rather than the app assembling it from the
  /// structured fields, because a fluent Bangla sentence about a street is
  /// something the model is better at than a template — and a template that
  /// stitches `{vehicle} {number} {destination}` produces exactly the stilted
  /// output the assistant elsewhere in this app was rewritten to avoid.
  final String spoken;

  final List<SceneHazard> hazards;
  final List<SceneVehicle> vehicles;

  /// Any text read in frame, verbatim, whatever the focus was.
  final String textFound;

  /// Roughly how many people are in view, when the model offered a number.
  /// The offline path fills this from the edge detector's person count
  /// instead, which caps at 10 — see `VisionConfig.edgeMaxDetections`.
  final int? peopleEstimate;

  final DateTime? capturedAt;

  /// True when this was answered from the cooldown cache rather than a fresh
  /// call. Surfaced so the assistant can say "still the same as a moment ago"
  /// rather than implying it just looked again.
  final bool fromCache;

  /// True when the cloud tier was unreachable and this was assembled from the
  /// edge detector alone.
  ///
  /// The spoken text must say so. A blind user being told "there is nothing
  /// in your way" by a scan that never actually ran is the single most
  /// dangerous output this module can produce, so "could not tell" and
  /// "nothing there" are never allowed to sound the same.
  final bool degraded;

  bool get hasHazards => hazards.isNotEmpty;
}
