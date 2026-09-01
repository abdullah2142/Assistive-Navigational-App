import 'package:flutter/material.dart';

import '../../../core/localization/dashboard_strings.dart';

/// A quick-tap suggestion above the chat input, so a user with limited
/// dexterity or reading fatigue rarely has to type.
enum SuggestedChipAction { routeToWork, scanBusSign, showScreenToPasserby, reportHazard }

class SuggestedChip {
  const SuggestedChip({required this.action, required this.icon});

  final SuggestedChipAction action;
  final IconData icon;

  /// Localized label — resolved per-build from the current [Dashboard]
  /// instance rather than baked into the const list, so it follows whatever
  /// language is picked without needing a second chip list.
  String labelFor(Dashboard d) => switch (action) {
        SuggestedChipAction.routeToWork => d.chipRouteToWork,
        SuggestedChipAction.scanBusSign => d.chipScanBus,
        SuggestedChipAction.showScreenToPasserby => d.chipShowScreen,
        SuggestedChipAction.reportHazard => d.chipReportHazard,
      };
}

const List<SuggestedChip> kDefaultSuggestedChips = [
  SuggestedChip(action: SuggestedChipAction.routeToWork, icon: Icons.directions_rounded),
  SuggestedChip(action: SuggestedChipAction.scanBusSign, icon: Icons.document_scanner_rounded),
  SuggestedChip(action: SuggestedChipAction.showScreenToPasserby, icon: Icons.campaign_rounded),
  SuggestedChip(action: SuggestedChipAction.reportHazard, icon: Icons.warning_amber_rounded),
];
