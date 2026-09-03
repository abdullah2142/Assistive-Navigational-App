import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

class DeafHearingScreen extends ConsumerWidget {
  const DeafHearingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.deafTitle,
      subtitle: s.deafSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        'Option 1: ${s.deafYesLabel}. ${s.deafYesDescription}',
        'Option 2: ${s.deafNoLabel}. ${s.deafNoDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(label: s.deafYesLabel, synonyms: s.deafYesSynonyms, onSelect: () => controller.setDeafHearing(true)),
        OnboardingVoiceChoice(label: s.deafNoLabel, synonyms: s.deafNoSynonyms, onSelect: () => controller.setDeafHearing(false)),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.deafYesLabel,
            description: s.deafYesDescription,
            icon: Icons.hearing_disabled_rounded,
            onTap: () => controller.setDeafHearing(true),
          ),
          BigChoiceCard(
            label: s.deafNoLabel,
            description: s.deafNoDescription,
            icon: Icons.hearing_rounded,
            onTap: () => controller.setDeafHearing(false),
          ),
        ],
      ),
    );
  }
}
