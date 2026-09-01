import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class VisionQuestionScreen extends ConsumerWidget {
  const VisionQuestionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.visionTitle,
      subtitle: s.visionSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        'Option 1: ${s.visionNoneLabel}. ${s.visionNoneDescription}',
        'Option 2: ${s.visionLowLabel}. ${s.visionLowDescription}',
        'Option 3: ${s.visionFullLabel}. ${s.visionFullDescription}',
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.visionNoneLabel,
            description: s.visionNoneDescription,
            onTap: () => controller.setVisionLevel(VisionLevel.none),
          ),
          BigChoiceCard(
            label: s.visionLowLabel,
            description: s.visionLowDescription,
            onTap: () => controller.setVisionLevel(VisionLevel.low),
          ),
          BigChoiceCard(
            label: s.visionFullLabel,
            description: s.visionFullDescription,
            onTap: () => controller.setVisionLevel(VisionLevel.full),
          ),
        ],
      ),
    );
  }
}
