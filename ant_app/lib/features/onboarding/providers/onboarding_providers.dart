import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../models/disability_profile_enums.dart';
import '../models/onboarding_step.dart';
import '../models/trusted_contact.dart';
import '../models/user_profile.dart';
import '../models/user_role.dart';
import '../services/auth_service.dart';
import '../services/pairing_service.dart';
import '../services/profile_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());
final pairingServiceProvider = Provider<PairingService>((ref) => PairingService());
final profileServiceProvider = Provider<ProfileService>((ref) => ProfileService());

final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges();
});

/// Live `users/{uid}` document for any uid — used by [AppRoot] for
/// role-based routing (Module 2), and by dashboards to watch either "my own"
/// profile or a paired counterpart's.
final profileStreamProvider = StreamProvider.family<UserProfile?, String>((ref, uid) {
  return ref.watch(profileServiceProvider).watchProfile(uid);
});

class OnboardingState {
  const OnboardingState({
    this.step = OnboardingStep.languageSelection,
    this.language = AppLanguage.english,
    this.profile,
    this.pairingCode,
    this.isLoading = false,
    this.errorMessage,
    this.history = const [],
    this.stepGeneration = 0,
  });

  final OnboardingStep step;

  /// Bumped every time [step] changes (see `_goTo`/`goBack`) — a screen's
  /// own voice-listening loop captures this at mount time and bails out the
  /// instant it no longer matches, even before the outgoing widget itself
  /// gets disposed (which `AnimatedSwitcher`'s cross-fade in
  /// `OnboardingFlowScreen` delays by ~250ms, long enough for a stale
  /// listener to misfire against the *next* screen's own narration — a
  /// real bug confirmed live, see `_goTo`'s doc comment).
  final int stepGeneration;

  /// Only authoritative before [profile] exists (language selection and
  /// role selection, the two screens shown pre-signin) — once a
  /// [UserProfile] is created, `profile.language` is the source of truth,
  /// baked in from this at [chooseRole] time.
  final AppLanguage language;
  final UserProfile? profile;
  final String? pairingCode;
  final bool isLoading;
  final String? errorMessage;
  final List<OnboardingStep> history;

  OnboardingState copyWith({
    OnboardingStep? step,
    AppLanguage? language,
    UserProfile? profile,
    String? pairingCode,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    List<OnboardingStep>? history,
    int? stepGeneration,
  }) =>
      OnboardingState(
        step: step ?? this.step,
        language: language ?? this.language,
        profile: profile ?? this.profile,
        pairingCode: pairingCode ?? this.pairingCode,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        history: history ?? this.history,
        stepGeneration: stepGeneration ?? this.stepGeneration,
      );
}

/// Drives the entire Module 1 flow: role selection -> pairing -> disability
/// interview -> visual calibration -> verbosity/contacts/safe-havens ->
/// automation lock-in.
class OnboardingController extends Notifier<OnboardingState> {
  StreamSubscription<String?>? _pairingSub;

  @override
  OnboardingState build() {
    ref.onDispose(() => _pairingSub?.cancel());
    return const OnboardingState();
  }

  void _goTo(OnboardingStep next) {
    // Cut off whatever mic session belongs to the step being left, right
    // now — not whenever its `OnboardingScaffold` eventually calls
    // `dispose()`. Confirmed live as a real bug without this: `KeyedSubtree`
    // inside `OnboardingFlowScreen`'s `AnimatedSwitcher` keeps the outgoing
    // screen mounted (and its own narrate-then-listen loop still running)
    // for the ~250ms cross-fade, so the previous step's mic could still be
    // open when the next step's own `OnboardingScaffold` starts its own
    // listen session — two concurrent `listenOnce()` calls on the same
    // `SttService` singleton, with the stale one able to pick up the new
    // screen's own spoken narration and misfire its `onSelect`, which is
    // exactly what produced the "Welcome to ANT" role-selection screen
    // reappearing after an option was already tapped.
    debugPrint('[Onboarding] _goTo: ${state.step} -> $next (generation ${state.stepGeneration} -> ${state.stepGeneration + 1})');
    ref.read(sttServiceProvider).stop();
    state = state.copyWith(
      step: next,
      history: [...state.history, state.step],
      clearError: true,
      stepGeneration: state.stepGeneration + 1,
    );
  }

  void goBack() {
    if (state.history.isEmpty) return;
    ref.read(sttServiceProvider).stop();
    final previous = List<OnboardingStep>.from(state.history);
    final last = previous.removeLast();
    debugPrint('[Onboarding] goBack: ${state.step} -> $last (generation ${state.stepGeneration} -> ${state.stepGeneration + 1})');
    state = state.copyWith(
      step: last,
      history: previous,
      clearError: true,
      stepGeneration: state.stepGeneration + 1,
    );
  }

  void setLanguage(AppLanguage language) {
    state = state.copyWith(language: language);
    _goTo(OnboardingStep.roleSelection);
  }

  /// Stops whatever the *current* screen has listening/speaking, right now
  /// — not whenever `_goTo` eventually runs. Confirmed live as a real,
  /// recurring bug without this: nearly every controller method here does
  /// an async Firestore write (`_persist`, `ensureSignedIn`, `redeemCode`,
  /// `generateCode`) *before* calling `_goTo`, so the outgoing screen
  /// stayed fully mounted — mic still open, its own retry/auto-help logic
  /// still free to fire — for the entire round trip. A stale listener
  /// re-narrating (or worse, re-matching) the screen the user just left is
  /// exactly what looked like "the previous screen briefly reappearing"
  /// right before the real navigation happened. `_goTo`'s own `stop()`
  /// remains too (it also covers `setLanguage`/`skipPairing`, which have no
  /// async gap before it), but it's too late on its own for anything that
  /// awaits first.
  void _stopCurrentScreenVoice() {
    ref.read(sttServiceProvider).stop();
    ref.read(ttsServiceProvider).stop();
  }

  Future<void> chooseRole(UserRole role) async {
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await ref.read(authServiceProvider).ensureSignedIn();
      final profile = UserProfile(uid: user.uid, role: role, language: state.language);
      await ref.read(profileServiceProvider).saveProfile(profile);
      state = state.copyWith(profile: profile, isLoading: false);

      if (role == UserRole.caretaker) {
        await _startCaretakerPairing(user.uid);
      } else {
        _goTo(OnboardingStep.userPairingCodeEntry);
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  Future<void> _startCaretakerPairing(String uid) async {
    try {
      final code = await ref.read(pairingServiceProvider).generateCode(caretakerUid: uid);
      state = state.copyWith(pairingCode: code);
      _goTo(OnboardingStep.caretakerPairing);

      _pairingSub?.cancel();
      _pairingSub = ref.read(pairingServiceProvider).watchClaimedBy(code).listen((claimedByUid) {
        if (claimedByUid != null) {
          state = state.copyWith(
            profile: state.profile?.copyWith(pairedUserId: claimedByUid),
          );
          _goTo(OnboardingStep.pairedConfirmation);
          _pairingSub?.cancel();
        }
      });
    } catch (e) {
      state = state.copyWith(errorMessage: e.toString());
    }
  }

  Future<void> submitPairingCode(String code) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final caretakerUid =
          await ref.read(pairingServiceProvider).redeemCode(code: code, disabledUserUid: profile.uid);
      final updated = profile.copyWith(pairedUserId: caretakerUid);
      await ref.read(profileServiceProvider).saveProfile(updated);
      state = state.copyWith(profile: updated, isLoading: false);
      _goTo(OnboardingStep.visionQuestion);
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }

  /// Some Disabled Users don't have a caretaker at all. They can still use
  /// every safety feature that doesn't depend on one (Magic Button contacts,
  /// hazard detection, safe havens) — `pairedUserId` just stays null.
  /// Pairing can always be completed later via the AI chat (Module 3).
  void skipPairing() {
    _goTo(OnboardingStep.visionQuestion);
  }

  // Deliberately does NOT stop STT/TTS itself — `addContact`/`removeContact`
  // also route through this and, unlike every other caller, don't navigate
  // away afterward (they're called mid-flow by the contacts screen's own
  // voice loop, which immediately starts its *own* next `listenOnce()`
  // right after). Stopping the mic here would race that next listen
  // attempt. Every navigating caller below calls `_stopCurrentScreenVoice()`
  // itself, before this.
  Future<void> _persist(UserProfile updated) async {
    state = state.copyWith(profile: updated);
    await ref.read(profileServiceProvider).saveProfile(updated);
  }

  Future<void> setVisionLevel(VisionLevel level) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    // A fully blind user can't see which theme is active and gets no
    // benefit from being asked — default them straight to Dark (real
    // battery savings on the OLED panels most phones here ship with) and
    // skip the now-pointless question entirely, same as Low Vision
    // skipping past it in the other direction. Still just a starting
    // point: changeable later via My Settings or "change theme to light".
    final updated = level == VisionLevel.none
        ? profile.copyWith(visionLevel: level, themePreference: ThemePreference.dark)
        : profile.copyWith(visionLevel: level);
    await _persist(updated);
    // Low Vision still gets a Light/Dark say — it's an independent
    // accessibility axis, not a fixed theme substituted in its place (see
    // theme_resolver.dart) — so it's only None that skips themePreference,
    // Low Vision users detour through calibration first and still reach it.
    _goTo(switch (level) {
      VisionLevel.low => OnboardingStep.visualCalibration,
      VisionLevel.none => OnboardingStep.mobilityQuestion,
      VisionLevel.full => OnboardingStep.themePreference,
    });
  }

  Future<void> setCalibration({required double contrastLevel, required double fontScale}) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(contrastLevel: contrastLevel, fontScale: fontScale));
    _goTo(OnboardingStep.themePreference);
  }

  Future<void> setThemePreference(ThemePreference preference) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(themePreference: preference));
    _goTo(OnboardingStep.mobilityQuestion);
  }

  Future<void> setMobilityAid(MobilityAid aid) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(mobilityAid: aid));
    _goTo(OnboardingStep.cognitiveAnxietyQuestion);
  }

  Future<void> setCognitiveAnxiety({
    required bool crowdedPlacesAnxious,
    required bool complexInstructionsHard,
  }) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(
      crowdedPlacesAnxious: crowdedPlacesAnxious,
      complexInstructionsHard: complexInstructionsHard,
    ));
    _goTo(OnboardingStep.deafHearingQuestion);
  }

  Future<void> setDeafHearing(bool isDeafOrHardOfHearing) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(isDeafOrHardOfHearing: isDeafOrHardOfHearing));
    // Spoken onboarding guidance defaults on for Visually Impaired users with
    // no one to read the screen for them (see ttsEnabledProvider) — but it's
    // useless noise for someone who can't hear it, so switch it off the
    // moment we know that's the case.
    if (isDeafOrHardOfHearing) {
      ref.read(ttsServiceProvider).stop();
      ref.read(ttsEnabledProvider.notifier).state = false;
    }
    _goTo(OnboardingStep.verbosityAndVoice);
  }

  Future<void> setVerbosityAndVoice({required VerbosityLevel verbosity, required String voiceId}) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(verbosity: verbosity, voiceId: voiceId));
    // Applied immediately, not just persisted — every onboarding screen from
    // here on narrates with the voice just picked instead of the default.
    ref.read(ttsServiceProvider).setVoiceId(voiceId);
    _goTo(OnboardingStep.magicButtonContacts);
  }

  Future<void> addContact(TrustedContact contact) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(magicButtonContacts: [...profile.magicButtonContacts, contact]));
  }

  Future<void> removeContact(int index) async {
    final profile = state.profile;
    if (profile == null) return;
    final updated = List<TrustedContact>.from(profile.magicButtonContacts)..removeAt(index);
    await _persist(profile.copyWith(magicButtonContacts: updated));
  }

  void continueFromContacts() {
    if ((state.profile?.magicButtonContacts.length ?? 0) < 1) {
      state = state.copyWith(
        errorMessage: Onboarding.of(state.profile!.language).contactsErrorAtLeastOne,
      );
      return;
    }
    _goTo(OnboardingStep.passerbyMessages);
  }

  Future<void> setPasserbyHelperMessages(List<String> messages) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(passerbyHelperMessages: messages));
    _goTo(OnboardingStep.snapshotConsent);
  }

  Future<void> setSnapshotConsent(SnapshotConsentPreference preference) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(snapshotConsent: preference));
    _goTo(OnboardingStep.safeHavens);
  }

  Future<void> setSafeHavens({required String homeAddress, String? safePlaceAddress}) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(homeAddress: homeAddress, safePlaceAddress: safePlaceAddress));
    _goTo(OnboardingStep.lockIn);
  }

  /// Caretaker-side equivalent of [confirmLockIn] — there is no disability
  /// interview for this role, pairing is the entire Module 1 flow. Must
  /// still persist `onboardingComplete: true`, the same field [AppRoot]
  /// (Module 2) checks for both roles to decide whether to skip straight to
  /// a dashboard on a later launch.
  Future<void> finishCaretakerSetup() async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    await _persist(profile.copyWith(onboardingComplete: true));
    _goTo(OnboardingStep.complete);
  }

  Future<void> confirmLockIn() async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _persist(profile.copyWith(onboardingComplete: true));
      state = state.copyWith(isLoading: false);
      _goTo(OnboardingStep.complete);
    } catch (e) {
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    }
  }
}

final onboardingControllerProvider = NotifierProvider<OnboardingController, OnboardingState>(
  OnboardingController.new,
);
