import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

class CognitiveAnxietyScreen extends ConsumerStatefulWidget {
  const CognitiveAnxietyScreen({super.key});

  @override
  ConsumerState<CognitiveAnxietyScreen> createState() => _CognitiveAnxietyScreenState();
}

class _CognitiveAnxietyScreenState extends ConsumerState<CognitiveAnxietyScreen> {
  bool _crowdedAnxious = false;
  bool _complexHard = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);

    return OnboardingScaffold(
      title: 'A couple more questions',
      subtitle: 'There are no wrong answers here — this only helps us keep things calm for you.',
      onBack: controller.goBack,
      primaryActionLabel: 'Continue',
      onPrimaryAction: () => controller.setCognitiveAnxiety(
        crowdedPlacesAnxious: _crowdedAnxious,
        complexInstructionsHard: _complexHard,
      ),
      child: Column(
        children: [
          _YesNoQuestion(
            question: 'Do crowded places make you feel anxious?',
            value: _crowdedAnxious,
            onChanged: (v) => setState(() => _crowdedAnxious = v),
          ),
          const SizedBox(height: 20),
          _YesNoQuestion(
            question: 'Do you find complex, multi-step instructions hard to follow?',
            value: _complexHard,
            onChanged: (v) => setState(() => _complexHard = v),
          ),
        ],
      ),
    );
  }
}

class _YesNoQuestion extends StatelessWidget {
  const _YesNoQuestion({required this.question, required this.value, required this.onChanged});

  final String question;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      label: question,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(
          children: [
            Expanded(child: Text(question, style: Theme.of(context).textTheme.titleMedium)),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
