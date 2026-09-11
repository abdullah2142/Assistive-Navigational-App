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
import '../models/saved_place.dart';
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
    this.voiceRearmToken = 0,
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

  /// Bumped when a step *fails* and the user is being left on it.
  ///
  /// [stepGeneration] is a one-way cancel — once a screen's voice loop sees
  /// it change it exits for good, which is correct when we're leaving that
  /// screen but wrong when we aren't. `_stopCurrentScreenVoice` bumps the
  /// generation the moment a navigating method starts, so a save that then
  /// throws would otherwise leave a fully-mounted screen with no voice at
  /// all — and onboarding errors are only ever *shown*, never spoken, so a
  /// blind user would be stuck on a silent dead end with no idea why.
  /// Screens re-arm their narrate-then-listen loop when this changes.
  final int voiceRearmToken;

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
    int? voiceRearmToken,
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
        voiceRearmToken: voiceRearmToken ?? this.voiceRearmToken,
      );
}

/// Drives the entire Module 1 flow: role selection -> pairing -> disability
/// interview -> visual calibration -> verbosity/contacts/safe-havens ->
/// automation lock-in.
class OnboardingController extends Notifier<OnboardingState> {
  StreamSubscription<String?>? _pairingSub;

  /// Whether a saved profile has already been adopted this session, so a
  /// rebuild of the flow screen cannot throw the user back to where they
  /// launched from after they have moved on from it.
  bool _resumed = false;

  @override
  OnboardingState build() {
    ref.onDispose(() => _pairingSub?.cancel());
    return const OnboardingState();
  }

  /// Puts someone who left mid-interview back where they were.
  ///
  /// Called by [OnboardingFlowScreen] when the app launches onto a profile
  /// that exists but is not finished. Everything the user answered is
  /// already in that profile — it was written after every step — so this
  /// only has to restore *position*, which is the one thing nothing was
  /// recording. See [UserProfile.onboardingStep].
  void resumeFrom(UserProfile profile) {
    if (_resumed || profile.onboardingComplete) return;
    _resumed = true;

    // A profile written before the step was recorded can say only that this
    // person got past role selection, so that is where they go back to.
    // Cheap now, and no longer destructive: `chooseRole` merges into what is
    // already saved rather than overwriting it.
    final step = profile.onboardingStep ?? OnboardingStep.roleSelection;
    debugPrint('[Onboarding] resuming ${profile.uid} at $step '
        '(recorded: ${profile.onboardingStep})');

    state = OnboardingState(
      step: step,
      language: profile.language,
      profile: profile,
    );

    // The pairing screen shows a code that only ever existed in memory, and
    // the claim it waits on is a live subscription. Resuming onto it with
    // neither would be a screen displaying nothing, waiting for nothing, so
    // the pairing is started again from scratch — which also re-enters the
    // step through `_goTo` and gets the history and generation right.
    if (step == OnboardingStep.caretakerPairing) {
      unawaited(_startCaretakerPairing(profile.uid));
    }
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
      profile: state.profile?.copyWith(onboardingStep: next),
    );
    _rememberStep(next);
  }

  /// Writes just the step the user has reached, so a kill between here and
  /// their next answer resumes on the right screen instead of at the start.
  ///
  /// Deliberately not awaited and deliberately its own single-field write.
  /// Navigation is synchronous and must stay that way — making every step
  /// change wait on Firestore would put a network round trip between a tap
  /// and the screen it opens. And because it touches no field [_persist]
  /// writes, the two cannot clobber each other whichever order they land
  /// in; every caller persists the answer first and navigates second, so
  /// the step is always the later write anyway.
  ///
  /// A failure here is not worth surfacing: the cost is resuming a step
  /// earlier than the user actually got to, which is the behaviour they
  /// have today for every step.
  void _rememberStep(OnboardingStep step) {
    final profile = state.profile;
    if (profile == null) return;
    unawaited(
      ref.read(profileServiceProvider).saveOnboardingStep(uid: profile.uid, step: step).catchError(
            (Object e) => debugPrint('[Onboarding] could not record step $step: $e'),
          ),
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
      profile: state.profile?.copyWith(onboardingStep: last),
    );
    _rememberStep(last);
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
    // Bumping the cancellation token matters as much as stopping the
    // devices, and was the missing half of this fix. Stopping the mic ends
    // the current `listenOnce`, but it does not end the *loop* around it:
    // that loop sees a session that returned nothing, reads it as "the user
    // said something I couldn't match", speaks the retry hint, re-reads the
    // whole option list after two such misses, and opens the mic again —
    // all while we're still awaiting the Firestore write, because `_goTo`
    // (the only other thing that bumps the generation) hasn't run yet.
    //
    // Confirmed by a reproducing widget test: answering a question by
    // *tapping* it left the screen narrating its own title and options
    // again straight afterwards, which for a user who can't see the screen
    // is indistinguishable from that screen coming back — the reported
    // "duplicate Welcome to ANT screen".
    debugPrint('[Onboarding] _stopCurrentScreenVoice: cancelling voice for '
        'generation ${state.stepGeneration}');
    state = state.copyWith(stepGeneration: state.stepGeneration + 1);
  }

  /// Records a failure and hands the current screen's voice back to it.
  ///
  /// Every caller of [_stopCurrentScreenVoice] that can throw must end up
  /// here, or the cancellation above becomes permanent for a screen we
  /// never actually left. See [OnboardingState.voiceRearmToken].
  void _failCurrentStep(Object error) {
    debugPrint('[Onboarding] step failed, re-arming screen voice: $error');
    state = state.copyWith(
      isLoading: false,
      errorMessage: error.toString(),
      voiceRearmToken: state.voiceRearmToken + 1,
    );
  }

  Future<void> chooseRole(UserRole role) async {
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await ref.read(authServiceProvider).ensureSignedIn();
      // Whatever this uid already answered, if anything.
      //
      // `ensureSignedIn` returns the *existing* anonymous user on a relaunch,
      // so this uid can already own a half-finished profile — and building a
      // fresh `UserProfile` here wrote every default it has straight over it
      // through `SetOptions(merge: true)`. Vision level, mobility aid,
      // contacts, safe havens: all of it back to defaults, in Firestore, not
      // merely re-asked. That is the literal half of "সব ডাটা নষ্ট হয়ে যায়" —
      // the data really was destroyed, and by the app's own second screen.
      //
      // A failed read must not take the same path. Falling back to a blank
      // profile on an error is how the destructive version behaved, so a
      // transient Firestore hiccup would quietly wipe a finished interview.
      // Let it throw to [_failCurrentStep] instead: the user is told, and
      // their answers are still there to come back to.
      final existing = await ref.read(profileServiceProvider).fetchProfile(user.uid);
      final profile = existing == null
          ? UserProfile(uid: user.uid, role: role, language: state.language)
          : existing.copyWith(role: role, language: state.language);
      await ref.read(profileServiceProvider).saveProfile(profile);
      state = state.copyWith(profile: profile, isLoading: false);

      if (role == UserRole.caretaker) {
        await _startCaretakerPairing(user.uid);
      } else {
        _goTo(OnboardingStep.userPairingCodeEntry);
      }
    } catch (e) {
      _failCurrentStep(e);
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
      _failCurrentStep(e);
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
      _failCurrentStep(e);
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
  ///
  /// Returns whether the write actually succeeded. Callers must check it
  /// and bail rather than navigating on regardless: every one of these used
  /// to `await` this with no error handling at all, so an offline or
  /// permission-denied write threw straight past them into the framework as
  /// an unhandled async error — the step silently never advanced, nothing
  /// was shown, and nothing was spoken. That is exactly the crash-instead-
  /// of-degrade behaviour `ai_developer_prompt.md`'s "Graceful Offline
  /// Degradation" rule exists to prevent. Failure now routes through
  /// [_failCurrentStep], which surfaces the error and re-arms the screen's
  /// voice so the user can hear what happened and retry.
  Future<bool> _persist(UserProfile updated) async {
    state = state.copyWith(profile: updated);
    try {
      await ref.read(profileServiceProvider).saveProfile(updated);
      return true;
    } catch (e) {
      _failCurrentStep(e);
      return false;
    }
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
    // Auto-listen is derived from the vision level, and re-derived here for
    // the same reason it is in setCognitiveAnxiety: the constructor's rule
    // only runs for a profile being created, so answering this question on a
    // profile that already exists never moved the setting.
    final autoListen = autoListenDefaultFor(
      visionLevel: level,
      complexInstructionsHard: profile.complexInstructionsHard,
    );
    final updated = level == VisionLevel.none
        ? profile.copyWith(
            visionLevel: level,
            themePreference: ThemePreference.dark,
            voiceAutoListen: autoListen,
          )
        : profile.copyWith(visionLevel: level, voiceAutoListen: autoListen);
    if (!await _persist(updated)) return;
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
    if (!await _persist(profile.copyWith(contrastLevel: contrastLevel, fontScale: fontScale))) return;
    _goTo(OnboardingStep.themePreference);
  }

  Future<void> setThemePreference(ThemePreference preference) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(themePreference: preference))) return;
    _goTo(OnboardingStep.mobilityQuestion);
  }

  Future<void> setMobilityAid(MobilityAid aid) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(mobilityAid: aid))) return;
    _goTo(OnboardingStep.cognitiveAnxietyQuestion);
  }

  Future<void> setCognitiveAnxiety({
    required bool crowdedPlacesAnxious,
    required bool complexInstructionsHard,
  }) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    final saved = await _persist(profile.copyWith(
      crowdedPlacesAnxious: crowdedPlacesAnxious,
      complexInstructionsHard: complexInstructionsHard,
      // Re-derived, because this answer is one of its two inputs and the
      // constructor only applies the rule to a profile being created.
      voiceAutoListen: autoListenDefaultFor(
        visionLevel: profile.visionLevel,
        complexInstructionsHard: complexInstructionsHard,
      ),
    ));
    if (!saved) return;
    _goTo(OnboardingStep.deafHearingQuestion);
  }

  Future<void> setDeafHearing(bool isDeafOrHardOfHearing) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(isDeafOrHardOfHearing: isDeafOrHardOfHearing))) return;
    // Spoken onboarding guidance defaults on for Visually Impaired users with
    // no one to read the screen for them (see ttsEnabledProvider) — but it's
    // useless noise for someone who can't hear it, so switch it off the
    // moment we know that's the case.
    if (isDeafOrHardOfHearing) {
      ref.read(ttsServiceProvider).stop();
      ref.read(ttsEnabledProvider.notifier).state = false;
    }
    // Blind users are not asked about auto-listen — it is already on for
    // them, because a microphone that does not open itself is one they
    // cannot reach. See `autoListenDefaultFor`.
    _goTo(shouldAskAboutAutoListen(profile.visionLevel)
        ? OnboardingStep.autoListenQuestion
        : OnboardingStep.verbosityAndVoice);
  }

  /// The answer to `OnboardingStep.autoListenQuestion`.
  Future<void> setAutoListen(bool enabled) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(voiceAutoListen: enabled))) return;
    _goTo(OnboardingStep.verbosityAndVoice);
  }

  Future<void> setVerbosityAndVoice({required VerbosityLevel verbosity, required String voiceId}) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(verbosity: verbosity, voiceId: voiceId))) return;
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
        voiceRearmToken: state.voiceRearmToken + 1,
      );
      return;
    }
    _goTo(OnboardingStep.passerbyMessages);
  }

  Future<void> setPasserbyHelperMessages(List<String> messages) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(passerbyHelperMessages: messages))) return;
    _goTo(OnboardingStep.snapshotConsent);
  }

  Future<void> setSnapshotConsent(SnapshotConsentPreference preference) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(snapshotConsent: preference))) return;
    _goTo(OnboardingStep.safeHavens);
  }

  Future<void> setSafeHavens({required String homeAddress, String? safePlaceAddress}) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    if (!await _persist(profile.copyWith(homeAddress: homeAddress, safePlaceAddress: safePlaceAddress))) return;
    _goTo(OnboardingStep.frequentPlaces);
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
    if (!await _persist(profile.copyWith(onboardingComplete: true))) return;
    _goTo(OnboardingStep.complete);
  }

  /// Optional — the whole step can be skipped with an empty list.
  ///
  /// Saved places are a convenience, not a requirement, and a user part-way
  /// through a long accessibility interview should not be made to invent
  /// destinations to get past a screen. They can add them later by just
  /// saying "save this as my office" while standing there, which is a
  /// better moment to capture one anyway.
  Future<void> setFrequentPlaces(List<SavedPlace> places) async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    final routable = places.where((p) => p.isRoutable).toList();
    if (!await _persist(profile.copyWith(savedPlaces: routable))) return;
    _goTo(OnboardingStep.commandTour);
  }

  /// Re-narrates the command tour.
  ///
  /// Bumping the generation is what re-runs it: the scaffold speaks on
  /// entering a step, so "hear it again" is the same thing as arriving
  /// again. Nothing is persisted — this screen collects no answer.
  void repeatCommandTour() {
    _stopCurrentScreenVoice();
    _goTo(OnboardingStep.commandTour);
  }

  /// Leaves the command tour for the final review.
  ///
  /// Nothing to save: this step teaches rather than asks, so it has no
  /// answer to persist and cannot fail.
  void finishCommandTour() {
    _stopCurrentScreenVoice();
    _goTo(OnboardingStep.lockIn);
  }

  /// **Development only.** Signs in, writes a complete dummy profile, and
  /// drops straight to the dashboard.
  ///
  /// Onboarding is deliberately long — it is a full accessibility interview
  /// with voice narration at every step — which makes it a real obstacle
  /// when the thing being tested is the dashboard. This skips it.
  ///
  /// Guarded by [kDebugMode] at both ends: the button that calls it is not
  /// built in a release binary, and this method refuses to run in one even
  /// if something else calls it. Two gates rather than one, because a
  /// backdoor that silently fabricates a disability profile and marks
  /// onboarding complete is not something to leave one edit away from
  /// shipping.
  ///
  /// The values are chosen to make the dashboard immediately *useful*, not
  /// merely valid — real Dhaka coordinates on the saved places so
  /// "take me to work" routes on the first try, and contacts/messages
  /// populated so the Magic Button and Passerby surfaces have something to
  /// show.
  Future<void> devSkipOnboarding() async {
    if (!kDebugMode) {
      debugPrint('[Onboarding] devSkipOnboarding ignored — not a debug build.');
      return;
    }
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final user = await ref.read(authServiceProvider).ensureSignedIn();
      // `role` is immutable once the profile exists — `firestore.rules`
      // rejects any update that changes it, because a verified custom claim
      // is minted from it by `onUserRoleWritten`. So the existing role is
      // read and kept rather than assumed.
      //
      // Assuming it was the live bug: this shortcut wrote
      // `role: disabledUser` unconditionally, which meant that for anyone
      // whose profile already existed as a Caretaker, dev-skip was
      // *guaranteed* to fail with `permission-denied` — the exact error
      // seen on device. It presents as a mysterious intermittent failure
      // rather than an obvious one because it depends entirely on what the
      // last run of the app happened to leave behind.
      final existing = await ref.read(profileServiceProvider).fetchProfile(user.uid);
      final profile = _dummyProfile(user.uid, state.language)
          .copyWith(role: existing?.role, pairedUserId: existing?.pairedUserId);
      // Written to Firestore rather than only held in memory, because
      // `AppRoot` routes off the persisted profile — an in-memory shortcut
      // would bounce straight back to onboarding on the next rebuild.
      await ref.read(profileServiceProvider).saveProfile(profile);
      ref.read(ttsServiceProvider).setVoiceId(profile.voiceId);
      state = state.copyWith(profile: profile, isLoading: false, step: OnboardingStep.complete);
      debugPrint('[Onboarding] devSkipOnboarding: wrote dummy profile for ${user.uid}');
    } catch (e) {
      _failCurrentStep(e);
    }
  }

  /// Exposed only so tests can assert the shortcut produces a profile that
  /// is genuinely usable, not merely well-formed.
  @visibleForTesting
  UserProfile debugDummyProfile(String uid, AppLanguage language) => _dummyProfile(uid, language);

  UserProfile _dummyProfile(String uid, AppLanguage language) => UserProfile(
        uid: uid,
        role: UserRole.disabledUser,
        language: language,
        displayName: 'Test User',
        // The app's primary user. Also the most demanding path — full
        // narration, dark theme, voice-first everything — so anything
        // tested against this profile is tested against the hard case.
        visionLevel: VisionLevel.none,
        mobilityAid: MobilityAid.whiteCane,
        verbosity: VerbosityLevel.descriptive,
        crowdedPlacesAnxious: true,
        complexInstructionsHard: false,
        isDeafOrHardOfHearing: false,
        themePreference: ThemePreference.dark,
        snapshotConsent: SnapshotConsentPreference.askEachTime,
        magicButtonContacts: const [
          TrustedContact(name: 'Ma', phoneNumber: '01711111111', relationship: 'Mother', isPrimary: true),
          TrustedContact(name: 'Rakib', phoneNumber: '01822222222', relationship: 'Brother'),
        ],
        homeAddress: 'House 12, Road 5, Dhanmondi, Dhaka',
        safePlaceAddress: 'Dhanmondi 27 pharmacy',
        passerbyHelperMessages: Onboarding.of(language).defaultPasserbyMessages,
        // Real coordinates, so routing and turn-by-turn work on the first
        // try instead of needing a geocode that may not resolve.
        savedPlaces: const [
          SavedPlace(label: 'work', kind: SavedPlaceKind.work, address: 'Gulshan 1, Dhaka', lat: 23.7808, lng: 90.4142),
          SavedPlace(label: 'school', kind: SavedPlaceKind.school, address: 'Dhanmondi, Dhaka', lat: 23.7461, lng: 90.3742),
          SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'Mirpur 10, Dhaka', lat: 23.8069, lng: 90.3687),
        ],
        // Both off deliberately. A profile with no vision computes
        // `voiceAutoListen: true`, which reopens the microphone after every
        // utterance — correct for a real blind user, and constant
        // interference when the point is to poke at the dashboard. Flip
        // either back on from My Settings when that is what is being
        // tested.
        wakeWordEnabled: false,
        voiceAutoListen: false,
        onboardingComplete: true,
      );

  Future<void> confirmLockIn() async {
    final profile = state.profile;
    if (profile == null) return;
    _stopCurrentScreenVoice();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      if (!await _persist(profile.copyWith(onboardingComplete: true))) return;
      state = state.copyWith(isLoading: false);
      _goTo(OnboardingStep.complete);
    } catch (e) {
      _failCurrentStep(e);
    }
  }
}

final onboardingControllerProvider = NotifierProvider<OnboardingController, OnboardingState>(
  OnboardingController.new,
);
