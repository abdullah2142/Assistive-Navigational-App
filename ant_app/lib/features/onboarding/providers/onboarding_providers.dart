import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

class OnboardingState {
  const OnboardingState({
    this.step = OnboardingStep.roleSelection,
    this.profile,
    this.pairingCode,
    this.isLoading = false,
    this.errorMessage,
    this.history = const [],
  });

  final OnboardingStep step;
  final UserProfile? profile;
  final String? pairingCode;
  final bool isLoading;
  final String? errorMessage;
  final List<OnboardingStep> history;

  OnboardingState copyWith({
    OnboardingStep? step,
    UserProfile? profile,
    String? pairingCode,
    bool? isLoading,
    String? errorMessage,
    bool clearError = false,
    List<OnboardingStep>? history,
  }) =>
      OnboardingState(
        step: step ?? this.step,
        profile: profile ?? this.profile,
        pairingCode: pairingCode ?? this.pairingCode,
        isLoading: isLoading ?? this.isLoading,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        history: history ?? this.history,
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
    state = state.copyWith(
      step: next,
      history: [...state.history, state.step],
      clearError: true,
    );
  }

  void goBack() {
    if (state.history.isEmpty) return;
    final previous = List<OnboardingStep>.from(state.history);
    final last = previous.removeLast();
    state = state.copyWith(step: last, history: previous, clearError: true);
  }

  Future<void> chooseRole(UserRole role) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await ref.read(authServiceProvider).ensureSignedIn();
      final profile = UserProfile(uid: user.uid, role: role);
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

  Future<void> _persist(UserProfile updated) async {
    state = state.copyWith(profile: updated);
    await ref.read(profileServiceProvider).saveProfile(updated);
  }

  Future<void> setVisionLevel(VisionLevel level) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(visionLevel: level));
    _goTo(level == VisionLevel.low ? OnboardingStep.visualCalibration : OnboardingStep.mobilityQuestion);
  }

  Future<void> setCalibration({required double contrastLevel, required double fontScale}) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(contrastLevel: contrastLevel, fontScale: fontScale));
    _goTo(OnboardingStep.mobilityQuestion);
  }

  Future<void> setMobilityAid(MobilityAid aid) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(mobilityAid: aid));
    _goTo(OnboardingStep.cognitiveAnxietyQuestion);
  }

  Future<void> setCognitiveAnxiety({
    required bool crowdedPlacesAnxious,
    required bool complexInstructionsHard,
  }) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(
      crowdedPlacesAnxious: crowdedPlacesAnxious,
      complexInstructionsHard: complexInstructionsHard,
    ));
    _goTo(OnboardingStep.deafHearingQuestion);
  }

  Future<void> setDeafHearing(bool isDeafOrHardOfHearing) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(isDeafOrHardOfHearing: isDeafOrHardOfHearing));
    _goTo(OnboardingStep.verbosityAndVoice);
  }

  Future<void> setVerbosityAndVoice({required VerbosityLevel verbosity, required String voiceId}) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(verbosity: verbosity, voiceId: voiceId));
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
        errorMessage: 'Please add at least one trusted contact for the Magic Button to work.',
      );
      return;
    }
    _goTo(OnboardingStep.safeHavens);
  }

  Future<void> setSafeHavens({required String homeAddress, String? safePlaceAddress}) async {
    final profile = state.profile;
    if (profile == null) return;
    await _persist(profile.copyWith(homeAddress: homeAddress, safePlaceAddress: safePlaceAddress));
    _goTo(OnboardingStep.lockIn);
  }

  /// Caretaker-side equivalent of [confirmLockIn] — there is no disability
  /// interview for this role, pairing is the entire Module 1 flow.
  void finishCaretakerSetup() {
    _goTo(OnboardingStep.complete);
  }

  Future<void> confirmLockIn() async {
    final profile = state.profile;
    if (profile == null) return;
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
