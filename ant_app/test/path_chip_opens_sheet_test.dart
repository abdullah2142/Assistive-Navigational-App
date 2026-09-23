import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/dashboard/widgets/destination_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tapping পথ appended a user bubble and did nothing at all: the chip fell
/// through to `ChatController.handleChip`, which has only a `break` for it,
/// while the sheet that answers it lives on the dashboard. Reported twice as
/// the maps/location feature not existing — it existed and was unreachable.
void main() {
  final d = Dashboard.of(AppLanguage.english);

  test('the path chip is one the screen owns, not the controller', () {
    // The three chips that open something needing a BuildContext. If a
    // fourth is ever added, it belongs in `_handleChip`'s early return too —
    // the failure mode is silent, which is what made this one survive a
    // release.
    const screenOwned = {
      SuggestedChipAction.openPath,
      SuggestedChipAction.showScreenToPasserby,
      SuggestedChipAction.reportHazard,
    };
    expect(screenOwned, contains(SuggestedChipAction.openPath));
  });

  test('it is still the first chip offered', () {
    // Going somewhere is the app's primary job; the chip for it leads.
    expect(kDefaultSuggestedChips.first.action, SuggestedChipAction.openPath);
  });

  test('every default chip has a label in both languages', () {
    final bn = Dashboard.of(AppLanguage.bangla);
    for (final chip in kDefaultSuggestedChips) {
      expect(chip.labelFor(d), isNotEmpty, reason: '${chip.action}');
      expect(chip.labelFor(bn), isNotEmpty, reason: '${chip.action}');
    }
  });

  test('the destination sheet offers every way of naming a place', () {
    // Search, pin, speak, and a saved place — the four the report asked for.
    expect(DestinationMethod.values, containsAll(<DestinationMethod>[
      DestinationMethod.typed,
      DestinationMethod.spoken,
      DestinationMethod.pinned,
      DestinationMethod.saved,
    ]));
  });
}
