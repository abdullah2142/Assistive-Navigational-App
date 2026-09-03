import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../models/user_role.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class RoleSelectionScreen extends ConsumerWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final s = Onboarding.of(state.language);

    return OnboardingScaffold(
      title: s.roleSelectionTitle,
      subtitle: s.roleSelectionSubtitle,
      onBack: controller.goBack,
      isLoading: state.isLoading,
      language: state.language,
      spokenOptions: [
        'Option 1: ${s.roleDisabledUserLabel}. ${s.roleDisabledUserDescription}',
        'Option 2: ${s.roleCaretakerLabel}. ${s.roleCaretakerDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.roleDisabledUserLabel,
          synonyms: s.roleDisabledUserSynonyms,
          onSelect: () => controller.chooseRole(UserRole.disabledUser),
        ),
        OnboardingVoiceChoice(
          label: s.roleCaretakerLabel,
          synonyms: s.roleCaretakerSynonyms,
          onSelect: () => controller.chooseRole(UserRole.caretaker),
        ),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.roleDisabledUserLabel,
            description: s.roleDisabledUserDescription,
            icon: Icons.accessibility_new_rounded,
            onTap: () => controller.chooseRole(UserRole.disabledUser),
          ),
          BigChoiceCard(
            label: s.roleCaretakerLabel,
            description: s.roleCaretakerDescription,
            icon: Icons.favorite_rounded,
            onTap: () => controller.chooseRole(UserRole.caretaker),
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              state.errorMessage!,
              style: const TextStyle(color: AppColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}
