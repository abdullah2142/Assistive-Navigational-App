import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

const _voiceOptions = [
  ('bn-BD-female-1', 'Bangla — Female voice'),
  ('bn-BD-male-1', 'Bangla — Male voice'),
];

class VerbosityVoiceScreen extends ConsumerStatefulWidget {
  const VerbosityVoiceScreen({super.key});

  @override
  ConsumerState<VerbosityVoiceScreen> createState() => _VerbosityVoiceScreenState();
}

class _VerbosityVoiceScreenState extends ConsumerState<VerbosityVoiceScreen> {
  VerbosityLevel? _verbosity;
  String? _voiceId;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final canContinue = _verbosity != null && _voiceId != null;

    return OnboardingScaffold(
      title: 'How should the AI talk to you?',
      onBack: controller.goBack,
      primaryActionLabel: 'Continue',
      primaryActionEnabled: canContinue,
      onPrimaryAction: canContinue
          ? () => controller.setVerbosityAndVoice(verbosity: _verbosity!, voiceId: _voiceId!)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chattiness', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          BigChoiceCard(
            label: 'Minimalist',
            description: 'Short, essential instructions only.',
            selected: _verbosity == VerbosityLevel.minimalist,
            onTap: () => setState(() => _verbosity = VerbosityLevel.minimalist),
          ),
          BigChoiceCard(
            label: 'Descriptive',
            description: 'More detail and reassurance along the way.',
            selected: _verbosity == VerbosityLevel.descriptive,
            onTap: () => setState(() => _verbosity = VerbosityLevel.descriptive),
          ),
          const SizedBox(height: 16),
          Text('Voice', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (id, label) in _voiceOptions)
            BigChoiceCard(
              label: label,
              selected: _voiceId == id,
              onTap: () => setState(() => _voiceId = id),
            ),
        ],
      ),
    );
  }
}
