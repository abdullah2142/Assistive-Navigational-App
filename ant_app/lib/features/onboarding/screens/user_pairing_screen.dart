import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

class UserPairingScreen extends ConsumerStatefulWidget {
  const UserPairingScreen({super.key});

  @override
  ConsumerState<UserPairingScreen> createState() => _UserPairingScreenState();
}

class _UserPairingScreenState extends ConsumerState<UserPairingScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(onboardingControllerProvider);
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'Enter your caretaker\'s code',
      subtitle: 'Ask your caretaker for the 6-digit code shown on their screen.',
      isLoading: state.isLoading,
      primaryActionLabel: 'Continue',
      primaryActionEnabled: _controller.text.length == 6,
      onPrimaryAction: () => controller.submitPairingCode(_controller.text),
      child: Column(
        children: [
          Semantics(
            label: 'Enter the 6 digit pairing code',
            textField: true,
            child: TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 32, letterSpacing: 8, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(hintText: '000000'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(state.errorMessage!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 32),
          Semantics(
            button: true,
            label: 'I don\'t have a caretaker, continue without pairing',
            child: TextButton(
              onPressed: state.isLoading ? null : controller.skipPairing,
              child: const Text('I don\'t have a caretaker'),
            ),
          ),
          Text(
            'You can still use every safety feature. You can pair with a caretaker '
            'later just by asking the AI.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
