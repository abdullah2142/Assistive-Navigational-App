import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Step 4 — The Automation Lock-In.
///
/// This is the last screen with a traditional settings-style layout the
/// Disabled User will ever see. After confirming, the setup UI disappears
/// permanently: every future preference change happens through natural
/// language via the AI chat (Module 3's Gemini function-calling layer) or
/// remotely via the paired Caretaker.
class LockInScreen extends ConsumerWidget {
  const LockInScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final profile = state.profile;
    final s = Onboarding.of(profile?.language ?? state.language);

    return OnboardingScaffold(
      title: s.lockInTitle,
      subtitle: s.lockInSubtitle,
      onBack: controller.goBack,
      isLoading: state.isLoading,
      language: profile?.language ?? state.language,
      primaryActionLabel: s.lockInConfirmButton,
      onPrimaryAction: controller.confirmLockIn,
      spokenOptions: profile == null
          ? const []
          : [
              s.lockInSpokenIntro,
              '${s.lockInVisionLabel}: ${s.visionLevelLabel(profile.visionLevel)}.',
              '${s.lockInThemeLabel}: ${s.themePreferenceLabel(profile.themePreference)}.',
              '${s.lockInMobilityLabel}: ${s.mobilityAidLabel(profile.mobilityAid)}.',
              '${s.lockInDeafLabel}: ${profile.isDeafOrHardOfHearing ? s.lockInYes : s.lockInNo}.',
              '${s.lockInVerbosityLabel}: ${s.verbosityLevelLabel(profile.verbosity)}.',
              '${s.lockInContactsLabel}: ${s.lockInContactsValue(profile.magicButtonContacts.length)}.',
              '${s.lockInMessagesLabel}: ${s.lockInMessagesValue(profile.passerbyHelperMessages.length)}.',
              '${s.lockInSnapshotLabel}: ${s.snapshotConsentLabel(profile.snapshotConsent)}.',
              '${s.lockInHomeLabel}: ${profile.homeAddress ?? s.lockInHomeNotSet}.',
              s.lockInSpokenOutro,
            ],
      voiceChoices: profile == null
          ? const []
          : [
              OnboardingVoiceChoice(
                label: s.lockInConfirmButton,
                synonyms: s.lockInConfirmSynonyms,
                onSelect: controller.confirmLockIn,
              ),
            ],
      child: profile == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SummaryTile(label: s.lockInVisionLabel, value: s.visionLevelLabel(profile.visionLevel)),
                _SummaryTile(label: s.lockInThemeLabel, value: s.themePreferenceLabel(profile.themePreference)),
                _SummaryTile(label: s.lockInMobilityLabel, value: s.mobilityAidLabel(profile.mobilityAid)),
                _SummaryTile(
                  label: s.lockInDeafLabel,
                  value: profile.isDeafOrHardOfHearing ? s.lockInYes : s.lockInNo,
                ),
                _SummaryTile(label: s.lockInVerbosityLabel, value: s.verbosityLevelLabel(profile.verbosity)),
                _SummaryTile(
                  label: s.lockInContactsLabel,
                  value: s.lockInContactsValue(profile.magicButtonContacts.length),
                ),
                _SummaryTile(
                  label: s.lockInMessagesLabel,
                  value: s.lockInMessagesValue(profile.passerbyHelperMessages.length),
                ),
                _SummaryTile(label: s.lockInSnapshotLabel, value: s.snapshotConsentLabel(profile.snapshotConsent)),
                _SummaryTile(label: s.lockInHomeLabel, value: profile.homeAddress ?? s.lockInNotSet),
                if (state.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(state.errorMessage!, style: const TextStyle(color: AppColors.danger)),
                  ),
              ],
            ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        // Both sides flexible. The value used to be a bare `Text` beside an
        // `Expanded` label, which let the label claim every spare pixel and
        // squeezed the value to almost no width — a saved home address then
        // wrapped one character per line, rendering as a vertical column of
        // letters. Giving the value the larger share, and letting the label
        // shrink, is what keeps a long address on one or two normal lines.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              flex: 2,
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 3,
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
