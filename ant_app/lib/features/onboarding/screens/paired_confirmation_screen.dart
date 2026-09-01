import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';

/// Shown to the Caretaker the instant the Disabled User redeems the code.
/// Continuing here hands off to the Guardian Hub (Module 2), out of scope
/// for this module.
class PairedConfirmationScreen extends ConsumerWidget {
  const PairedConfirmationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);
    final s = Onboarding.of(state.profile?.language ?? state.language);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle_rounded, color: AppColors.success, size: 72),
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  s.pairedConfirmationTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                s.pairedConfirmationBody,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: controller.finishCaretakerSetup,
                  child: Text(s.continueLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
