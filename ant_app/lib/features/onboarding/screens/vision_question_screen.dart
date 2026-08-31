import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class VisionQuestionScreen extends ConsumerWidget {
  const VisionQuestionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Do you have any vision difficulty?',
      subtitle: 'This helps us adjust the screen and voice guidance for you.',
      onBack: controller.goBack,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'No vision',
            description: 'I rely entirely on voice and touch.',
            onTap: () => controller.setVisionLevel(VisionLevel.none),
          ),
          BigChoiceCard(
            label: 'Partial / low vision',
            description: 'I can see some things, but need larger text and higher contrast.',
            onTap: () => controller.setVisionLevel(VisionLevel.low),
          ),
          BigChoiceCard(
            label: 'Full vision',
            description: 'I see well and don\'t need visual adjustments.',
            onTap: () => controller.setVisionLevel(VisionLevel.full),
          ),
        ],
      ),
    );
  }
}
