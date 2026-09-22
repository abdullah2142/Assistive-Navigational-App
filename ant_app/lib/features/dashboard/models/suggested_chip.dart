import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';

/// A quick-tap suggestion above the chat input, so a user with limited
/// dexterity or reading fatigue rarely has to type.
/// The overlays and quick actions the chat can hand back to the dashboard.
///
/// [sendCaretakerVoiceMemo] has no chip of its own — it is reached by asking
/// for it out loud. It rides on this enum because the dashboard is what owns
/// a `BuildContext`, and recording needs one; the executor cannot open a
/// recorder from where it sits.
enum SuggestedChipAction {
  routeToWork,
  // Module 6's wide "what's around me" sweep deliberately has **no chip**.
  //
  // It was built with one and the chip was removed: five permanent chips
  // become six once a caretaker is paired, and `SuggestedChipRow` is built so
  // that never becomes a third row — "a third row would eat the chat above
  // it". A row of four cells at Dhaka-typical text scales is not a tappable
  // target either.
  //
  // Nothing is lost. The sweep is reachable by asking for it out loud, by
  // holding Volume Up (`MainActivity.SWEEP_HOLD_MS`), and by the assistant
  // calling `look_around` — three routes, none of which needs sight, which is
  // more than the chip offered a user who cannot see it.
  scanBusSign,
  showScreenToPasserby,
  reportHazard,
  sendCaretakerVoiceMemo,

  /// Item 51 — asking for the map. Neither has a chip: the map already has a
  /// button on the input row, and these exist so it can be asked for out
  /// loud, which is the only way a user who cannot see that button has.
  showMap,
  hideMap,
}

class SuggestedChip {
  const SuggestedChip({required this.action, required this.icon});

  final SuggestedChipAction action;
  final IconData icon;

  /// What a screen reader announces, which is not always what is printed.
  ///
  /// A chip's visible label has to fit a cell; a spoken one has no such
  /// limit and should say the whole thing. Only the chips whose printed text
  /// had to be shortened override this.
  String semanticsLabelFor(Dashboard d) => switch (action) {
        SuggestedChipAction.showScreenToPasserby => d.chipShowScreenSemantics,
        _ => labelFor(d),
      };

  /// Localized label — resolved per-build from the current [Dashboard]
  /// instance rather than baked into the const list, so it follows whatever
  /// language is picked without needing a second chip list.
  String labelFor(Dashboard d) => switch (action) {
        SuggestedChipAction.routeToWork => d.chipRouteToWork,
        SuggestedChipAction.scanBusSign => d.chipScanBus,
        SuggestedChipAction.showScreenToPasserby => d.chipShowScreen,
        SuggestedChipAction.reportHazard => d.chipReportHazard,
        SuggestedChipAction.sendCaretakerVoiceMemo => d.chipVoiceMemo,
        SuggestedChipAction.showMap => d.mapShowSemantics,
        SuggestedChipAction.hideMap => d.mapHideSemantics,
      };
}

const List<SuggestedChip> kDefaultSuggestedChips = [
  SuggestedChip(action: SuggestedChipAction.routeToWork, icon: Icons.directions_rounded),
  SuggestedChip(action: SuggestedChipAction.scanBusSign, icon: Icons.document_scanner_rounded),
  SuggestedChip(action: SuggestedChipAction.showScreenToPasserby, icon: Icons.campaign_rounded),
  SuggestedChip(action: SuggestedChipAction.reportHazard, icon: Icons.warning_amber_rounded),
];

/// The chip for sending a caretaker a voice message.
///
/// Appended rather than folded into [kDefaultSuggestedChips] because it is
/// conditional — see [suggestedChipsFor].
const SuggestedChip kVoiceMemoChip =
    SuggestedChip(action: SuggestedChipAction.sendCaretakerVoiceMemo, icon: Icons.mic_rounded);

/// The chips to show this user.
///
/// The voice-message chip appears **only when a caretaker is paired**. A chip
/// that is always there and fails for most users is worse than no chip: it
/// costs a row of space permanently, and for a screen-reader user it is a
/// control that reads as available and then explains it cannot work. The
/// assistant can still be *asked* for a voice message at any time — it
/// answers by saying how to pair — but the visible shortcut is only offered
/// once there is somebody on the other end of it.
///
/// This is also what makes the feature discoverable at all. Until now it was
/// reachable only by already knowing a phrase, which for a blind user means
/// not reachable.
List<SuggestedChip> suggestedChipsFor({required bool caretakerPaired}) => [
      ...kDefaultSuggestedChips,
      if (caretakerPaired) kVoiceMemoChip,
    ];
