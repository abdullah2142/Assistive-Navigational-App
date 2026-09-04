import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

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
        '${s.spokenOptionLabel(1)}: ${s.visionNoneLabel}. ${s.visionNoneDescription}',
        '${s.spokenOptionLabel(2)}: ${s.visionLowLabel}. ${s.visionLowDescription}',
        '${s.spokenOptionLabel(3)}: ${s.visionFullLabel}. ${s.visionFullDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.visionNoneLabel,
          synonyms: s.visionNoneSynonyms,
          onSelect: () => controller.setVisionLevel(VisionLevel.none),
        ),
        OnboardingVoiceChoice(
          label: s.visionLowLabel,
          synonyms: s.visionLowSynonyms,
          onSelect: () => controller.setVisionLevel(VisionLevel.low),
        ),
        OnboardingVoiceChoice(
          label: s.visionFullLabel,
          synonyms: s.visionFullSynonyms,
          onSelect: () => controller.setVisionLevel(VisionLevel.full),
        ),
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
