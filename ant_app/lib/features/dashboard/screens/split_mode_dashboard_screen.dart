import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../guardian/providers/guardian_providers.dart';
import '../../guardian/services/live_location_publisher.dart';
import '../../onboarding/models/user_role.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../onboarding/models/user_profile.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';
import '../widgets/chat_stream_panel.dart';
import '../widgets/caretaker_voice_memo_overlay.dart';
import '../widgets/crowdsource_reporting_hub.dart';
import '../widgets/caretaker_inbox_listener.dart';
import '../widgets/dashboard_map_panel.dart';
import '../providers/chat_providers.dart';
import '../widgets/destination_sheet.dart';
import '../widgets/passerby_message_picker.dart';
import 'map_pin_picker_screen.dart';
import 'my_settings_screen.dart';

/// The Disabled User's home screen — Split-Mode Dashboard: chat (60%) over
/// a clean map with a giant directional arrow (40%), or the map alone at
/// full screen when expanded (see [_mapFullScreen]). See UI module plan
/// Step 2.
class SplitModeDashboardScreen extends ConsumerStatefulWidget {
  const SplitModeDashboardScreen({super.key, required this.profile});

  final UserProfile profile;

  @override
  ConsumerState<SplitModeDashboardScreen> createState() =>
      _SplitModeDashboardScreenState();
}

class _SplitModeDashboardScreenState
    extends ConsumerState<SplitModeDashboardScreen> {
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
      _chatFraction = (_chatFraction + deltaPixels / bodyHeight).clamp(
        _minChatFraction,
        _maxChatFraction,
      );
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

  @override
  void initState() {
    super.initState();
    _syncLocationPublishing();
  }

  @override
  void didUpdateWidget(SplitModeDashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pairing happens mid-session — "pair with my caretaker" is a chat
    // command — so the publisher cannot be started once and forgotten.
    if (oldWidget.profile.uid != profile.uid ||
        oldWidget.profile.pairedUserId != profile.pairedUserId) {
      _syncLocationPublishing();
    }
  }

  /// Held rather than read back in [dispose]: `ref` is unsafe once the
  /// widget is being unmounted, which is the only moment this is needed.
  LiveLocationPublisher? _locationPublisher;

  @override
  void dispose() {
    _locationPublisher?.stop();
    super.dispose();
  }

  /// Item 58 — "caretaker doesnt get location".
  ///
  /// Nothing published this except the emergency sequence, so a caretaker
  /// could see where someone was only once they had already triggered an
  /// SOS. Started here because this screen is the disabled user's session:
  /// it is on screen for as long as the app is being used by the person
  /// whose location it is.
  void _syncLocationPublishing() {
    if (profile.role != UserRole.disabledUser) return;
    final LiveLocationPublisher publisher =
        _locationPublisher ?? ref.read(liveLocationPublisherProvider);
    _locationPublisher = publisher;
    publisher.start(uid: profile.uid, isPaired: profile.pairedUserId != null);
  }

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
      case SuggestedChipAction.sendCaretakerVoiceMemo:
        final caretakerUid = profile.pairedUserId;
        // The executor already refuses this when nobody is paired and says
        // so; the guard is here because a profile can change between the
        // call and the overlay opening.
        if (caretakerUid == null) break;
        await CaretakerVoiceMemoOverlay.show(
          context,
          disabledUserUid: profile.uid,
          caretakerUid: caretakerUid,
          strings: d,
          language: profile.language,
        );
      // Item 51 — "map on koro doesnt open the map, in fact map does not auto
      // open". It opened itself when a route was planned and closed when one
      // was cleared, and between those two moments there was no way to ask
      // for it at all, in any language. The button on the input row is no use
      // to somebody who cannot see it.
      case SuggestedChipAction.showMap:
        if (!_mapVisible) setState(() => _mapVisible = true);
      case SuggestedChipAction.hideMap:
        if (_mapVisible) {
          setState(() {
            _mapVisible = false;
            _mapFullScreen = false;
          });
        }
      case SuggestedChipAction.cameraScan:
        break; // Handled inside the chat panel itself.
      case SuggestedChipAction.openPath:
        unawaited(_openPathSheet());
    }
  }

  /// The destination sheet — search, pin, speak or type — and what to do
  /// with what it hands back.
  ///
  /// A named place goes through `sendFreeText` rather than straight to the
  /// router, deliberately: that is the path with the destination
  /// clarification conversation on it ("which Gulshan?"), the saved-place
  /// matcher, and the transcript entry. Bypassing it to save one hop would
  /// mean a place typed here resolves by different rules than the same place
  /// spoken at the main microphone, and only one of the two would ask when
  /// it was unsure.
  ///
  /// A **pin** cannot take that path — it has no name to send, and inventing
  /// one ("23.81, 90.41") would be handed to a geocoder that has no idea
  /// what to do with it. It goes to the router as coordinates.
  Future<void> _openPathSheet() async {
    final choice = await showModalBottomSheet<DestinationChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (_) =>
          DestinationSheet(profile: profile, onPickOnMap: _pickOnMap),
    );
    if (choice == null || !mounted) return;

    final controller = ref.read(chatControllerProvider.notifier);
    if (choice.isPin) {
      await controller.routeToCoordinates(
        latitude: choice.latitude!,
        longitude: choice.longitude!,
        profile: profile,
      );
      return;
    }
    final text = choice.text?.trim() ?? '';
    if (text.isEmpty) return;
    await controller.sendFreeText(text, profile);
  }

  /// Opens the full-screen pin picker, centred on the user when their
  /// position is already known.
  ///
  /// The fix is best-effort and short: this is the map's opening camera, not
  /// a navigation fix, and a picker that hangs on a GPS lock before it will
  /// draw anything is worse than one that opens over Dhaka.
  Future<DestinationChoice?> _pickOnMap() async {
    LatLng? centre;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) centre = LatLng(last.latitude, last.longitude);
    } catch (e) {
      debugPrint('[Map] pin picker could not read a last-known position: $e');
    }
    if (!mounted) return null;
    return Navigator.of(context).push<DestinationChoice>(
      MaterialPageRoute(
        builder: (_) => MapPinPickerScreen(
          language: profile.language,
          initialCentre: centre,
          savedPlaces: profile.savedPlaces,
        ),
      ),
    );
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
    ref.listen(chatControllerProvider.select((s) => s.pendingRoute), (
      previous,
      next,
    ) {
      // The route going away closes the map again.
      //
      // It used to only ever open it, on the reasoning that somebody who
      // deliberately hid the map should not be overruled. That is right for a
      // *rebuild*, and wrong for a cancellation: reported directly, "map
      // should close if user says the trip is cancelled, right now it remains
      // still". A map showing nothing is a map taking half the screen for
      // nothing.
      if (next == null) {
        if (previous != null && _mapVisible) {
          setState(() {
            _mapVisible = false;
            _mapFullScreen = false;
          });
        }
        return;
      }
      if (_mapVisible || !profile.autoOpenMapOnRoute) return;
      setState(() => _mapVisible = true);
    });
    // Wraps the whole dashboard so the caretaker's messages keep arriving
    // while the user is anywhere in it. Renders nothing of its own — delivery
    // is into the chat stream, spoken. See `CaretakerInboxListener`.
    return CaretakerInboxListener(
      profile: widget.profile,
      child: Scaffold(
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
                  MaterialPageRoute(
                    builder: (_) => MySettingsScreen(profile: profile),
                  ),
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
                onOverlayChip: (action, prefill) =>
                    _handleOverlayChip(context, action, prefill),
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
                        onDrag: (delta) =>
                            _dragSplit(delta, constraints.maxHeight),
                        semanticsLabel: d.mapResizeSemantics,
                        onNudge: (delta) =>
                            _dragSplit(delta, constraints.maxHeight),
                      ),
                    Expanded(
                      child: DashboardMapPanel(
                        language: profile.language,
                        isFullScreen: _mapFullScreen,
                        onToggleFullScreen: () =>
                            setState(() => _mapFullScreen = !_mapFullScreen),
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
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
  const _SplitHandle({
    required this.onDrag,
    required this.onNudge,
    required this.semanticsLabel,
  });

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
