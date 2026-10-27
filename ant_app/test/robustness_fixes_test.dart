// Fixes found by the mock-user test run, each of which left a user stranded.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/emergency_plan.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/offline_intent_matcher.dart';
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

  group('distress without a cry word raises the SOS', () {
    for (final p in [
      "i can't breathe", 'i cannot breathe', 'please call an ambulance',
      'i am bleeding badly', 'i fell down and cannot get up',
      'he has a knife', 'please save my life', 'help he has a knife',
    ]) {
      test('"$p"', () {
        expect(LocalIntentMatcher.match(p, AppLanguage.english)?.name, 'trigger_emergency');
      });
    }
    for (final p in ['আমি পড়ে গেছি', 'এম্বুলেন্স ডাকো', 'রক্ত পড়ছে']) {
      test('"$p"', () {
        expect(LocalIntentMatcher.match(p, AppLanguage.bangla)?.name, 'trigger_emergency');
      });
    }
    for (final p in ['i fell asleep on the bus', 'the ambulance station is near', 'take me to the hospital', 'that helps', 'my nose is not bleeding']) {
      test('not an alarm: "$p"', () {
        expect(LocalIntentMatcher.match(p, AppLanguage.english)?.name, isNot('trigger_emergency'));
      });
    }
    test('offline still answers a distress phrase', () {
      expect(OfflineIntentMatcher.match("i can't breathe", AppLanguage.english), isNotNull);
    });
  });
}
