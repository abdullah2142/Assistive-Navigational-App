import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';
import '../widgets/voice_dictate_button.dart';

class SafeHavensScreen extends ConsumerStatefulWidget {
  const SafeHavensScreen({super.key});

  @override
  ConsumerState<SafeHavensScreen> createState() => _SafeHavensScreenState();
}

class _SafeHavensScreenState extends ConsumerState<SafeHavensScreen> {
  final _homeController = TextEditingController();
  final _safePlaceController = TextEditingController();

  @override
  void dispose() {
    _homeController.dispose();
    _safePlaceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile!.language));
    final s = Onboarding.of(language);

    return OnboardingScaffold(
      title: s.safeHavensTitle,
      subtitle: s.safeHavensSubtitle,
      onBack: controller.goBack,
      language: language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: _homeController.text.trim().isNotEmpty,
      onPrimaryAction: () => controller.setSafeHavens(
        homeAddress: _homeController.text.trim(),
        safePlaceAddress:
            _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
      ),
      spokenOptions: [s.safeHavensSpokenHint],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.safeHavensHomeLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.safeHavensHomeLabel,
                  child: TextField(
                    controller: _homeController,
                    decoration: InputDecoration(hintText: s.safeHavensHomeHint),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(
                controller: _homeController,
                language: language,
                onDictated: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(s.safeHavensPlaceLabel, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Semantics(
                  textField: true,
                  label: s.safeHavensPlaceLabel,
                  child: TextField(
                    controller: _safePlaceController,
                    decoration: InputDecoration(hintText: s.safeHavensPlaceHint),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              VoiceDictateButton(controller: _safePlaceController, language: language),
            ],
          ),
        ],
      ),
    );
  }
}
