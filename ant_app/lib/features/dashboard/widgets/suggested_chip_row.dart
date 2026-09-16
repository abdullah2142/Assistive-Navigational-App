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
/// A grid, not a free-flowing wrap: fixed cells put every chip in a
/// predictable place, which is what makes it learnable by position for
/// someone with low vision. Equal-width cells within a row also stop the
/// layout from re-flowing into a different arrangement when a label changes
/// length between Bangla and English.
///
/// ## Why the second row can hold three
///
/// Adding the caretaker voice-message chip made five, and five in pairs is
/// three rows — a third row of chips eats the chat above it, which is the
/// part users actually read. So the fifth goes into the second row rather
/// than starting a new one.
///
/// It is the *second* row that widens, deliberately. Putting the extra chip
/// in the first would push every existing chip one place along, and position
/// is the thing this layout exists to make learnable — somebody who has
/// learned that "report a hazard" is bottom-left should still find it
/// bottom-left. Widening the second row leaves both first-row chips exactly
/// where they were and keeps the other two in the row and the order they
/// were already in.
///
/// The cost is narrower cells in that row, so a long label wraps to more
/// lines. `IntrinsicHeight` already equalises the row's height around that,
/// and wrapping was always the behaviour — see `_Chip`.
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

  /// How many chips sit in each row, top row first.
  ///
  /// Pairs by default, which is every case this had before a fifth chip
  /// existed. Five becomes 2 then 3 rather than 2, 2 and 1: two rows is the
  /// budget, and the widened row is the second one so nothing already on
  /// screen moves. See the class comment.
  @visibleForTesting
  static List<int> rowSizesFor(int count) {
    if (count <= 4) return [for (var i = 0; i < count; i += 2) count - i >= 2 ? 2 : 1];
    if (count == 5) return const [2, 3];
    // Beyond five this stops trying to be clever and fills rows of three.
    // Nothing reaches it today; it is here so a sixth chip degrades into a
    // predictable grid rather than into whatever the last branch happened
    // to do.
    return [for (var i = 0; i < count; i += 3) count - i >= 3 ? 3 : count - i];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = 10.0;
    final rowSizes = rowSizesFor(chips.length);

    return LayoutBuilder(
      builder: (context, constraints) {
        var next = 0;
        final rows = <Widget>[];
        for (var row = 0; row < rowSizes.length; row++) {
          final columns = rowSizes[row];
          // Cell width is derived from this row's own column count, so the
          // row fills the full width whether it holds two chips or three.
          final cell = (constraints.maxWidth - gap * (columns - 1)) / columns;
          final start = next;
          next += columns;
          if (row > 0) rows.add(const SizedBox(height: gap));
          rows.add(
            // Equal-height cells within a row, so a chip whose label wraps
            // to two lines does not leave its neighbour looking like a
            // different kind of control. `IntrinsicHeight` because the
            // enclosing column is unbounded, where `stretch` alone
            // resolves to an infinite height.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: gap),
                    SizedBox(
                      width: cell,
                      // A short final row leaves its spare cell empty rather
                      // than letting one chip stretch to fill it — a chip
                      // that changes size depending on how many others exist
                      // is a chip you cannot learn the position of.
                      child: start + col < chips.length
                          ? _Chip(
                              chip: chips[start + col],
                              label: chips[start + col].labelFor(strings),
                              semanticsLabel: chips[start + col].semanticsLabelFor(strings),
                              onTap: () => onTap(chips[start + col]),
                              theme: theme,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.chip,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
    required this.theme,
  });

  final SuggestedChip chip;
  final String label;

  /// What is announced, which may be fuller than what is printed — a cell
  /// has a width, a spoken label does not.
  final String semanticsLabel;
  final VoidCallback onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
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
