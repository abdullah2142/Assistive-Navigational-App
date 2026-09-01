import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class MobilityQuestionScreen extends ConsumerWidget {
  const MobilityQuestionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.mobilityTitle,
      subtitle: s.mobilitySubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        'Option 1: ${s.mobilityWhiteCaneLabel}.',
        'Option 2: ${s.mobilityWheelchairLabel}.',
        'Option 3: ${s.mobilityUnassistedLabel}.',
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.mobilityWhiteCaneLabel,
            icon: Icons.accessible_forward_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.whiteCane),
          ),
          BigChoiceCard(
            label: s.mobilityWheelchairLabel,
            icon: Icons.accessible_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.wheelchair),
          ),
          BigChoiceCard(
            label: s.mobilityUnassistedLabel,
            icon: Icons.directions_walk_rounded,
            onTap: () => controller.setMobilityAid(MobilityAid.unassisted),
          ),
        ],
      ),
    );
  }
}
