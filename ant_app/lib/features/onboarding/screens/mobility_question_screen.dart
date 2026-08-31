import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class MobilityQuestionScreen extends ConsumerWidget {
  const MobilityQuestionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'How do you get around?',
      subtitle: 'This helps us choose routes that work for you.',
      onBack: controller.goBack,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'White cane',
            icon: Icons.accessible_forward_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.whiteCane),
          ),
          BigChoiceCard(
            label: 'Wheelchair',
            icon: Icons.accessible_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.wheelchair),
          ),
          BigChoiceCard(
            label: 'I walk unassisted',
            icon: Icons.directions_walk_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.unassisted),
          ),
        ],
      ),
    );
  }
}
