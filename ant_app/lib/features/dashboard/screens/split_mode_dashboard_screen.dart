import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../onboarding/models/user_profile.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';
import '../widgets/chat_stream_panel.dart';
import '../widgets/crowdsource_reporting_hub.dart';
import '../widgets/dashboard_map_panel.dart';
import '../providers/chat_providers.dart';
import '../widgets/passerby_message_picker.dart';
import 'my_settings_screen.dart';

/// The Disabled User's home screen — Split-Mode Dashboard: chat (60%) over
/// a clean map with a giant directional arrow (40%), or the map alone at
/// full screen when expanded (see [_mapFullScreen]). See UI module plan
/// Step 2.
class SplitModeDashboardScreen extends ConsumerStatefulWidget {
  const SplitModeDashboardScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<SplitModeDashboardScreen> createState() => _SplitModeDashboardScreenState();
}

class _SplitModeDashboardScreenState extends ConsumerState<SplitModeDashboardScreen> {
  /// Share of the body height the chat panel takes when the map is not
  /// expanded — the "60% chat / 40% map" split from UI module plan Step 2.
  static const double _defaultChatFraction = 0.6;

  /// How much of the body the chat gets. Draggable — the right split
  /// depends on whether anyone is looking at the map at all, which varies by
  /// user and by moment, and a fixed 60/40 was reported as too rigid.
  ///
  /// Bounded so neither panel can be dragged out of existence: a map with no
  /// chat has no way back for someone who cannot see the map, and a chat
  /// with a sliver of map is worse than no map.
  double _chatFraction = _defaultChatFraction;
  static const double _minChatFraction = 0.25;
  static const double _maxChatFraction = 0.85;

  void _dragSplit(double deltaPixels, double bodyHeight) {
    if (bodyHeight <= 0) return;
    setState(() {
      _chatFraction = (_chatFraction + deltaPixels / bodyHeight)
          .clamp(_minChatFraction, _maxChatFraction);
    });
  }

  void _toggleMap() => setState(() {
        _mapVisible = !_mapVisible;
        // Leaving this set would bring the map back full-screen next time,
        // with no chat and no obvious way out.
        if (!_mapVisible) _mapFullScreen = false;
      });

  bool _mapFullScreen = false;

  /// Whether the map is on screen at all.
  ///
  /// Off by default. This dashboard is built for users who cannot see the
  /// map, so giving it half the screen from the start costs the chat — the
  /// part they actually use — for no benefit. A sighted companion, or a user
  /// with some vision, turns it on from the app bar.
  bool _mapVisible = false;

  /// Keeps one ChatStreamPanel State alive across the layout change.
  ///
  /// Toggling the map moves the panel between an `Expanded` and a
  /// `SizedBox`, which is a different widget type at the same slot — without
  /// a key Flutter discards the element and rebuilds the panel, dropping its
  /// wake-word/STT session and chat scroll position every time someone
  /// showed or hid the map.
  final GlobalKey _chatKey = GlobalKey();

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
    // A planned route reveals the map.
    //
    // The map is hidden by default because most of this app's users cannot
    // see it — but asking to be taken somewhere is the one moment it has
    // something to say, and a sighted companion or a low-vision user should
    // not have to know about a toggle to get at it. Only ever opens it, never
    // closes it, so someone who deliberately hid the map is not overruled on
    // their next route.
    //
    // Must sit directly in build(): ref.listen asserts if called from inside
    // a LayoutBuilder's builder, which is where this started.
    ref.listen(chatControllerProvider.select((s) => s.pendingRoute), (previous, next) {
      if (next == null || _mapVisible) return;
      setState(() => _mapVisible = true);
    });
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
            final chatPanel = ChatStreamPanel(
              key: _chatKey,
              profile: profile,
              onOverlayChip: (action, prefill) => _handleOverlayChip(context, action, prefill),
              mapVisible: _mapVisible,
              onToggleMap: _toggleMap,
            );
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
                if (!_mapVisible)
                  // Map off: the chat is the whole dashboard.
                  Expanded(child: chatPanel)
                else ...[
                  Offstage(
                    offstage: _mapFullScreen,
                    child: SizedBox(
                      height: constraints.maxHeight * _chatFraction,
                      child: chatPanel,
                    ),
                  ),
                  if (!_mapFullScreen)
                    _SplitHandle(
                      onDrag: (delta) => _dragSplit(delta, constraints.maxHeight),
                      semanticsLabel: d.mapResizeSemantics,
                      onNudge: (delta) => _dragSplit(delta, constraints.maxHeight),
                    ),
                  Expanded(
                    child: DashboardMapPanel(
                      language: profile.language,
                      isFullScreen: _mapFullScreen,
                      onToggleFullScreen: () => setState(() => _mapFullScreen = !_mapFullScreen),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The grab bar between the chat and the map.
///
/// Also operable without dragging: a blind or low-vision user gets increase/
/// decrease actions through the semantics layer, because a drag target is
/// the one control shape a screen reader cannot work by itself.
class _SplitHandle extends StatelessWidget {
  const _SplitHandle({required this.onDrag, required this.onNudge, required this.semanticsLabel});

  final void Function(double deltaPixels) onDrag;
  final void Function(double deltaPixels) onNudge;
  final String semanticsLabel;

  /// One step of the keyboard/screen-reader adjustment.
  static const double _nudge = 48;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      slider: true,
      onIncrease: () => onNudge(_nudge),
      onDecrease: () => onNudge(-_nudge),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) => onDrag(details.delta.dy),
        child: SizedBox(
          height: 24,
          child: Center(
            child: Container(
              width: 44,
              height: 5,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
