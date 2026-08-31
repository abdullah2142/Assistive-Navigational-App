import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../models/user_role.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class RoleSelectionScreen extends ConsumerWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Welcome to ANT',
      subtitle: 'Let\'s get started. Are you setting this up for yourself, or for someone you care for?',
      isLoading: state.isLoading,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'I need assistance',
            description: 'Set up navigation help for myself.',
            icon: Icons.accessibility_new_rounded,
            onTap: () => controller.chooseRole(UserRole.disabledUser),
          ),
          BigChoiceCard(
            label: 'I am a Caretaker',
            description: 'Set up remote monitoring for someone I support.',
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
