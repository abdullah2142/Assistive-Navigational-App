import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Asks whether the microphone should open on its own.
///
/// Only reached by users who are not blind — see `autoListenDefaultFor`. For
/// a blind user this is already on and asking would be a question with one
/// sensible answer, which is worse than no question.
///
/// It exists at all because the setting used to be *derived*: on for anyone
/// not fully sighted, or who said complex instructions were hard. That
/// produced a behaviour nobody chose, sitting in settings beside the wake
/// word with nothing explaining how the two related — reported as "auto
/// listen is a weird option".
class AutoListenScreen extends ConsumerWidget {
  const AutoListenScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.autoListenTitle,
      subtitle: s.autoListenSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        '${s.spokenOptionLabel(1)}: ${s.autoListenYesLabel}. ${s.autoListenYesDescription}',
        '${s.spokenOptionLabel(2)}: ${s.autoListenNoLabel}. ${s.autoListenNoDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.autoListenYesLabel,
          synonyms: s.autoListenYesSynonyms,
          onSelect: () => controller.setAutoListen(true),
        ),
        OnboardingVoiceChoice(
          label: s.autoListenNoLabel,
          synonyms: s.autoListenNoSynonyms,
          onSelect: () => controller.setAutoListen(false),
        ),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.autoListenYesLabel,
            description: s.autoListenYesDescription,
            icon: Icons.mic_rounded,
            onTap: () => controller.setAutoListen(true),
          ),
          BigChoiceCard(
            label: s.autoListenNoLabel,
            description: s.autoListenNoDescription,
            icon: Icons.touch_app_rounded,
            onTap: () => controller.setAutoListen(false),
          ),
        ],
      ),
    );
  }
}
