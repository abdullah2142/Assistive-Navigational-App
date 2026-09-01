import 'package:flutter/material.dart';

/// Shown in place of a `GoogleMap` wherever [MapsConfig.isConfigured] is
/// false, so the app never crashes or shows a broken map — it just says so.
///
/// [message]/[subtitle] default to English (used as-is by Guardian Hub,
/// which isn't localized yet); Disabled User-facing call sites pass
/// Bangla-aware strings explicitly via `Dashboard`.
class MapUnavailablePlaceholder extends StatelessWidget {
  const MapUnavailablePlaceholder({super.key, this.message, this.subtitle});

  final String? message;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedSubtitle = subtitle ?? 'A Google Maps API key hasn\'t been configured yet.';
    return Semantics(
      label: '${message ?? 'Map unavailable'}. $resolvedSubtitle',
      child: Container(
        color: theme.dividerColor.withValues(alpha: 0.4),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, color: theme.colorScheme.primary, size: 40),
            const SizedBox(height: 12),
            Text(
              message ?? 'Map unavailable',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              resolvedSubtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
