import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../providers/onboarding_providers.dart';
import '../widgets/onboarding_scaffold.dart';

/// Step 2.1b — Visual Calibration Phase.
///
/// Shown only when the user reports Low Vision. They drag two sliders until
/// a live preview block is legible for their specific eye condition; the
/// resulting values become `contrastLevel` / `fontScale` on their profile
/// and activate the Low Vision Theme app-wide (see AppTheme.lowVision).
class VisualCalibrationScreen extends ConsumerStatefulWidget {
  const VisualCalibrationScreen({super.key});

  @override
  ConsumerState<VisualCalibrationScreen> createState() => _VisualCalibrationScreenState();
}

class _VisualCalibrationScreenState extends ConsumerState<VisualCalibrationScreen> {
  double _contrast = 0.7;
  double _fontScale = 1.4;

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(onboardingControllerProvider.notifier);
    final bg = Color.lerp(AppColors.background, Colors.black, _contrast)!;
    final fg = Color.lerp(AppColors.textPrimary, Colors.white, _contrast)!;

    return OnboardingScaffold(
      title: 'Let\'s adjust the display for you',
      subtitle: 'Move the sliders until the text below is easy for you to read.',
      onBack: controller.goBack,
      primaryActionLabel: 'This is comfortable, continue',
      onPrimaryAction: () =>
          controller.setCalibration(contrastLevel: _contrast, fontScale: _fontScale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            label: 'Preview text',
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
              child: Text(
                'ANT will guide you safely.\nআমরা আপনাকে নিরাপদে পথ দেখাব।',
                style: TextStyle(
                  color: fg,
                  fontSize: 18 * _fontScale,
                  fontWeight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Semantics(
            label: 'Contrast level slider, currently ${(_contrast * 100).round()} percent',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Contrast', style: Theme.of(context).textTheme.titleMedium),
                Slider(
                  value: _contrast,
                  onChanged: (v) => setState(() => _contrast = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Text size slider, currently ${_fontScale.toStringAsFixed(1)} times normal size',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Text size', style: Theme.of(context).textTheme.titleMedium),
                Slider(
                  value: _fontScale,
                  min: 1.0,
                  max: 2.5,
                  onChanged: (v) => setState(() => _fontScale = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
