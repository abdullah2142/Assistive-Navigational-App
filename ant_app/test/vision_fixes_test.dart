// Found by the mock-user test run: a covered lens read as a clear path, and
// the explicit "which bus" scan was aborted by the bus itself.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';

void main() {
  for (final language in AppLanguage.values) {
    test('[${language.name}] the new spoken cues exist', () {
      final d = Dashboard.of(language);
      expect(d.visionTooDark.length, greaterThan(20));
      expect(d.visionStillLooking.length, greaterThan(10));
      expect(d.visionLookingNow.length, greaterThan(2));
    });
  }
}
