import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/user_profile.dart';
import '../widgets/alert_center_panel.dart';
import '../widgets/communication_hub_panel.dart';
import '../widgets/overwatch_map_panel.dart';
import 'remote_management_screen.dart';

/// The Caretaker's home screen — Guardian Hub: Overwatch Map, Alert Center,
/// Communication Hub, and a link into Remote Management. See UI module
/// plan Step 3.
class GuardianHubScreen extends StatelessWidget {
  const GuardianHubScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final disabledUserUid = profile.pairedUserId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Guardian Hub'),
        actions: [
          if (disabledUserUid != null)
            Semantics(
              button: true,
              label: 'Remote Management settings',
              child: IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RemoteManagementScreen(disabledUserUid: disabledUserUid),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: disabledUserUid == null
            ? _NotPairedState(theme: Theme.of(context))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text('Overwatch', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  OverwatchMapPanel(disabledUserUid: disabledUserUid),
                  const SizedBox(height: 24),
                  Text('Alerts', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  AlertCenterPanel(disabledUserUid: disabledUserUid),
                  const SizedBox(height: 24),
                  Text('Communication', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  CommunicationHubPanel(disabledUserUid: disabledUserUid, caretakerUid: profile.uid),
                ],
              ),
      ),
    );
  }
}

class _NotPairedState extends StatelessWidget {
  const _NotPairedState({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.link_off_rounded, color: theme.colorScheme.primary, size: 48),
            const SizedBox(height: 16),
            Text(
              'Not paired with anyone yet.',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Once your pairing code is redeemed, their Overwatch map, alerts, and settings appear here.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
