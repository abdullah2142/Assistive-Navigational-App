import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

class DeafHearingScreen extends ConsumerWidget {
  const DeafHearingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Are you deaf or hard of hearing?',
      subtitle: 'If so, we\'ll show you text and visual guidance instead of relying on audio.',
      onBack: controller.goBack,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'Yes',
            description: 'Show me text and visuals instead of audio.',
            icon: Icons.hearing_disabled_rounded,
            onTap: () => controller.setDeafHearing(true),
          ),
          BigChoiceCard(
            label: 'No',
            description: 'I can hear voice guidance normally.',
            icon: Icons.hearing_rounded,
            onTap: () => controller.setDeafHearing(false),
          ),
        ],
      ),
    );
  }
}
