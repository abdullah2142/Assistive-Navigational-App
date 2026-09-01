import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../models/suggested_chip.dart';

/// Horizontal row of large single-tap chips above the chat input, so the
/// most common requests never require typing or speech.
class SuggestedChipRow extends StatelessWidget {
  const SuggestedChipRow({super.key, required this.chips, required this.onTap, required this.strings});

  final List<SuggestedChip> chips;
  final ValueChanged<SuggestedChip> onTap;
  final Dashboard strings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final chip = chips[index];
          final label = chip.labelFor(strings);
          return Semantics(
            button: true,
            label: label,
            child: Material(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () => onTap(chip),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(chip.icon, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(label, style: theme.textTheme.labelLarge),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
