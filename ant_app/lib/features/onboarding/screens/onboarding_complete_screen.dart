import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../models/user_role.dart';
import '../providers/onboarding_providers.dart';

/// Placeholder hand-off screen. In the real app this routes straight into
/// the Split-Mode Dashboard (Disabled User) or Guardian Hub (Caretaker) —
/// both are Module 2 scope and not built yet.
class OnboardingCompleteScreen extends ConsumerWidget {
  const OnboardingCompleteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(onboardingControllerProvider).profile?.role;
    final message = role == UserRole.caretaker
        ? 'Setup complete. The Guardian Hub (live tracking dashboard) is built in Module 2.'
        : 'Setup complete. The Split-Mode Dashboard (AI chat + map) is built in Module 2.';

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
