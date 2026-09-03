import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Only shown to users who aren't getting the forced Low Vision high-contrast
/// theme — see [OnboardingController.setVisionLevel].
class ThemePreferenceScreen extends ConsumerWidget {
  const ThemePreferenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.themeTitle,
      subtitle: s.themeSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        'Option 1: ${s.themeLightLabel}. ${s.themeLightDescription}',
        'Option 2: ${s.themeDarkLabel}. ${s.themeDarkDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.themeLightLabel,
          synonyms: s.themeLightSynonyms,
          onSelect: () => controller.setThemePreference(ThemePreference.light),
        ),
        OnboardingVoiceChoice(
          label: s.themeDarkLabel,
          synonyms: s.themeDarkSynonyms,
          onSelect: () => controller.setThemePreference(ThemePreference.dark),
        ),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.themeLightLabel,
            description: s.themeLightDescription,
            icon: Icons.light_mode_rounded,
            onTap: () => controller.setThemePreference(ThemePreference.light),
          ),
          BigChoiceCard(
            label: s.themeDarkLabel,
            description: s.themeDarkDescription,
            icon: Icons.dark_mode_rounded,
            onTap: () => controller.setThemePreference(ThemePreference.dark),
          ),
        ],
      ),
    );
  }
}
