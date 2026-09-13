import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/onboarding_step.dart';
import '../models/user_profile.dart';
import '../providers/onboarding_providers.dart';
import 'caretaker_pairing_screen.dart';
import 'cognitive_anxiety_screen.dart';
import 'frequent_places_screen.dart';
import 'auto_listen_screen.dart';
import 'deaf_hearing_screen.dart';
import 'language_selection_screen.dart';
import 'command_tour_screen.dart';
import 'lock_in_screen.dart';
import 'magic_button_contacts_screen.dart';
import 'mobility_question_screen.dart';
import 'onboarding_complete_screen.dart';
import 'option_narration_screen.dart';
import 'paired_confirmation_screen.dart';
import 'passerby_messages_screen.dart';
import 'role_selection_screen.dart';
import 'safe_havens_screen.dart';
import 'snapshot_consent_screen.dart';
import 'theme_preference_screen.dart';
import 'user_pairing_screen.dart';
import 'verbosity_voice_screen.dart';
import 'vision_question_screen.dart';
import 'visual_calibration_screen.dart';

/// Single host widget that switches between onboarding steps based on
/// [OnboardingController] state — keeps navigation logic in one place
/// instead of spreading named routes across go_router for a flow that is
/// inherently linear.
class OnboardingFlowScreen extends ConsumerStatefulWidget {
  const OnboardingFlowScreen({super.key, this.resumeFrom});

  /// A saved, unfinished profile for this user, if there is one — handed
  /// down by [AppRoot], which has already read it to decide that onboarding
  /// is where this launch belongs.
  ///
  /// Without this the flow always began at language selection, so someone
  /// who had answered twenty minutes of questions and then had the app
  /// killed was asked all of them over again. Both testers reported it
  /// independently and it is the one bug in the file that throws away work
  /// the user already did.
  final UserProfile? resumeFrom;

  @override
  ConsumerState<OnboardingFlowScreen> createState() => _OnboardingFlowScreenState();
}

class _OnboardingFlowScreenState extends ConsumerState<OnboardingFlowScreen> {
  @override
  void initState() {
    super.initState();
    final profile = widget.resumeFrom;
    if (profile == null) return;
    // Not in `build` — this writes provider state, and the controller's own
    // guard makes it a no-op on every call after the first anyway.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(onboardingControllerProvider.notifier).resumeFrom(profile);
    });
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(onboardingControllerProvider.select((s) => s.step));

    final screen = switch (step) {
      OnboardingStep.languageSelection => const LanguageSelectionScreen(),
      OnboardingStep.roleSelection => const RoleSelectionScreen(),
      OnboardingStep.caretakerPairing => const CaretakerPairingScreen(),
      OnboardingStep.userPairingCodeEntry => const UserPairingScreen(),
      OnboardingStep.pairedConfirmation => const PairedConfirmationScreen(),
      OnboardingStep.visionQuestion => const VisionQuestionScreen(),
      OnboardingStep.visualCalibration => const VisualCalibrationScreen(),
      OnboardingStep.themePreference => const ThemePreferenceScreen(),
      OnboardingStep.mobilityQuestion => const MobilityQuestionScreen(),
      OnboardingStep.cognitiveAnxietyQuestion => const CognitiveAnxietyScreen(),
      OnboardingStep.deafHearingQuestion => const DeafHearingScreen(),
      OnboardingStep.autoListenQuestion => const AutoListenScreen(),
      OnboardingStep.optionNarrationQuestion => const OptionNarrationScreen(),
      OnboardingStep.verbosityAndVoice => const VerbosityVoiceScreen(),
      OnboardingStep.magicButtonContacts => const MagicButtonContactsScreen(),
      OnboardingStep.passerbyMessages => const PasserbyMessagesScreen(),
      OnboardingStep.snapshotConsent => const SnapshotConsentScreen(),
      OnboardingStep.safeHavens => const SafeHavensScreen(),
      OnboardingStep.frequentPlaces => const FrequentPlacesScreen(),
      OnboardingStep.commandTour => const CommandTourScreen(),
      OnboardingStep.lockIn => const LockInScreen(),
      OnboardingStep.complete => const OnboardingCompleteScreen(),
    };

    // Deliberately not `AnimatedSwitcher` — its cross-fade keeps the
    // *outgoing* screen mounted (with its own narrate-then-listen voice
    // loop still running) for the transition's duration, which is exactly
    // what let a stale listener from the previous step still be alive when
    // the next step's own screen started speaking/listening. Confirmed
    // live as a real, user-visible bug: the previous screen's narration
    // kept audibly playing over the new screen, and its listener could
    // misfire off the new screen's own speech. A screen change here should
    // be instant, not animated — see `OnboardingScaffold.dispose` for the
    // other half of this fix (it now also stops TTS, not just STT).
    final view = KeyedSubtree(key: ValueKey(step), child: screen);

    // Android's back gesture goes back a *step*, not out of the app.
    //
    // Reported as "backbutton of caretaker code input page doesn't work", and
    // it was true of every screen in the interview, not just that one: this
    // whole flow is a single route that switches on state, so the system back
    // had nothing to pop except the route itself, and pressing it left the
    // app. Before onboarding could resume (item 26), leaving mid-interview was
    // indistinguishable from losing the lot — which is very likely part of
    // what "app data clean hoye jaay close korlei" was describing.
    //
    // The on-screen back arrow in `OnboardingScaffold` always worked; it is
    // the gesture every Android user actually reaches for that did not.
    //
    // `canPop` is true only on the very first screen, where there is no
    // previous step: refusing there would trap somebody in an app they cannot
    // leave, which is worse than the bug.
    final atStart = ref.watch(onboardingControllerProvider.select((s) => s.history.isEmpty));
    return PopScope(
      canPop: atStart,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ref.read(onboardingControllerProvider.notifier).goBack();
      },
      child: view,
    );
  }
}
