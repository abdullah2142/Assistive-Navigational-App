import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';

/// Shown to the Caretaker the instant the Disabled User redeems the code.
/// Continuing here hands off to the Guardian Hub (Module 2), out of scope
/// for this module.
class PairedConfirmationScreen extends ConsumerWidget {
  const PairedConfirmationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(onboardingControllerProvider.notifier);

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
                  'Paired successfully!',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'You are now linked. You will be able to see their live location and get safety alerts once they finish their setup.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: controller.finishCaretakerSetup,
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
