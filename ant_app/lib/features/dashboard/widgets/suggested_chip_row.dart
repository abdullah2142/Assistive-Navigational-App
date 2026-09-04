import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../models/suggested_chip.dart';

/// Large single-tap chips above the chat input, so the most common requests
/// never require typing or speech.
///
/// Wraps onto as many lines as it needs rather than scrolling sideways.
/// A horizontally scrolling strip hid every chip past the second one — on
/// a 720px-wide phone that was "Route to Work" and half of "Scan the next
/// bus", with the rest reachable only by dragging. That is a poor control
/// for anyone and close to useless for this app's users: a screen-reader
/// user has no way to know an off-screen chip exists, and a low-vision
/// user has to discover a horizontal drag gesture on a surface where
/// nothing else scrolls that way. These are meant to be the shortcuts you
/// can see, so all of them are on screen at once.
class SuggestedChipRow extends StatelessWidget {
  const SuggestedChipRow({super.key, required this.chips, required this.onTap, required this.strings});

  final List<SuggestedChip> chips;
  final ValueChanged<SuggestedChip> onTap;
  final Dashboard strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `Wrap` hands its children an unbounded width, and an unbounded width
    // is exactly what a `Flexible` inside a `Row` cannot lay out in. The
    // available width is captured here and imposed per chip, which also
    // gives a very long label somewhere to wrap to rather than overflowing.
    return LayoutBuilder(
      builder: (context, constraints) {
        return Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            for (final chip in chips)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                child: _Chip(
                  chip: chip,
                  label: chip.labelFor(strings),
                  onTap: () => onTap(chip),
                  theme: theme,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.chip,
    required this.label,
    required this.onTap,
    required this.theme,
  });

  final SuggestedChip chip;
  final String label;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            // Height is no longer imposed by a fixed-height parent, so the
            // 48dp minimum touch target is asserted here — it still has to
            // hold for someone aiming at this by feel.
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(chip.icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                // Wraps rather than clipping: at the largest text sizes this
                // app offers, a label forced onto one line was cut mid-word.
                Flexible(child: Text(label, style: theme.textTheme.labelLarge)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
