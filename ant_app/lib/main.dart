import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/routing/app_root.dart';
import 'core/theme/app_colors.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_resolver.dart';
import 'features/onboarding/providers/onboarding_providers.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  bool firebaseReady = true;
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    firebaseReady = false;
  }

  runApp(ProviderScope(child: AntApp(firebaseReady: firebaseReady)));
}

class AntApp extends ConsumerWidget {
  const AntApp({super.key, required this.firebaseReady});

  final bool firebaseReady;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      title: 'ANT',
      debugShowCheckedModeBanner: false,
      // Watched here, not just wrapped around one route's own build output,
      // so it applies to every route on the Navigator — including ones
      // reached via Navigator.push, like MySettingsScreen or
      // RemoteManagementScreen. See theme_resolver.dart's doc comment.
      theme: firebaseReady ? _watchTheme(ref) : AppTheme.standard(),
      home: firebaseReady ? const AppRoot() : const _FirebaseSetupRequiredScreen(),
    );
  }

  ThemeData _watchTheme(WidgetRef ref) {
    final user = ref.watch(authStateProvider).value;
    if (user == null) return AppTheme.standard();
    final profile = ref.watch(profileStreamProvider(user.uid)).value;
    return resolveThemeForProfile(profile);
  }
}

class _FirebaseSetupRequiredScreen extends StatelessWidget {
  const _FirebaseSetupRequiredScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cloud_off_rounded, color: AppColors.caution, size: 56),
              const SizedBox(height: 20),
              Text(
                'Firebase isn\'t connected yet',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Run "firebase init" and "flutterfire configure" in the ant_app/ '
                'directory to connect this app to a Firebase project, then restart.',
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
