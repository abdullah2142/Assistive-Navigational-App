import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../onboarding/models/user_profile.dart';
import '../models/suggested_chip.dart';
import '../widgets/chat_stream_panel.dart';
import '../widgets/crowdsource_reporting_hub.dart';
import '../widgets/dashboard_map_panel.dart';
import '../widgets/passerby_message_picker.dart';
import 'my_settings_screen.dart';

/// The Disabled User's home screen — Split-Mode Dashboard: chat (60%) over
/// a clean map with a giant directional arrow (40%), or the map alone at
/// full screen when expanded (see [_mapFullScreen]). See UI module plan
/// Step 2.
class SplitModeDashboardScreen extends StatefulWidget {
  const SplitModeDashboardScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  State<SplitModeDashboardScreen> createState() => _SplitModeDashboardScreenState();
}

class _SplitModeDashboardScreenState extends State<SplitModeDashboardScreen> {
  bool _mapFullScreen = false;

  UserProfile get profile => widget.profile;

  Future<void> _handleOverlayChip(BuildContext context, SuggestedChipAction action) async {
    final d = Dashboard.of(profile.language);
    switch (action) {
      case SuggestedChipAction.showScreenToPasserby:
        final messages = profile.passerbyHelperMessages.isNotEmpty
            ? profile.passerbyHelperMessages
            : Onboarding.of(profile.language).defaultPasserbyMessages;
        await PasserbyMessagePicker.show(
          context,
          messages: messages,
          strings: d,
          language: profile.language,
          autoListen: profile.voiceAutoListen,
        );
      case SuggestedChipAction.reportHazard:
        await CrowdsourceReportingHub.show(
          context,
          reporterUid: profile.uid,
          language: profile.language,
          voiceAutoListen: profile.voiceAutoListen,
          mobilityAid: profile.mobilityAid,
        );
      case SuggestedChipAction.routeToWork:
      case SuggestedChipAction.scanBusSign:
        break; // Handled inside the chat panel itself.
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(profile.language);
    return Scaffold(
      // Deliberately minimal — a single icon, not a menu bar. See
      // MySettingsScreen's doc comment for why this exists at all.
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        automaticallyImplyLeading: false,
        toolbarHeight: 48,
        actions: [
          Semantics(
            button: true,
            label: d.settingsEntrySemantics,
            child: IconButton(
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => MySettingsScreen(profile: profile)),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // `Visibility` with `maintainState: true`, not a conditional
            // (`if (!_mapFullScreen) Expanded(...)`) — the latter would
            // unmount `ChatStreamPanel` entirely while the map is expanded,
            // tearing down its wake-word/STT session and losing the chat
            // scroll position, just to free up screen space. This keeps it
            // fully alive (still listening, if wake-word is on) but
            // invisible and zero-height, so the map's own `Expanded` below
            // is the *only* one actually taking space and fills the body.
            Visibility(
              visible: !_mapFullScreen,
              maintainState: true,
              maintainAnimation: true,
              child: Expanded(
                flex: 6,
                child: ChatStreamPanel(
                  profile: profile,
                  onOverlayChip: (action) => _handleOverlayChip(context, action),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: DashboardMapPanel(
                language: profile.language,
                isFullScreen: _mapFullScreen,
                onToggleFullScreen: () => setState(() => _mapFullScreen = !_mapFullScreen),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
