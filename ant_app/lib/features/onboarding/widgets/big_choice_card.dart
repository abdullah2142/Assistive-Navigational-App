import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// A large, high-contrast, single-tap choice control.
///
/// Every onboarding decision uses this instead of small radio buttons or
/// dropdowns — big touch targets matter for Mobility Impaired and Low
/// Vision users, and a single tap (no combo interactions) matters for
/// Cognitive Impairment.
class BigChoiceCard extends StatelessWidget {
  const BigChoiceCard({
    super.key,
    required this.label,
    required this.onTap,
    this.description,
    this.icon,
    this.selected = false,
  });

  final String label;
  final String? description;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: description == null ? label : '$label. $description',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: selected ? theme.colorScheme.primary.withValues(alpha: 0.12) : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 72),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: selected ? theme.colorScheme.primary : AppColors.divider,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(icon, color: theme.colorScheme.primary, size: 28),
                    const SizedBox(width: 16),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: theme.textTheme.titleMedium),
                        if (description != null) ...[
                          const SizedBox(height: 4),
                          Text(description!, style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
