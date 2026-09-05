// Who gets messaged and who gets called. This decides whether anyone
// actually comes, and it runs at the moment nobody can check it.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/emergency_plan.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';

void main() {
  TrustedContact c(String name, String phone, {bool primary = false}) =>
      TrustedContact(name: name, phoneNumber: phone, isPrimary: primary);

  group('numbers as people actually dictate them', () {
    test('spaces, dashes and brackets are stripped', () {
      // Onboarding captures these by voice, so what is stored contains
      // whatever separators the read-back accepted.
      expect(EmergencyPlan.normalise('017 1234-5678'), '01712345678');
      expect(EmergencyPlan.normalise('(017) 1234 5678'), '01712345678');
      expect(EmergencyPlan.normalise('  01712345678  '), '01712345678');
    });

    test('a leading country code survives', () {
      expect(EmergencyPlan.normalise('+880 1712 345678'), '+8801712345678');
    });

    test('a plus anywhere else is not treated as a country code', () {
      expect(EmergencyPlan.normalise('017+1234'), '0171234');
    });
  });

  group('what counts as dialable', () {
    test('real Bangladeshi mobile numbers, local and international', () {
      expect(EmergencyPlan.isDialable('01712345678'), isTrue);
      expect(EmergencyPlan.isDialable('+8801712345678'), isTrue);
      expect(EmergencyPlan.isDialable('999'), isFalse);
    });

    test('blanks and junk are rejected', () {
      expect(EmergencyPlan.isDialable(''), isFalse);
      expect(EmergencyPlan.isDialable('   '), isFalse);
      expect(EmergencyPlan.isDialable('not a number'), isFalse);
    });

    test('the bar stays low on purpose', () {
      // Refusing to try a number in an emergency is far worse than trying
      // one that fails, so anything plausibly a phone number is accepted.
      expect(EmergencyPlan.isDialable('+44 20 7123 4567'), isTrue);
      expect(EmergencyPlan.isDialable('0171234'), isTrue);
    });
  });

  group('who gets the SMS', () {
    test('the primary contact is messaged first', () {
      // Dispatch is sequential; a phone that dies partway through should
      // have reached the most important person already.
      final list = EmergencyPlan.smsRecipients([
        c('Rakib', '01822222222'),
        c('Ma', '01711111111', primary: true),
        c('Bon', '01933333333'),
      ]);
      expect(list.first, '01711111111');
      expect(list.length, 3);
    });

    test('the same person saved twice is messaged once', () {
      // Two messages reads as a malfunction and costs the recipient time
      // working out whether something happened twice.
      final list = EmergencyPlan.smsRecipients([
        c('Ma', '01711111111', primary: true),
        c('Mother', '017 1111 1111'),
      ]);
      expect(list, ['01711111111']);
    });

    test('unusable numbers are skipped without dropping the rest', () {
      final list = EmergencyPlan.smsRecipients([
        c('Broken', ''),
        c('Ma', '01711111111', primary: true),
        c('Junk', 'call me'),
        c('Rakib', '01822222222'),
      ]);
      expect(list, ['01711111111', '01822222222']);
    });

    test('no usable contacts gives an empty list, not a crash', () {
      expect(EmergencyPlan.smsRecipients([]), isEmpty);
      expect(EmergencyPlan.smsRecipients([c('Broken', '')]), isEmpty);
    });
  });

  group('who gets called', () {
    test('the explicit primary', () {
      final target = EmergencyPlan.callTarget([
        c('Rakib', '01822222222'),
        c('Ma', '01711111111', primary: true),
      ]);
      expect(target, '01711111111');
    });

    test('nobody marked primary still gets a call placed', () {
      // Onboarding does not force the choice, so this cannot assume it was
      // made — "no primary" must not silently mean "no call".
      final target = EmergencyPlan.callTarget([
        c('Rakib', '01822222222'),
        c('Bon', '01933333333'),
      ]);
      expect(target, '01822222222');
    });

    test('a primary with an unusable number falls through to someone real', () {
      final target = EmergencyPlan.callTarget([
        c('Ma', '', primary: true),
        c('Rakib', '01822222222'),
      ]);
      expect(target, '01822222222');
    });

    test('nobody to call is null, not an empty string', () {
      expect(EmergencyPlan.callTarget([]), isNull);
      expect(EmergencyPlan.callTarget([c('Broken', 'x')]), isNull);
    });
  });
}
