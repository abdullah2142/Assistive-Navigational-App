import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Asks whether every question should read its answers out before listening,
/// or stay quiet until asked.
///
/// This exists because the app has shipped it both ways and both were right
/// for somebody. `OnboardingScaffold` originally deferred the option list
/// until the user said "options", so a user who already knew their answer did
/// not sit through a read-out. Live testing reverted it: a microphone opening
/// in silence reads as the app "just recording", with no idea what to say.
/// Neither report was wrong, so this stops guessing which user is on the
/// phone and asks them.
///
/// Not shown to a Deaf or hard-of-hearing user — see
/// `shouldAskAboutOptionNarration`. Spoken guidance is already off for them,
/// so this would be a question about something that does not happen.
///
/// This screen necessarily narrates its own options: the preference it
/// collects has not been given yet, and the default is to read them.
class OptionNarrationScreen extends ConsumerWidget {
  const OptionNarrationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.optionNarrationTitle,
      subtitle: s.optionNarrationSubtitle,
      onBack: controller.goBack,
      language: language,
      // See `OnboardingScaffold.alwaysNarrateOptions`.
      alwaysNarrateOptions: true,
      spokenOptions: [
        '${s.spokenOptionLabel(1)}: ${s.optionNarrationAlwaysLabel}. ${s.optionNarrationAlwaysDescription}',
        '${s.spokenOptionLabel(2)}: ${s.optionNarrationOnRequestLabel}. ${s.optionNarrationOnRequestDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.optionNarrationAlwaysLabel,
          synonyms: s.optionNarrationAlwaysSynonyms,
          onSelect: () => controller.setNarrateOptionsFirst(true),
        ),
        OnboardingVoiceChoice(
          label: s.optionNarrationOnRequestLabel,
          synonyms: s.optionNarrationOnRequestSynonyms,
          onSelect: () => controller.setNarrateOptionsFirst(false),
        ),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.optionNarrationAlwaysLabel,
            description: s.optionNarrationAlwaysDescription,
            icon: Icons.record_voice_over_rounded,
            onTap: () => controller.setNarrateOptionsFirst(true),
          ),
          BigChoiceCard(
            label: s.optionNarrationOnRequestLabel,
            description: s.optionNarrationOnRequestDescription,
            icon: Icons.volume_mute_rounded,
            onTap: () => controller.setNarrateOptionsFirst(false),
          ),
        ],
      ),
    );
  }
}
