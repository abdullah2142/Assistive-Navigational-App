import 'dart:io';

import 'package:ant_app/core/config/diagnostics_config.dart';
import 'package:ant_app/core/diagnostics/log_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

/// Static, offline checks of the security surface. Rules are read as text
/// because no rules emulator is available; each check asserts a protection
/// that was verified line by line to exist today.
String rules() => File('../firestore.rules').readAsStringSync();

/// The text of one `match /<path>` block, up to the closing brace at the same
/// indentation (four spaces).
String block(String src, String header) {
  final start = src.indexOf(header);
  expect(start, greaterThanOrEqualTo(0), reason: 'no block $header');
  final end = src.indexOf('\n    }\n', start);
  return src.substring(start, end);
}

void main() {
  group('firestore.rules: server-only collections', () {
    for (final h in [
      'match /busRoutes/{routeNumber}',
      'match /hazardZones/{zoneId}',
      'match /crimeZones/{thanaId}',
      'match /thanaAdvisories/{advisoryId}',
      'match /socialSignals/{signalId}',
      'match /thanaIncidents/{incidentId}',
      'match /cityTrend/{period}',
      'match /meta/{docId}',
    ]) {
      test('$h denies every client write', () {
        final b = block(rules(), h);
        expect(b, contains('allow write: if false;'));
        expect(RegExp(r'allow (create|update|delete)').hasMatch(b), isFalse);
      });
    }

    test('hazardReports: create only under own reporterUid, no update/delete', () {
      final b = block(rules(), 'match /hazardReports/{reportId}');
      expect(b, contains('request.auth.uid == request.resource.data.reporterUid'));
      expect(b, contains('allow update, delete: if false;'));
    });
  });

  group('firestore.rules: private data', () {
    test('liveLocations: only the owner writes, reads need ownership or pairing', () {
      final b = block(rules(), 'match /liveLocations/{disabledUserUid}');
      expect(b, contains('allow write: if request.auth != null && request.auth.uid == disabledUserUid;'));
      expect(b, contains('isPairedCaretaker(disabledUserUid)'));
    });

    test('alerts: caretaker may only flip resolved/resolvedAt, nobody deletes', () {
      final b = block(rules(), 'match /alerts/{disabledUserUid}/items/{alertId}');
      expect(b, contains("hasOnly(['resolved', 'resolvedAt'])"));
      expect(b, isNot(contains('delete')));
    });

    test('communications: sender must be the authenticated uid; no update/delete', () {
      final b = block(rules(), 'match /communications/{disabledUserUid}/messages/{messageId}');
      expect(b, contains('request.auth.uid == request.resource.data.fromUid'));
      expect(RegExp(r'allow (update|delete)').hasMatch(b), isFalse);
    });

    test('pairingCodes can be fetched by id but never listed', () {
      final b = block(rules(), 'match /pairingCodes/{code}');
      expect(b, contains('allow get:'));
      expect(RegExp(r'allow (read|list)').hasMatch(b), isFalse);
    });

    test('caretaker edit rule keeps role and pairedUserId unchanged', () {
      final b = block(rules(), 'match /users/{uid}');
      expect(b, contains('request.resource.data.role == resource.data.role'));
      expect(b, contains('request.resource.data.pairedUserId == resource.data.pairedUserId'));
    });

    test('no catch-all rule and no public (unauthenticated) read', () {
      final r = rules();
      expect(r, isNot(contains('match /{document=**}')));
      expect(RegExp(r'allow (read|get|list|write)[^;]*:\s*if true').hasMatch(r), isFalse);
    });
  });

  group('log redaction', () {
    test('LOG_RAW_TRANSCRIPTS defaults off', () {
      expect(DiagnosticsConfig.logRawTranscripts, isFalse);
    });

    test('quoted transcripts keep only their shape', () {
      final out = redactLogLine('[Stt] heard "amar basay phone koro 01712345678"');
      expect(out, isNot(contains('basay')));
      expect(out, isNot(contains('01712345678')));
    });

    test('ASCII phone numbers, pairing codes and coordinates are hidden', () {
      final out = redactLogLine('contact 01712345678 code 482913 at 23.746123,90.376543');
      expect(out, isNot(contains('01712345678')));
      expect(out, isNot(contains('482913')));
      expect(out, isNot(contains('23.746123')));
      expect(out, isNot(contains('90.376543')));
    });

    test('Firebase uid is replaced by a short tag', () {
      const uid = 'aB3dE5gH7jK9mN1pQ3rS5tU7vW9x';
      final out = redactLogLine('uid=$uid paired');
      expect(out, isNot(contains(uid)));
      expect(out, contains('<id:'));
    });

    test('bearer tokens and key params are hidden', () {
      final out = redactLogLine('Authorization: Bearer abcdefghijkl1234 and ?key=ZZZZZZZZZZZZ');
      expect(out, isNot(contains('abcdefghijkl1234')));
      expect(out, isNot(contains('ZZZZZZZZZZZZ')));
    });
  });

  group('android manifest', () {
    String manifest() => File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    test('only MainActivity is exported; the foreground service is not', () {
      final m = manifest();
      expect(RegExp('android:exported="true"').allMatches(m).length, 1);
      expect(m, contains('android:name=".WakeWordForegroundService"'));
      expect(RegExp(r'WakeWordForegroundService"\s+android:exported="false"').hasMatch(m), isTrue);
    });

    test('no deep links and no cleartext opt-in', () {
      final m = manifest();
      expect(m, isNot(contains('android.intent.action.VIEW')));
      expect(m, isNot(contains('BROWSABLE')));
      expect(m, isNot(contains('usesCleartextTraffic="true"')));
    });

    test('contacts permission is read-only', () {
      final m = manifest();
      expect(m, contains('READ_CONTACTS'));
      expect(m, isNot(contains('WRITE_CONTACTS')));
    });
  });

  test('dart_defines.local.json is git-ignored', () {
    expect(File('.gitignore').readAsStringSync(), contains('dart_defines.local.json'));
  });
}
