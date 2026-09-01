import '../../../core/localization/app_language.dart';
import 'disability_profile_enums.dart';
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
    this.language = AppLanguage.english,
    this.snapshotConsent = SnapshotConsentPreference.askEachTime,
  });

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
  final String voiceId;

  // Step 3.2 — Magic Button contacts.
  final List<TrustedContact> magicButtonContacts;

  // Step 3.3 — Safe havens.
  final String? homeAddress;
  final String? safePlaceAddress;

  // Step 4 — Automation lock-in.
  final bool onboardingComplete;

  // Display theme (Module 2) — irrelevant/overridden when visionLevel is
  // VisionLevel.low, which forces the high-contrast Low Vision theme.
  final ThemePreference themePreference;

  // Passerby Helper message templates (Module 2), collected during
  // onboarding so the "Show Screen" overlay has ready-to-use options
  // tailored to this person instead of a generic default set.
  final List<String> passerbyHelperMessages;

  // UI display language — chosen on the very first onboarding screen,
  // before role selection, since a Bangla-only reader needs to understand
  // that screen too. Independent of themePreference/voiceId.
  final AppLanguage language;

  // Step 3.4 — whether the paired Caretaker can trigger a Snapshot Request
  // (Module 6) without live per-request consent.
  final SnapshotConsentPreference snapshotConsent;

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
        'language': language.name,
        'snapshotConsent': snapshotConsent.name,
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
        themePreference: ThemePreference.fromFirestore(json['themePreference'] as String?),
        passerbyHelperMessages:
            (json['passerbyHelperMessages'] as List<dynamic>? ?? []).map((m) => m as String).toList(),
        language: AppLanguage.fromFirestore(json['language'] as String?),
        snapshotConsent: SnapshotConsentPreference.fromFirestore(json['snapshotConsent'] as String?),
      );

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
    AppLanguage? language,
    SnapshotConsentPreference? snapshotConsent,
  }) =>
      UserProfile(
        uid: uid,
        role: role ?? this.role,
        pairedUserId: pairedUserId ?? this.pairedUserId,
        displayName: displayName ?? this.displayName,
        visionLevel: visionLevel ?? this.visionLevel,
        contrastLevel: contrastLevel ?? this.contrastLevel,
        fontScale: fontScale ?? this.fontScale,
        mobilityAid: mobilityAid ?? this.mobilityAid,
        crowdedPlacesAnxious: crowdedPlacesAnxious ?? this.crowdedPlacesAnxious,
        complexInstructionsHard: complexInstructionsHard ?? this.complexInstructionsHard,
        isDeafOrHardOfHearing: isDeafOrHardOfHearing ?? this.isDeafOrHardOfHearing,
        verbosity: verbosity ?? this.verbosity,
        voiceId: voiceId ?? this.voiceId,
        magicButtonContacts: magicButtonContacts ?? this.magicButtonContacts,
        homeAddress: homeAddress ?? this.homeAddress,
        safePlaceAddress: safePlaceAddress ?? this.safePlaceAddress,
        onboardingComplete: onboardingComplete ?? this.onboardingComplete,
        themePreference: themePreference ?? this.themePreference,
        passerbyHelperMessages: passerbyHelperMessages ?? this.passerbyHelperMessages,
        language: language ?? this.language,
        snapshotConsent: snapshotConsent ?? this.snapshotConsent,
      );
}
