// The text a frightened relative receives at 11pm. Pinned here because it
// is assembled at the one moment nobody is watching, and because a message
// that arrives in two parts can arrive as one.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/emergency_payload.dart';

void main() {
  List<String> msgs(AppLanguage language,
          {String? name = 'Rahim', double? lat = 23.7808, double? lng = 90.4142, int? battery = 42}) =>
      EmergencyPayload.messages(
        language: language,
        name: name,
        lat: lat,
        lng: lng,
        batteryPercent: battery,
      );

  String body(AppLanguage language,
          {String? name = 'Rahim', double? lat = 23.7808, double? lng = 90.4142, int? battery = 42}) =>
      msgs(language, name: name, lat: lat, lng: lng, battery: battery).join(' ');

  group('the message says the things a recipient can act on', () {
    test('English names who, battery, and where', () {
      final s = body(AppLanguage.english);
      expect(s, contains('EMERGENCY'));
      expect(s, contains('Rahim'));
      expect(s, contains('42%'));
      expect(s, contains('https://maps.google.com/?q=23.780800,90.414200'));
    });

    test('Bangla is Bangla, not English with a translated first word', () {
      final s = body(AppLanguage.bangla);
      expect(RegExp(r'[ঀ-৿]').hasMatch(s), isTrue);
      expect(s, contains('42%'));
      expect(s, contains('maps.google.com'));
    });

    test('an unnamed user still gets a usable message', () {
      expect(body(AppLanguage.english, name: null), contains('I need help'));
      expect(body(AppLanguage.english, name: '   '), contains('I need help'));
    });
  });

  group('missing data is stated, not hidden', () {
    test('no location says so rather than going quiet', () {
      final s = body(AppLanguage.english, lat: null, lng: null);
      expect(s, contains('Location unavailable'));
      expect(s, isNot(contains('maps.google.com')));
    });

    test('no battery reading is simply omitted, never guessed', () {
      final s = body(AppLanguage.english, battery: null);
      expect(s, isNot(contains('%')));
      expect(s, contains('EMERGENCY'));
    });

    test('nothing available at all is still an emergency message', () {
      final s = body(AppLanguage.english, name: null, lat: null, lng: null, battery: null);
      expect(s, contains('EMERGENCY'));
      expect(s.trim(), isNotEmpty);
    });
  });

  group('the location link is usable by anyone', () {
    test('opens without our infrastructure, or any particular app', () {
      final link = EmergencyPayload.mapsLink(23.7808, 90.4142);
      // No shortener, no deep link, no domain of ours — in an emergency the
      // link must not depend on a service of ours still being up.
      expect(link, startsWith('https://maps.google.com/?q='));
      expect(link, isNot(contains('ant')));
    });

    test('precision is well past GPS accuracy, so rounding never moves the pin', () {
      expect(EmergencyPayload.mapsLink(23.78, 90.41), contains('23.780000,90.410000'));
    });

    test('southern and western hemispheres survive formatting', () {
      expect(EmergencyPayload.mapsLink(-33.8688, -151.2093), contains('-33.868800,-151.209300'));
    });
  });

  group('every message sent is individually one SMS part', () {
    // A concatenated message can arrive out of order, late, or half-lost on
    // a congested network — and the half that would go missing is the tail,
    // which carries the location. So each message is complete on its own.
    test('Bangla splits into an alert and an ASCII location, both single-part', () {
      final parts = msgs(AppLanguage.bangla);
      expect(parts.length, 2, reason: 'got ${parts.length}: $parts');
      expect(RegExp(r'[ঀ-৿]').hasMatch(parts.first), isTrue);
      expect(parts.last, startsWith('Location: https://maps.google.com/'));
      for (final p in parts) {
        expect(EmergencyPayload.fitsOnePart(p), isTrue,
            reason: '${p.runes.length} of ${EmergencyPayload.limitFor(p)}: $p');
      }
    });

    test('the ASCII location message gets the roomier GSM-7 limit', () {
      final parts = msgs(AppLanguage.bangla);
      expect(EmergencyPayload.limitFor(parts.last), EmergencyPayload.singlePartGsm7);
    });

    test('Bangla with no location needs only one message', () {
      final parts = msgs(AppLanguage.bangla, lat: null, lng: null);
      expect(parts.length, 1);
      expect(EmergencyPayload.fitsOnePart(parts.single), isTrue);
    });

    test('an absurdly long name is dropped rather than split', () {
      final parts = msgs(AppLanguage.bangla, name: 'মোহাম্মদ আব্দুর রহমান চৌধুরী সাহেব আলম');
      for (final p in parts) {
        expect(EmergencyPayload.fitsOnePart(p), isTrue,
            reason: '${p.runes.length} of ${EmergencyPayload.limitFor(p)}: $p');
      }
    });

    test('English carries everything in a single message', () {
      final parts = msgs(AppLanguage.english);
      expect(parts.length, 1, reason: 'got $parts');
      expect(EmergencyPayload.fitsOnePart(parts.single), isTrue);
    });

    test('English with a long name still fits one message', () {
      final parts = msgs(AppLanguage.english, name: 'Mohammad Abdur Rahman Chowdhury');
      expect(parts.length, 1);
      expect(EmergencyPayload.fitsOnePart(parts.single), isTrue,
          reason: '${parts.single.runes.length}: ${parts.single}');
    });
  });

  group('legacy shape checks', () {
    // A second part can arrive late, out of order, or not at all on a
    // congested network — and the part carrying the location is the one
    // that would be lost.
    test('the location link is last, so a lost tail still warns them', () {
      for (final language in AppLanguage.values) {
        final s = body(language);
        expect(s.indexOf('maps.google.com'), greaterThan(s.length ~/ 2),
            reason: 'link should be at the end for $language');
      }
    });
  });
}
