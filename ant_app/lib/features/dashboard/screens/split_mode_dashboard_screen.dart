import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../onboarding/models/user_profile.dart';
import '../models/hazard_report.dart';
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
  /// Share of the body height the chat panel takes when the map is not
  /// expanded — the "60% chat / 40% map" split from UI module plan Step 2.
  static const double _chatFlex = 0.6;

  bool _mapFullScreen = false;

  UserProfile get profile => widget.profile;

  Future<void> _handleOverlayChip(
    BuildContext context,
    SuggestedChipAction action,
    HazardReportPrefill? hazardPrefill,
  ) async {
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
          prefill: hazardPrefill,
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
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Column(
              children: [
                // NOT `Visibility(child: Expanded(...))`. `Expanded` is a
                // ParentDataWidget and must be a *direct* child of the
                // `Column` — wrapping it in anything else (Visibility
                // inserts its own render object) throws "Incorrect use of
                // ParentDataWidget", which takes the entire body subtree
                // down with it and leaves a black dashboard under a
                // perfectly working AppBar. That was a real, live bug.
                //
                // `Offstage` around an explicitly-sized box does the job
                // the `Visibility(maintainState: true)` was there for,
                // safely: the panel stays mounted and laid out (its
                // wake-word/STT session keeps running and the chat scroll
                // position survives) but is not painted, not hit-tested,
                // and takes zero room in the Column — so the map's
                // `Expanded` below is the only child claiming space and
                // fills the whole body when expanded.
                Offstage(
                  offstage: _mapFullScreen,
                  child: SizedBox(
                    height: constraints.maxHeight * _chatFlex,
                    child: ChatStreamPanel(
                      profile: profile,
                      onOverlayChip: (action, prefill) => _handleOverlayChip(context, action, prefill),
                    ),
                  ),
                ),
                Expanded(
                  child: DashboardMapPanel(
                    language: profile.language,
                    isFullScreen: _mapFullScreen,
                    onToggleFullScreen: () => setState(() => _mapFullScreen = !_mapFullScreen),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
