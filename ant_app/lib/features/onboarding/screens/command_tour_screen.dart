import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// The last thing onboarding teaches: what you can actually say.
///
/// ## Why this is a screen and not a help page
///
/// Everything before this asks the user *about themselves*. Nothing has yet
/// told them what the app does when they talk to it — which matters
/// disproportionately here, because after [LockInScreen] the settings UI
/// disappears and speech becomes the only way most of these users will ever
/// change anything. Sending someone into that with no idea what to say is
/// the whole failure this screen exists to prevent.
///
/// A written reference cannot do this job. The people it matters most for
/// cannot read it, and a list they have to go and find is a list they will
/// not find. So it is spoken, in their language, at the one moment they are
/// already listening — and it is deliberately *short*: four groups, one to
/// three examples each. This is not the full phrasebook and should never
/// grow into it. It exists to leave the impression "I can just say things",
/// not to be memorised.
///
/// The examples are also chosen to teach the *shape* rather than the
/// script, which is why the closing line says so explicitly. A user who
/// believes these are magic words will stop when one fails; a user who
/// understands they are examples will rephrase.
class CommandTourScreen extends ConsumerWidget {
  const CommandTourScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = state.profile?.language ?? state.language;
    final s = Onboarding.of(language);
    final groups = s.commandTourGroups;

    return OnboardingScaffold(
      title: s.commandTourTitle,
      subtitle: s.commandTourSubtitle,
      onBack: controller.goBack,
      isLoading: state.isLoading,
      language: language,
      primaryActionLabel: s.commandTourContinueLabel,
      onPrimaryAction: controller.finishCommandTour,
      spokenOptions: [
        for (final group in groups) ...[
          '${group.heading}:',
          // Each example is its own line so the engine puts a real pause
          // between them. Run together, three commands in one breath are
          // heard as one long sentence and none of them stick.
          ...group.examples.map((e) => '$e.'),
          if (group.note != null) group.note!,
        ],
        s.commandTourClosing,
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.commandTourRepeatLabel,
          synonyms: s.commandTourRepeatSynonyms,
          // Re-entering the same step re-runs the scaffold's narration.
          onSelect: controller.repeatCommandTour,
        ),
        OnboardingVoiceChoice(
          label: s.commandTourContinueLabel,
          synonyms: s.commandTourContinueSynonyms,
          onSelect: controller.finishCommandTour,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 20, bottom: 8),
              child: Text(
                group.heading,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            for (final example in group.examples)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3, right: 10),
                      child: Icon(Icons.graphic_eq_rounded, size: 18, color: AppColors.primary),
                    ),
                    Expanded(
                      child: Text(
                        '“$example”',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ],
                ),
              ),
            if (group.note != null)
              Padding(
                padding: const EdgeInsets.only(left: 28, top: 6),
                child: Text(
                  group.note!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
          ],
          const SizedBox(height: 24),
          Text(
            s.commandTourClosing,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
