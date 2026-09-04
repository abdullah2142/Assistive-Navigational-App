import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../models/disability_profile_enums.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/onboarding_voice.dart';

/// Step 3.4 — Snapshot Request permission (Module 6's Vision Engine: the
/// paired Caretaker can ask for one still frame, never a live feed — see
/// the "No Live Video Feeds" architectural rule). This screen decides
/// whether that request needs live consent each time.
class SnapshotConsentScreen extends ConsumerWidget {
  const SnapshotConsentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.snapshotTitle,
      subtitle: s.snapshotSubtitle,
      onBack: controller.goBack,
      language: language,
      spokenOptions: [
        '${s.spokenOptionLabel(1)}: ${s.snapshotAlwaysLabel}. ${s.snapshotAlwaysDescription}',
        '${s.spokenOptionLabel(2)}: ${s.snapshotAskLabel}. ${s.snapshotAskDescription}',
        '${s.spokenOptionLabel(3)}: ${s.snapshotNeverLabel}. ${s.snapshotNeverDescription}',
      ],
      voiceChoices: [
        OnboardingVoiceChoice(
          label: s.snapshotAlwaysLabel,
          synonyms: s.snapshotAlwaysSynonyms,
          onSelect: () => controller.setSnapshotConsent(SnapshotConsentPreference.always),
        ),
        OnboardingVoiceChoice(
          label: s.snapshotAskLabel,
          synonyms: s.snapshotAskSynonyms,
          onSelect: () => controller.setSnapshotConsent(SnapshotConsentPreference.askEachTime),
        ),
        OnboardingVoiceChoice(
          label: s.snapshotNeverLabel,
          synonyms: s.snapshotNeverSynonyms,
          onSelect: () => controller.setSnapshotConsent(SnapshotConsentPreference.never),
        ),
      ],
      child: Column(
        children: [
          BigChoiceCard(
            label: s.snapshotAlwaysLabel,
            description: s.snapshotAlwaysDescription,
            icon: Icons.camera_alt_rounded,
            onTap: () => controller.setSnapshotConsent(SnapshotConsentPreference.always),
          ),
          BigChoiceCard(
            label: s.snapshotAskLabel,
            description: s.snapshotAskDescription,
            icon: Icons.pending_actions_rounded,
            onTap: () => controller.setSnapshotConsent(SnapshotConsentPreference.askEachTime),
          ),
          BigChoiceCard(
            label: s.snapshotNeverLabel,
            description: s.snapshotNeverDescription,
            icon: Icons.no_photography_rounded,
            onTap: () => controller.setSnapshotConsent(SnapshotConsentPreference.never),
          ),
        ],
      ),
    );
  }
}
