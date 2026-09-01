import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/onboarding_strings.dart';
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
    final s = Onboarding.of(state.language);

    return OnboardingScaffold(
      title: s.userPairingTitle,
      subtitle: s.userPairingSubtitle,
      isLoading: state.isLoading,
      language: state.language,
      primaryActionLabel: s.continueLabel,
      primaryActionEnabled: _controller.text.length == 6,
      onPrimaryAction: () => controller.submitPairingCode(_controller.text),
      spokenOptions: [s.userPairingSpokenHint],
      child: Column(
        children: [
          Semantics(
            label: s.userPairingCodeFieldLabel,
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
            label: s.userPairingNoCaretakerSemantics,
            child: TextButton(
              onPressed: state.isLoading ? null : controller.skipPairing,
              child: Text(s.userPairingNoCaretakerButton),
            ),
          ),
          Text(
            s.userPairingNoCaretakerCaption,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
