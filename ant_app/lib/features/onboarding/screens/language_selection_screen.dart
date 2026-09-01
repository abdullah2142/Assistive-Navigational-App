import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/providers/tts_providers.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/big_choice_card.dart';
import '../widgets/onboarding_scaffold.dart';

/// The very first screen, before role selection — a Bangla-only reader
/// needs to understand *that* screen too. Deliberately bilingual on its own
/// terms: both labels are native-script regardless of any chosen language
/// (there isn't one yet), and voice guidance announces in both languages in
/// turn rather than guessing one and getting it wrong for half the
/// audience.
class LanguageSelectionScreen extends ConsumerStatefulWidget {
  const LanguageSelectionScreen({super.key});

  @override
  ConsumerState<LanguageSelectionScreen> createState() => _LanguageSelectionScreenState();
}

class _LanguageSelectionScreenState extends ConsumerState<LanguageSelectionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _announce());
  }

  Future<void> _announce() async {
    if (!ref.read(ttsEnabledProvider)) return;
    final tts = ref.read(ttsServiceProvider);
    await tts.speak('Choose your language: English, or Bangla.', language: AppLanguage.english);
    if (!mounted) return;
    await tts.speak('আপনার ভাষা বেছে নিন: ইংরেজি, অথবা বাংলা।', language: AppLanguage.bangla);
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Choose your language / ভাষা বাছাই করুন',
      autoSpeak: false,
      child: Column(
        children: [
          BigChoiceCard(
            label: 'English',
            onTap: () => controller.setLanguage(AppLanguage.english),
          ),
          BigChoiceCard(
            label: 'বাংলা',
            onTap: () => controller.setLanguage(AppLanguage.bangla),
          ),
        ],
      ),
    );
  }
}
