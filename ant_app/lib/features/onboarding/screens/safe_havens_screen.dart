import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

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

    return OnboardingScaffold(
      title: 'Where do you feel safest?',
      subtitle: 'We\'ll use these to guide you back to safety and to reroute you away from danger.',
      onBack: controller.goBack,
      primaryActionLabel: 'Continue',
      primaryActionEnabled: _homeController.text.trim().isNotEmpty,
      onPrimaryAction: () => controller.setSafeHavens(
        homeAddress: _homeController.text.trim(),
        safePlaceAddress:
            _safePlaceController.text.trim().isEmpty ? null : _safePlaceController.text.trim(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Home address', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Semantics(
            textField: true,
            label: 'Home address',
            child: TextField(
              controller: _homeController,
              decoration: const InputDecoration(hintText: 'e.g. House 12, Road 5, Dhanmondi'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 20),
          Text('A safe place nearby (optional)', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Semantics(
            textField: true,
            label: 'Safe place address, optional',
            child: TextField(
              controller: _safePlaceController,
              decoration: const InputDecoration(hintText: 'e.g. A trusted relative\'s house'),
            ),
          ),
        ],
      ),
    );
  }
}
