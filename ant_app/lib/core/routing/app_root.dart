import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/dashboard/screens/split_mode_dashboard_screen.dart';
import '../../features/guardian/screens/guardian_hub_screen.dart';
import '../../features/onboarding/models/user_role.dart';
import '../../features/onboarding/providers/onboarding_providers.dart';
import '../../features/onboarding/screens/onboarding_flow_screen.dart';
import '../theme/app_colors.dart';

/// Role-Based Routing (UI module plan Step 1): on every launch, reads the
/// signed-in user's `users/{uid}` doc and routes straight to their
/// dashboard once onboarding is complete, instead of always starting at
/// role selection.
///
/// This reads `role`/`onboardingComplete` off the Firestore profile rather
/// than a verified Auth custom claim because the `onUserRoleWritten` Cloud
/// Function is written but undeployed (Spark plan, no billing yet — see
/// Module 1's task.md). Swap to `user.getIdTokenResult()` claims once that
/// ships; nothing else here needs to change.
class AppRoot extends ConsumerWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authStateProvider);

    return authAsync.when(
      data: (user) {
        if (user == null) return const OnboardingFlowScreen();
        return _ProfileGate(uid: user.uid);
      },
      loading: () => const _SplashScreen(),
      error: (e, st) => _ErrorScreen(message: e.toString()),
    );
  }
}

class _ProfileGate extends ConsumerWidget {
  const _ProfileGate({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(profileStreamProvider(uid));

    return profileAsync.when(
      data: (profile) {
        if (profile == null || !profile.onboardingComplete) {
          return const OnboardingFlowScreen();
        }
        // Theming itself is resolved reactively at the MaterialApp level
        // (see theme_resolver.dart) so it reaches every route on the
        // Navigator, not just this one — routing only decides *which*
        // screen, not how it's themed.
        return switch (profile.role) {
          UserRole.caretaker => GuardianHubScreen(profile: profile),
          UserRole.disabledUser => SplitModeDashboardScreen(profile: profile),
        };
      },
      loading: () => const _SplashScreen(),
      error: (e, st) => _ErrorScreen(message: e.toString()),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: AppColors.danger, size: 48),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
