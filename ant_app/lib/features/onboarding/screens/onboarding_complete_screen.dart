import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';

/// Brief hand-off screen shown for the moment between writing
/// `onboardingComplete: true` and `AppRoot` (Module 2) picking up that
/// Firestore change and swapping to the real dashboard.
class OnboardingCompleteScreen extends ConsumerStatefulWidget {
  const OnboardingCompleteScreen({super.key});

  @override
  ConsumerState<OnboardingCompleteScreen> createState() => _OnboardingCompleteScreenState();
}

class _OnboardingCompleteScreenState extends ConsumerState<OnboardingCompleteScreen> {
  @override
  void initState() {
    super.initState();
    if (!ref.read(ttsEnabledProvider)) return;
    final state = ref.read(onboardingControllerProvider);
    final language = state.profile?.language ?? state.language;
    final message = Onboarding.of(language).completeMessage;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(ttsServiceProvider).speak(message, language: language),
    );
  }

  @override
  Widget build(BuildContext context) {
    final language = ref.watch(onboardingControllerProvider.select((s) => s.profile?.language)) ??
        ref.read(onboardingControllerProvider).language;
    final message = Onboarding.of(language).completeMessage;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.verified_rounded, color: AppColors.primary, size: 64),
              const SizedBox(height: 24),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
