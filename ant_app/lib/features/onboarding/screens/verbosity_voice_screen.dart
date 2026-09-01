import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

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
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);
    final canContinue = _verbosity != null && _voiceId != null;
    final voiceOptions = [
      ('bn-BD-female-1', s.verbosityFemaleVoiceLabel),
      ('bn-BD-male-1', s.verbosityMaleVoiceLabel),
    ];

    return OnboardingScaffold(
      title: s.verbosityTitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: canContinue,
      onPrimaryAction: canContinue
          ? () => controller.setVerbosityAndVoice(verbosity: _verbosity!, voiceId: _voiceId!)
          : null,
      spokenOptions: [s.verbositySpokenHint, s.verbositySpokenVoiceHint],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.verbosityChattinessLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          BigChoiceCard(
            label: s.verbosityMinimalistLabel,
            description: s.verbosityMinimalistDescription,
            selected: _verbosity == VerbosityLevel.minimalist,
            onTap: () => setState(() => _verbosity = VerbosityLevel.minimalist),
          ),
          BigChoiceCard(
            label: s.verbosityDescriptiveLabel,
            description: s.verbosityDescriptiveDescription,
            selected: _verbosity == VerbosityLevel.descriptive,
            onTap: () => setState(() => _verbosity = VerbosityLevel.descriptive),
          ),
          const SizedBox(height: 16),
          Text(s.verbosityVoiceLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final (id, label) in voiceOptions)
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
