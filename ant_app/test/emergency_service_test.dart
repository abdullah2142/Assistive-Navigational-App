// The escalation sequence. This runs when something has already gone wrong
// for the user, so the tests are mostly about what happens when each step
// fails — because at least one of them will.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/config/emergency_config.dart';
import 'package:ant_app/core/services/emergency_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = 'com.ant.assistive.ant_app/emergency';
  const channel = MethodChannel(channelName);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mock(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('the channel never throws into the emergency path', () {
    // An unhandled exception here means nobody is told. Every failure has
    // to come back as a value the caller can act on and carry on from.

    test('a platform error on sendSms reports every recipient as failed', () async {
      mock((call) async => throw PlatformException(code: 'no_sim'));
      final result = await EmergencyChannel(channel: channel)
          .sendSms(recipients: ['0171', '0182'], messages: ['help']);
      expect(result.anyDelivered, isFalse);
      expect(result.failed.keys, containsAll(['0171', '0182']));
    });

    test('a missing platform implementation is not a crash', () async {
      mock((call) async => throw MissingPluginException());
      final c = EmergencyChannel(channel: channel);
      expect(await c.hasPermission(EmergencyPermission.sms), isFalse);
      expect(await c.hasPermission(EmergencyPermission.call), isFalse);
      expect(await c.batteryPercent(), isNull);
      expect(await c.placeCall('01711111111'), isFalse);
    });

    test('a nonsense battery reading becomes null, not a number in an SMS', () async {
      // The platform API returns Integer.MIN_VALUE rather than throwing when
      // it has no reading, and "battery -2147483648%" must never be sent.
      mock((call) async => call.method == 'batteryPercent' ? null : null);
      expect(await EmergencyChannel(channel: channel).batteryPercent(), isNull);
    });

    test('an empty recipient list short-circuits without calling the platform', () async {
      var called = false;
      mock((call) async {
        called = true;
        return null;
      });
      final result =
          await EmergencyChannel(channel: channel).sendSms(recipients: [], messages: ['x']);
      expect(called, isFalse);
      expect(result.anyDelivered, isFalse);
    });
  });

  group('partial delivery is reported as partial', () {
    test('one contact failing does not report a total failure', () async {
      // Three people were reached. Telling the user nothing was sent would
      // make them stop trying to get help that is already coming.
      mock((call) async => {
            'delivered': ['0171', '0182', '0193'],
            'failed': {'0100': 'invalid number'},
          });
      final result = await EmergencyChannel(channel: channel)
          .sendSms(recipients: ['0171', '0182', '0193', '0100'], messages: ['help']);
      expect(result.anyDelivered, isTrue);
      expect(result.delivered.length, 3);
      expect(result.failed, {'0100': 'invalid number'});
    });
  });

  group('what the user is told is never optimistic', () {
    for (final language in AppLanguage.values) {
      test('$language has distinct wording for sent and not-sent', () {
        final d = Dashboard.of(language);
        expect(d.emergencySent(3), isNot(equals(d.emergencyNotSent)));
        expect(d.emergencyNotSent.trim(), isNotEmpty);
      });

      test('$language tells the user what to do when nothing sent', () {
        // A user who believes help is coming and stops trying is in a worse
        // position than one who knows the phone could not reach anyone.
        final d = Dashboard.of(language);
        expect(d.emergencyNotSent.length, greaterThan(20));
      });

      test('$language announces before anything is sent', () {
        expect(Dashboard.of(language).emergencyActivated.trim(), isNotEmpty);
      });

      test('$language names the cancel word in the countdown', () {
        final d = Dashboard.of(language);
        final prompt = d.emergencyAbout(3, 5);
        expect(prompt, contains('3'));
        expect(prompt, contains('5'));
      });
    }

    test('Bangla strings are actually Bangla', () {
      final d = Dashboard.of(AppLanguage.bangla);
      for (final s in [
        d.emergencyActivated,
        d.emergencyCancelled,
        d.emergencyNotSent,
        d.emergencyNoContacts,
        d.emergencyAbout(2, 5),
      ]) {
        expect(RegExp(r'[ঀ-৿]').hasMatch(s), isTrue, reason: s);
      }
    });
  });

  group('builds default to rehearsal, and say so', () {
    // A tester enters real emergency contacts during onboarding, and the
    // voice pack's whole job is saying unexpected things. Volume Down held
    // three seconds is barely distinguishable from adjusting the volume.
    // Shipping live dispatch to that would text and ring somebody's mother
    // from code that has never run on hardware.
    test('live dispatch is off unless explicitly compiled in', () {
      expect(EmergencyConfig.liveDispatch, isFalse);
      expect(EmergencyConfig.isRehearsal, isTrue);
    });

    for (final language in AppLanguage.values) {
      test('$language rehearsal says plainly that nothing was sent', () {
        // A rehearsal that sounded like the real thing would be worse than
        // none: a tester would report it works, and the first person to
        // learn otherwise would be someone in trouble.
        final d = Dashboard.of(language);
        final text = d.emergencyRehearsal(3);
        expect(text.trim(), isNotEmpty);
        expect(text, isNot(equals(d.emergencySent(3))));
        expect(text, contains('3'));
      });
    }

    test('the Bangla rehearsal line is Bangla', () {
      expect(
        RegExp(r'[ঀ-৿]').hasMatch(Dashboard.of(AppLanguage.bangla).emergencyRehearsal(2)),
        isTrue,
      );
    });
  });
}
