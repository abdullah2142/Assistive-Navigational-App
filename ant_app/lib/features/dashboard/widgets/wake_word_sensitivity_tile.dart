import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/wake_word_service.dart';

/// The "Hey ANT" sensitivity dial, plus the live match meter that makes it
/// possible to set.
///
/// Testers reported that the wake phrase has to be said softly, gently, and
/// with a pause between the two words. That is a statement about where the
/// detection line sits for *their* voices and *their* rooms — and the line was
/// a compile-time constant, so answering it meant shipping an APK per guess.
///
/// The meter matters as much as the slider. The measured gap between a real
/// attempt that failed (0.30-0.34) and one that succeeded (0.67+) is invisible
/// from outside `WakeWordService`, so a dial on its own would just move the
/// guessing into the app. With the score on screen, tuning becomes: say the
/// phrase, read the number, put the marker under it, say it again.
class WakeWordSensitivityTile extends ConsumerStatefulWidget {
  const WakeWordSensitivityTile({
    super.key,
    required this.threshold,
    required this.enabled,
    required this.strings,
    required this.onChanged,
  });

  /// The profile's stored threshold, or null when it has never been tuned.
  final double? threshold;

  /// Whether the wake word is switched on at all. The meter can only show
  /// anything while the detector is actually running.
  final bool enabled;

  final Dashboard strings;

  /// Called when the user settles on a value — on drag *end*, not on every
  /// frame of the drag, since this is persisted to Firestore.
  final ValueChanged<double> onChanged;

  @override
  ConsumerState<WakeWordSensitivityTile> createState() => _WakeWordSensitivityTileState();
}

class _WakeWordSensitivityTileState extends ConsumerState<WakeWordSensitivityTile> {
  static const double _min = WakeWordService.minThreshold;
  static const double _max = WakeWordService.maxThreshold;

  /// How long a peak stays on screen before the meter falls back to live
  /// values.
  ///
  /// The classifier scores a window every 80ms, and the phrase itself spans
  /// only a handful of them, so an un-held meter shows the peak for a single
  /// frame and is unreadable. Three seconds is long enough to look down after
  /// speaking.
  static const Duration _peakHold = Duration(seconds: 3);

  late double _threshold = widget.threshold ?? WakeWordService.defaultDetectionThreshold;

  double _live = 0;
  double _peak = 0;
  DateTime? _peakAt;
  Timer? _decay;

  // Captured in a field rather than read through `ref` on demand — `ref` is
  // unsafe once a widget is unmounting, and `dispose` below has to detach the
  // score listener. Reading it there crashes with "Using 'ref' when a widget
  // is about to or has been unmounted is unsafe", which is the same trap
  // documented on `_stt`/`_tts` in every other voice widget in this app.
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);

  @override
  void initState() {
    super.initState();
    // Forces the lazy initializer now, while `ref` is still safe.
    _wakeWord.lastScore.addListener(_onScore);
  }

  @override
  void didUpdateWidget(covariant WakeWordSensitivityTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only when it actually changed elsewhere — otherwise a rebuild mid-drag
    // would snap the slider back to the saved value under the user's finger.
    if (widget.threshold != oldWidget.threshold) {
      _threshold = widget.threshold ?? WakeWordService.defaultDetectionThreshold;
    }
  }

  @override
  void dispose() {
    _wakeWord.lastScore.removeListener(_onScore);
    _decay?.cancel();
    super.dispose();
  }

  void _onScore() {
    if (!mounted) return;
    final score = _wakeWord.lastScore.value;
    final now = DateTime.now();
    final peakExpired = _peakAt == null || now.difference(_peakAt!) > _peakHold;
    setState(() {
      _live = score;
      if (score >= _peak || peakExpired) {
        _peak = score;
        _peakAt = now;
      }
    });
    // Retires a stale peak even if the classifier goes quiet — otherwise the
    // last thing said stays on screen indefinitely and reads as current.
    _decay?.cancel();
    _decay = Timer(_peakHold, () {
      if (mounted) setState(() => _peak = _live);
    });
  }

  /// Sensitivity runs the opposite way to the threshold: dragging right should
  /// make the wake word *easier* to trigger, which means a lower score bar.
  double get _sensitivity => (_max - _threshold) / (_max - _min);

  double _thresholdFor(double sensitivity) => _max - sensitivity * (_max - _min);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.strings;
    final percent = (_sensitivity * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(d.settingsWakeWordSensitivityHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        Semantics(
          slider: true,
          label: d.settingsWakeWordSensitivityValue(percent),
          child: Slider(
            value: _sensitivity.clamp(0.0, 1.0),
            // 5% steps. A continuous slider cannot be landed on the same
            // value twice, which makes comparing two settings impossible.
            divisions: 20,
            label: '$percent%',
            onChanged: (v) => setState(() => _threshold = _thresholdFor(v)),
            onChangeEnd: (v) => widget.onChanged(_thresholdFor(v)),
          ),
        ),
        // Both `Flexible`, so the two labels wrap instead of overflowing.
        // "Sensitivity 72%" beside "Triggers at 0.30" is 12 pixels too wide on
        // a 360dp phone — which is the Redmi 10C this is tested on — and the
        // Bangla strings are longer than the English ones. An overflow here
        // paints a black-and-yellow bar across the very meter this exists to
        // show.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(d.settingsWakeWordSensitivityValue(percent), style: theme.textTheme.labelMedium),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                d.settingsWakeWordThresholdValue(_threshold.toStringAsFixed(2)),
                textAlign: TextAlign.end,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (!widget.enabled)
          Text(d.settingsWakeWordListeningOff, style: theme.textTheme.bodySmall)
        else ...[
          Semantics(
            label: d.settingsWakeWordMeterSemantics,
            value: _peak.toStringAsFixed(2),
            child: _MatchMeter(threshold: _threshold, live: _live, peak: _peak),
          ),
          const SizedBox(height: 6),
          Text(
            d.settingsWakeWordLiveScore(_peak.toStringAsFixed(2)),
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
          ),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () {
              setState(() => _threshold = WakeWordService.defaultDetectionThreshold);
              widget.onChanged(WakeWordService.defaultDetectionThreshold);
            },
            child: Text(d.settingsWakeWordReset),
          ),
        ),
      ],
    );
  }
}

/// A 0-to-1 bar with the trigger line marked on it.
///
/// The line is the whole point: a bare level meter would say how loud the
/// match was without saying whether it was enough, which is the one thing
/// somebody tuning this needs to know.
class _MatchMeter extends StatelessWidget {
  const _MatchMeter({required this.threshold, required this.live, required this.peak});

  final double threshold;
  final double live;
  final double peak;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wouldFire = peak >= threshold;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: 22,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
              // The peak sits behind the live level so a fading attempt still
              // shows how far it actually got.
              FractionallySizedBox(
                widthFactor: peak.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: (wouldFire ? theme.colorScheme.primary : theme.colorScheme.error)
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
              FractionallySizedBox(
                widthFactor: live.clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: wouldFire ? theme.colorScheme.primary : theme.colorScheme.error,
                    borderRadius: BorderRadius.circular(11),
                  ),
                ),
              ),
              Positioned(
                left: (threshold.clamp(0.0, 1.0) * width) - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: theme.colorScheme.onSurface),
              ),
            ],
          ),
        );
      },
    );
  }
}
