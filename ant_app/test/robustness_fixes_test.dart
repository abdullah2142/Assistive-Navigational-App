// Fixes found by the mock-user test run, each of which left a user stranded.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/emergency_plan.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';

void main() {
  test('a phone number dictated in Bengali digits is still dialable', () {
    expect(EmergencyPlan.normalise('০১৭১১১১১১১১'), '01711111111');
    expect(EmergencyPlan.isDialable('০১৭১১-১১১১১১'), isTrue);
    expect(EmergencyPlan.normalise('+৮৮০১৭১১১১১১১১'), '+8801711111111');
  });

  test('"don\'t cancel" does not cancel an emergency', () {
    expect(VoiceCancelWindow.cancelsEmergency("don't cancel"), isFalse);
    expect(VoiceCancelWindow.cancelsEmergency('do not cancel it'), isFalse);
    expect(VoiceCancelWindow.cancelsEmergency('cancel'), isTrue);
  });

  for (final l in AppLanguage.values) {
    test('[${l.name}] new spoken lines exist', () {
      final d = Dashboard.of(l);
      expect(d.navigateLocationLost.length, greaterThan(20));
      expect(d.commandFailedReply.length, greaterThan(10));
      expect(d.emergencyAboutCaretaker(5), contains('5'));
    });
  }
}
