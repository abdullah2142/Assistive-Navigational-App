import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../models/guardian_alert.dart';
import '../providers/guardian_providers.dart';

/// Alert Center — flashes when the Magic Button is pressed or the Virtual
/// Guardian's inactivity timer fires. Both triggers are Modules 8-9; this
/// panel is fully functional against whatever they write to
/// `alerts/{disabledUserUid}/items`. An audible alarm needs an audio
/// package that isn't part of Module 2's scope — left for whichever of
/// those modules adds it.
class AlertCenterPanel extends ConsumerWidget {
  const AlertCenterPanel({super.key, required this.disabledUserUid});

  final String disabledUserUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alertsAsync = ref.watch(alertsStreamProvider(disabledUserUid));
    final theme = Theme.of(context);

    return alertsAsync.when(
      data: (alerts) {
        final active = alerts.where((a) => !a.resolved).toList();
        if (active.isEmpty) {
          return Semantics(
            label: 'No active alerts',
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_moon_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text('No active alerts.', style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          );
        }
        return Column(
          children: active.map((alert) => _AlertCard(disabledUserUid: disabledUserUid, alert: alert)).toList(),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, st) => Text('Couldn\'t load alerts: $e', style: theme.textTheme.bodySmall),
    );
  }
}

class _AlertCard extends ConsumerStatefulWidget {
  const _AlertCard({required this.disabledUserUid, required this.alert});

  final String disabledUserUid;
  final GuardianAlert alert;

  @override
  ConsumerState<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends ConsumerState<_AlertCard> with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: '${widget.alert.type.label}. Active alert.',
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final t = _pulseController.value;
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Color.lerp(AppColors.danger, AppColors.danger.withValues(alpha: 0.7), t),
              borderRadius: BorderRadius.circular(16),
            ),
            child: child,
          );
        },
        child: Row(
          children: [
            const Icon(Icons.warning_rounded, color: Colors.white, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.alert.type.label,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              onPressed: () => ref
                  .read(alertServiceProvider)
                  .resolveAlert(widget.disabledUserUid, widget.alert.id),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('Mark resolved'),
            ),
          ],
        ),
      ),
    );
  }
}
