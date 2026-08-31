import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

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

    return OnboardingScaffold(
      title: 'You\'re all set',
      subtitle: 'Once you confirm, this setup screen goes away for good. To change anything later, '
          'just tell the AI — for example, say "Change my emergency contact to Mom."',
      onBack: controller.goBack,
      isLoading: state.isLoading,
      primaryActionLabel: 'Confirm and start using ANT',
      onPrimaryAction: controller.confirmLockIn,
      child: profile == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _SummaryTile(label: 'Vision', value: profile.visionLevel.name),
                _SummaryTile(label: 'Mobility', value: profile.mobilityAid.name),
                _SummaryTile(
                  label: 'Deaf / hard of hearing',
                  value: profile.isDeafOrHardOfHearing ? 'Yes' : 'No',
                ),
                _SummaryTile(label: 'AI verbosity', value: profile.verbosity.name),
                _SummaryTile(
                  label: 'Trusted contacts',
                  value: '${profile.magicButtonContacts.length} added',
                ),
                _SummaryTile(label: 'Home address', value: profile.homeAddress ?? '—'),
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
        child: Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
