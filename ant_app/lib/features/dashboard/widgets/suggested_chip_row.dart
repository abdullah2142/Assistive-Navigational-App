import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../models/suggested_chip.dart';

/// Large single-tap chips above the chat input, so the most common requests
/// never require typing or speech.
///
/// Laid out as a fixed two-column grid rather than scrolling sideways.
/// A horizontally scrolling strip hid every chip past the second one — on
/// a 720px-wide phone that was "Route to Work" and half of "Scan the next
/// bus", with the rest reachable only by dragging. That is a poor control
/// for anyone and close to useless for this app's users: a screen-reader
/// user has no way to know an off-screen chip exists, and a low-vision
/// user has to discover a horizontal drag gesture on a surface where
/// nothing else scrolls that way. These are meant to be the shortcuts you
/// can see, so all of them are on screen at once.
///
/// Two columns, not a free-flowing wrap: a grid puts every chip in a
/// predictable place, which is what makes it learnable by position for
/// someone with low vision. Equal-width cells also stop the row from
/// re-flowing into a different arrangement when a label changes length
/// between Bangla and English.
class SuggestedChipRow extends StatelessWidget {
  const SuggestedChipRow({
    super.key,
    required this.chips,
    required this.onTap,
    required this.strings,
  });

  final List<SuggestedChip> chips;
  final ValueChanged<SuggestedChip> onTap;
  final Dashboard strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = 10.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth - gap) / 2;
        return Column(
          children: [
            for (var row = 0; row * 2 < chips.length; row++) ...[
              if (row > 0) const SizedBox(height: gap),
              // Equal-height cells within a row, so a chip whose label wraps
              // to two lines does not leave its neighbour looking like a
              // different kind of control. `IntrinsicHeight` because the
              // enclosing column is unbounded, where `stretch` alone
              // resolves to an infinite height.
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var col = 0; col < 2; col++) ...[
                      if (col > 0) const SizedBox(width: gap),
                      SizedBox(
                        width: cell,
                        // An odd number of chips leaves the last cell empty
                        // rather than letting one stretch to full width — a
                        // chip that changes size depending on how many others
                        // exist is a chip you cannot learn the position of.
                        child: row * 2 + col < chips.length
                            ? _Chip(
                                chip: chips[row * 2 + col],
                                label: chips[row * 2 + col].labelFor(strings),
                                onTap: () => onTap(chips[row * 2 + col]),
                                theme: theme,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.chip, required this.label, required this.onTap, required this.theme});

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
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Container(
            // 48dp minimum touch target, still true for someone aiming by
            // feel, and asserted here because no parent imposes a height.
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(chip.icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                // Wraps rather than clipping: at the largest text sizes this
                // app offers, a label forced onto one line was cut mid-word.
                Flexible(
                  child: Text(
                    label,
                    // Colour set explicitly rather than inherited. The theme's
                    // `labelMedium` carries a dimmed onSurfaceVariant, which on
                    // the dark dashboard rendered these labels almost invisible
                    // — a contrast failure anywhere, and disqualifying in an app
                    // whose users include people with low vision.
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
