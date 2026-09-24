import '../../../core/localization/app_language.dart';
import 'disability_profile_enums.dart';
import 'onboarding_step.dart';
import 'saved_place.dart';
import 'trusted_contact.dart';
import 'user_role.dart';

/// The full disability/preference profile built during onboarding.
///
/// This document lives at `users/{uid}` in Firestore. Once
/// [onboardingComplete] is true, the app enters Self-Sustaining Mode: no
/// screen mutates these fields directly again — only the Gemini function
/// calling layer (chat/voice intent -> Firestore write) or the paired
/// Caretaker's remote toggles do (see Module 2 & 3).
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.role,
    this.pairedUserId,
    this.displayName = '',
    this.visionLevel = VisionLevel.full,
    this.contrastLevel = 0.5,
    this.fontScale = 1.0,
    this.mobilityAid = MobilityAid.unassisted,
    this.crowdedPlacesAnxious = false,
    this.complexInstructionsHard = false,
    this.isDeafOrHardOfHearing = false,
    this.verbosity = VerbosityLevel.descriptive,
    this.voiceId = 'bn-BD-female-1',
    this.magicButtonContacts = const [],
    this.homeAddress,
    this.safePlaceAddress,
    this.onboardingComplete = false,
    this.themePreference = ThemePreference.light,
    this.passerbyHelperMessages = const [],
    this.rememberedNotes = const [],
    this.language = AppLanguage.english,
    this.snapshotConsent = SnapshotConsentPreference.askEachTime,
    this.wakeWordEnabled = false,
    this.wakeWordThreshold,
    this.narrateOptionsFirst = true,
    this.hapticIntensity = HapticIntensity.medium,
    this.savedPlaces = const [],
    this.onboardingStep,
    bool? voiceAutoListen,
    bool? depthScanningEnabled,
    bool? autoOpenMapOnRoute,
  }) : voiceAutoListen =
           voiceAutoListen ??
           (visionLevel != VisionLevel.full || complexInstructionsHard),
       depthScanningEnabled =
           depthScanningEnabled ?? visionLevel == VisionLevel.none,
       autoOpenMapOnRoute =
           autoOpenMapOnRoute ?? visionLevel != VisionLevel.none;

  final String uid;
  final UserRole role;
  final String? pairedUserId;
  final String displayName;

  // Step 2.1 — Vision.
  final VisionLevel visionLevel;
  final double contrastLevel; // 0.0-1.0, set during Visual Calibration.
  final double fontScale; // multiplier applied via AppTheme.

  // Step 2.2 — Mobility.
  final MobilityAid mobilityAid;

  // Step 2.3 — Cognitive & anxiety thresholds.
  final bool crowdedPlacesAnxious;
  final bool complexInstructionsHard;

  // Step 2.4 — Deaf/hearing profiling.
  final bool isDeafOrHardOfHearing;

  // Step 3.1 — AI verbosity & voice.
  final VerbosityLevel verbosity;

  /// Which synthesized voice narrates the app, e.g. `en-US-female-1`.
  ///
  /// The language half must match [language]. It used to be hardcoded to
  /// `bn-BD-*` on the voice-selection screen regardless of what the user had
  /// chosen, so an English user's profile claimed a Bangla voice — confusing
  /// anywhere the value is shown or read back, and wrong the moment anything
  /// infers a language from it. Build it with [voiceIdFor].
  final String voiceId;

  // Step 3.2 — Magic Button contacts.
  final List<TrustedContact> magicButtonContacts;

  // Step 3.3 — Safe havens.
  final String? homeAddress;
  final String? safePlaceAddress;

  // Step 4 — Automation lock-in.
  final bool onboardingComplete;

  /// How far through the interview this person got, so a relaunch can put
  /// them back rather than starting over.
  ///
  /// Every answer was already being written to Firestore after every step —
  /// `ProfileService.saveProfile` says so in as many words — but nothing
  /// recorded *where* the user was, so the flow restarted at language
  /// selection and asked all of it again. Both testers reported the same
  /// thing independently, and one put it as "সব ডাটা নষ্ট হয়ে যায়": all the
  /// previous data is destroyed. From the far side of the screen that is
  /// exactly what being asked every question a second time looks like.
  ///
  /// Null on a profile written before this field existed. Those cannot say
  /// where they were, only that they got past role selection — see
  /// [OnboardingController.resumeFrom] for what is done with them.
  final OnboardingStep? onboardingStep;

  // Display theme (Module 2) — irrelevant/overridden when visionLevel is
  // VisionLevel.low, which forces the high-contrast Low Vision theme.
  final ThemePreference themePreference;

  // Passerby Helper message templates (Module 2), collected during
  // onboarding so the "Show Screen" overlay has ready-to-use options
  // tailored to this person instead of a generic default set.
  final List<String> passerbyHelperMessages;

  /// Things the user has told the assistant about themselves in passing —
  /// item 56.
  ///
  /// **Reported:** "app should work like a normal chatbot, as in how
  /// conversational chatgpt and gemini is in speak mode, remembering context
  /// and informations/preferences."
  ///
  /// The recent transcript now survives a restart (item 52) and covers the
  /// last few turns, but a conversation window is not memory: anything said
  /// nine turns ago is gone, and the things worth keeping — "I use a
  /// wheelchair", "I can't manage stairs", "my daughter picks me up on
  /// Fridays" — are exactly the things said once, in passing, and never
  /// repeated.
  ///
  /// Deliberately plain sentences rather than structured fields. The point is
  /// that the user does not have to know what the app has a field for; the
  /// onboarding answers already cover everything this app can act on
  /// mechanically, and this is for everything else.
  ///
  /// Capped at [maxRememberedNotes] — an unbounded list grows into the
  /// prompt, and a prompt that grows every turn eventually costs more than
  /// the reply.
  final List<String> rememberedNotes;

  static const int maxRememberedNotes = 20;

  // UI display language — chosen on the very first onboarding screen,
  // before role selection, since a Bangla-only reader needs to understand
  // that screen too. Independent of themePreference/voiceId.
  final AppLanguage language;

  // Step 3.4 — whether the paired Caretaker can trigger a Snapshot Request
  // (Module 6) without live per-request consent.
  final SnapshotConsentPreference snapshotConsent;

  // Module 3 — continuous on-device wake-word listening ("Hey ANT", via
  // openWakeWord). Defaults off: always-on mic capture is a real
  // battery/privacy tradeoff this app doesn't force on anyone, unlike
  // push-to-talk which every user gets regardless. See `WakeWordService`.
  final bool wakeWordEnabled;

  /// How hard "Hey Jarvis" has to be to say, as a classifier score between
  /// [WakeWordService.minThreshold] and [WakeWordService.maxThreshold].
  ///
  /// Null means "whatever this build ships with"
  /// ([WakeWordService.defaultDetectionThreshold]), which is what every
  /// profile written before the dial existed says, and what a user who has
  /// never touched it keeps saying.
  ///
  /// Stored per user rather than per device on purpose: it is a property of
  /// somebody's voice and the rooms they use the app in, not of the handset.
  /// A tester who finds their setting should not lose it to a reinstall.
  final double? wakeWordThreshold;

  /// Whether a screen reads its options out before it starts listening, or
  /// waits to be asked for them.
  ///
  /// This has been decided both ways already, which is why it is now a
  /// question rather than a constant. `OnboardingScaffold` originally deferred
  /// the list until the user said "options", so somebody who already knew
  /// their answer did not sit through a read-out; live testing reverted it,
  /// because a microphone opening in silence reads as the app "just
  /// recording" with no idea what to say. Both findings are real, and they
  /// came from different people.
  ///
  /// Defaults to reading them out. That is the current behaviour, it is the
  /// safer of the two for someone who cannot see the screen, and a user who
  /// finds it slow can say so — whereas a user left in silence has nothing to
  /// say it *to*.
  ///
  /// Either way "options"/"help"/"বিকল্প" still repeats the list mid-listen;
  /// this only decides whether it is offered unprompted.
  final bool narrateOptionsFirst;

  /// How strong the haptic patterns are — see `HapticsService`.
  ///
  /// Module 7 step 3.1 asks for this because older devices have weaker
  /// motors, and the test handset for this project is a budget Xiaomi. It cuts
  /// the other way too: a strong buzz startles, and being startled in a crowd
  /// is its own failure for a user who told onboarding that crowds make them
  /// anxious.
  final HapticIntensity hapticIntensity;

  // Whether voice mic entry points (the passerby message composer today —
  // see `PasserbyMessagePicker`) should start listening automatically
  // instead of waiting for a manual mic tap. Defaults to on for anyone
  // whose profile already signals they'd benefit most — not fully sighted,
  // or finds complex multi-step instructions hard to follow — and off for
  // everyone else; either way it's just the starting point; explicitly
  // toggled after that (My Settings, or the `voice_auto_listen` chat
  // setting) via the constructor's `voiceAutoListen` parameter, which
  // overrides the computed default and is what actually gets persisted.
  final bool voiceAutoListen;

  /// Whether the local depth model checks the ground during ambient scans.
  /// Defaults on for blind users; older profiles keep that smart default.
  final bool depthScanningEnabled;

  /// Whether a successful route automatically reveals the map.
  /// Defaults off for blind users and on for other vision profiles.
  final bool autoOpenMapOnRoute;

  /// Places this user goes to often, so "take me to work" resolves
  /// instantly — no geocoding, no language model, no follow-up question.
  /// Collected optionally during onboarding and editable afterwards by
  /// voice ("save this as my office"). See [SavedPlace].
  final List<SavedPlace> savedPlaces;

  bool get requiresVisualCalibration => visionLevel == VisionLevel.low;

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'role': role.firestoreValue,
    'pairedUserId': pairedUserId,
    'displayName': displayName,
    'visionLevel': visionLevel.name,
    'contrastLevel': contrastLevel,
    'fontScale': fontScale,
    'mobilityAid': mobilityAid.name,
    'crowdedPlacesAnxious': crowdedPlacesAnxious,
    'complexInstructionsHard': complexInstructionsHard,
    'isDeafOrHardOfHearing': isDeafOrHardOfHearing,
    'verbosity': verbosity.name,
    'voiceId': voiceId,
    'magicButtonContacts': magicButtonContacts.map((c) => c.toJson()).toList(),
    'homeAddress': homeAddress,
    'safePlaceAddress': safePlaceAddress,
    'onboardingComplete': onboardingComplete,
    'themePreference': themePreference.name,
    'passerbyHelperMessages': passerbyHelperMessages,
    'rememberedNotes': rememberedNotes,
    'language': language.name,
    'snapshotConsent': snapshotConsent.name,
    'wakeWordEnabled': wakeWordEnabled,
    'wakeWordThreshold': wakeWordThreshold,
    'narrateOptionsFirst': narrateOptionsFirst,
    'hapticIntensity': hapticIntensity.name,
    'voiceAutoListen': voiceAutoListen,
    'depthScanningEnabled': depthScanningEnabled,
    'autoOpenMapOnRoute': autoOpenMapOnRoute,
    'savedPlaces': savedPlaces.map((p) => p.toJson()).toList(),
    'onboardingStep': onboardingStep?.name,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    uid: json['uid'] as String,
    role: UserRole.fromFirestore(json['role'] as String? ?? 'disabledUser'),
    pairedUserId: json['pairedUserId'] as String?,
    displayName: json['displayName'] as String? ?? '',
    visionLevel: VisionLevel.fromFirestore(json['visionLevel'] as String?),
    contrastLevel: (json['contrastLevel'] as num?)?.toDouble() ?? 0.5,
    fontScale: (json['fontScale'] as num?)?.toDouble() ?? 1.0,
    mobilityAid: MobilityAid.fromFirestore(json['mobilityAid'] as String?),
    crowdedPlacesAnxious: json['crowdedPlacesAnxious'] as bool? ?? false,
    complexInstructionsHard: json['complexInstructionsHard'] as bool? ?? false,
    isDeafOrHardOfHearing: json['isDeafOrHardOfHearing'] as bool? ?? false,
    verbosity: VerbosityLevel.fromFirestore(json['verbosity'] as String?),
    voiceId: json['voiceId'] as String? ?? 'bn-BD-female-1',
    magicButtonContacts: (json['magicButtonContacts'] as List<dynamic>? ?? [])
        .map((c) => TrustedContact.fromJson(c as Map<String, dynamic>))
        .toList(),
    homeAddress: json['homeAddress'] as String?,
    safePlaceAddress: json['safePlaceAddress'] as String?,
    onboardingComplete: json['onboardingComplete'] as bool? ?? false,
    themePreference: ThemePreference.fromFirestore(
      json['themePreference'] as String?,
    ),
    passerbyHelperMessages:
        (json['passerbyHelperMessages'] as List<dynamic>? ?? [])
            .map((m) => m as String)
            .toList(),
    rememberedNotes: (json['rememberedNotes'] as List<dynamic>? ?? [])
        .whereType<String>()
        .toList(),
    language: AppLanguage.fromFirestore(json['language'] as String?),
    snapshotConsent: SnapshotConsentPreference.fromFirestore(
      json['snapshotConsent'] as String?,
    ),
    wakeWordEnabled: json['wakeWordEnabled'] as bool? ?? false,
    wakeWordThreshold: (json['wakeWordThreshold'] as num?)?.toDouble(),
    // Absent on every profile written before the question existed, and
    // those users have been hearing the options all along.
    narrateOptionsFirst: json['narrateOptionsFirst'] as bool? ?? true,
    hapticIntensity: HapticIntensity.fromFirestore(
      json['hapticIntensity'] as String?,
    ),
    // Not `?? false` like the others — a profile that's never had this
    // field written yet (every profile created before this field
    // existed) should still get the smart, profile-based default
    // rather than being silently opted out. `null` here is what lets
    // the constructor's own default-computation run.
    voiceAutoListen: json['voiceAutoListen'] as bool?,
    depthScanningEnabled: json['depthScanningEnabled'] as bool?,
    autoOpenMapOnRoute: json['autoOpenMapOnRoute'] as bool?,
    savedPlaces: (json['savedPlaces'] as List<dynamic>? ?? [])
        .map((p) => SavedPlace.fromJson(p as Map<String, dynamic>))
        .toList(),
    onboardingStep: _stepFromName(json['onboardingStep'] as String?),
  );

  /// Tolerant of a name this build does not have. A step removed or renamed
  /// between releases must not make the whole profile unreadable — that
  /// would lose far more than it saved.
  static OnboardingStep? _stepFromName(String? name) {
    if (name == null) return null;
    for (final step in OnboardingStep.values) {
      if (step.name == name) return step;
    }
    return null;
  }

  UserProfile copyWith({
    UserRole? role,
    String? pairedUserId,
    String? displayName,
    VisionLevel? visionLevel,
    double? contrastLevel,
    double? fontScale,
    MobilityAid? mobilityAid,
    bool? crowdedPlacesAnxious,
    bool? complexInstructionsHard,
    bool? isDeafOrHardOfHearing,
    VerbosityLevel? verbosity,
    String? voiceId,
    List<TrustedContact>? magicButtonContacts,
    String? homeAddress,
    String? safePlaceAddress,
    bool? onboardingComplete,
    ThemePreference? themePreference,
    List<String>? passerbyHelperMessages,
    List<String>? rememberedNotes,
    AppLanguage? language,
    SnapshotConsentPreference? snapshotConsent,
    bool? wakeWordEnabled,
    double? wakeWordThreshold,
    bool? narrateOptionsFirst,
    HapticIntensity? hapticIntensity,
    bool? voiceAutoListen,
    bool? depthScanningEnabled,
    bool? autoOpenMapOnRoute,
    List<SavedPlace>? savedPlaces,
    OnboardingStep? onboardingStep,
  }) => UserProfile(
    uid: uid,
    role: role ?? this.role,
    pairedUserId: pairedUserId ?? this.pairedUserId,
    displayName: displayName ?? this.displayName,
    visionLevel: visionLevel ?? this.visionLevel,
    contrastLevel: contrastLevel ?? this.contrastLevel,
    fontScale: fontScale ?? this.fontScale,
    mobilityAid: mobilityAid ?? this.mobilityAid,
    crowdedPlacesAnxious: crowdedPlacesAnxious ?? this.crowdedPlacesAnxious,
    complexInstructionsHard:
        complexInstructionsHard ?? this.complexInstructionsHard,
    isDeafOrHardOfHearing: isDeafOrHardOfHearing ?? this.isDeafOrHardOfHearing,
    verbosity: verbosity ?? this.verbosity,
    voiceId: voiceId ?? this.voiceId,
    magicButtonContacts: magicButtonContacts ?? this.magicButtonContacts,
    homeAddress: homeAddress ?? this.homeAddress,
    safePlaceAddress: safePlaceAddress ?? this.safePlaceAddress,
    onboardingComplete: onboardingComplete ?? this.onboardingComplete,
    themePreference: themePreference ?? this.themePreference,
    passerbyHelperMessages:
        passerbyHelperMessages ?? this.passerbyHelperMessages,
    rememberedNotes: rememberedNotes ?? this.rememberedNotes,
    language: language ?? this.language,
    snapshotConsent: snapshotConsent ?? this.snapshotConsent,
    wakeWordEnabled: wakeWordEnabled ?? this.wakeWordEnabled,
    wakeWordThreshold: wakeWordThreshold ?? this.wakeWordThreshold,
    narrateOptionsFirst: narrateOptionsFirst ?? this.narrateOptionsFirst,
    hapticIntensity: hapticIntensity ?? this.hapticIntensity,
    // Always resolved to a concrete value before reaching the
    // constructor (never left as a bare `null` pass-through) — this
    // preserves whatever was already persisted rather than recomputing
    // the smart default off a field that might be changing in this
    // same `copyWith` call (e.g. `visionLevel`).
    voiceAutoListen: voiceAutoListen ?? this.voiceAutoListen,
    depthScanningEnabled: depthScanningEnabled ?? this.depthScanningEnabled,
    autoOpenMapOnRoute: autoOpenMapOnRoute ?? this.autoOpenMapOnRoute,
    savedPlaces: savedPlaces ?? this.savedPlaces,
    onboardingStep: onboardingStep ?? this.onboardingStep,
  );
}

/// The voice id for [language] and gender.
///
/// One place, so the language half can never drift from the user's actual
/// choice. `CloudTtsService` only reads the gender out of this and takes the
/// language from its own parameter, which is why the mismatch went unnoticed:
/// the wrong value still produced the right voice.
/// The auto-listen default implied by the accessibility answers.
///
/// Mirrors the rule in [UserProfile]'s constructor, exposed so onboarding can
/// re-apply it when those answers change. The constructor only derives it for
/// a profile being *created*; a profile that already exists keeps whatever was
/// stored, so answering the vision question later never moved it. A user who
/// went through onboarding again — or whose profile started from the dev skip,
/// which writes false explicitly — ended up with auto-listen off despite
/// answering in a way that should have turned it on. Seen on device.
/// Whether auto-listen should be on without asking.
///
/// On for a blind user, full stop: they cannot find a mic button on a screen
/// they cannot see, so a microphone that does not open itself is a
/// microphone they do not have. Everyone else is asked during onboarding
/// (`OnboardingStep.autoListenQuestion`) rather than having it derived for
/// them — the old rule inferred it from vision level and "finds complex
/// instructions hard", which produced a setting nobody chose, sitting in
/// settings next to the wake word with no explanation of how the two
/// related. Reported as exactly that confusion: "auto listen is a weird
/// option".
bool autoListenDefaultFor({
  required VisionLevel visionLevel,
  required bool complexInstructionsHard,
}) => visionLevel == VisionLevel.none;

/// Whether onboarding should put the question to this user at all.
bool shouldAskAboutAutoListen(VisionLevel visionLevel) =>
    visionLevel != VisionLevel.none;

/// Whether to ask how options should be narrated.
///
/// Not asked of a Deaf or hard-of-hearing user: spoken guidance is switched
/// off for them the moment they say so (see `setDeafHearing`), so a question
/// about when narration happens is a question about something that does not.
bool shouldAskAboutOptionNarration({required bool isDeafOrHardOfHearing}) =>
    !isDeafOrHardOfHearing;

String voiceIdFor(AppLanguage language, {required bool female}) {
  final locale = language == AppLanguage.bangla ? 'bn-BD' : 'en-US';
  return '$locale-${female ? 'female' : 'male'}-1';
}
