// runtime_lifecycle: verified-working behaviours (regression coverage). Offline, fast.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/diagnostics/diagnostics_log.dart';
import 'package:ant_app/core/services/api_budget.dart';
import 'package:ant_app/core/services/background_listening_service.dart';
import 'package:ant_app/core/services/emergency_channel.dart';
import 'package:ant_app/core/services/gemini_model_cooldowns.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';

class _Store implements ApiBudgetStore {
  _Store({this.fail = false});
  bool fail;
  final Map<String, Map<String, int>> data = {};
  int reads = 0;
  @override
  Future<Map<String, int>> read(String period) async {
    reads++;
    if (fail) throw StateError('offline');
    return Map.of(data[period] ?? {});
  }

  @override
  Future<void> increment(String period, String api) async {
    if (fail) throw StateError('offline');
    final m = data.putIfAbsent(period, () => {});
    m[api] = (m[api] ?? 0) + 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiBudget', () {
    test('a store that cannot be read is treated as exhausted, never throws', () async {
      final b = MonthlyApiBudget(store: _Store(fail: true));
      expect(await b.tryConsume(BillableApi.routes), isFalse);
      expect(await b.usage(), isEmpty);
    });

    test('the cap is honoured and the month rolls over', () async {
      var now = DateTime(2026, 9, 30, 23, 59);
      final store = _Store();
      final b = MonthlyApiBudget(store: store, now: () => now, caps: {BillableApi.routes: 2});
      expect(await b.tryConsume(BillableApi.routes), isTrue);
      expect(await b.tryConsume(BillableApi.routes), isTrue);
      expect(await b.tryConsume(BillableApi.routes), isFalse);
      now = DateTime(2026, 10, 1, 0, 1);
      expect(b.currentPeriod, '2026-10');
      expect(await b.tryConsume(BillableApi.routes), isTrue);
    });

    test('an api with no cap entry is refused rather than unlimited', () async {
      final b = MonthlyApiBudget(store: _Store(), caps: {});
      expect(await b.tryConsume(BillableApi.gemini), isFalse);
    });

    test('a failing increment does not fail the call', () async {
      final store = _Store();
      final b = MonthlyApiBudget(store: store);
      expect(await b.tryConsume(BillableApi.gemini), isTrue);
      store.fail = true;
      expect(await b.tryConsume(BillableApi.gemini), isTrue); // cached read, increment error swallowed
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('GeminiModelCooldowns', () {
    test('a per-day quota error cools the model until just after Pacific midnight (PDT and PST)', () {
      // 2026-10-27 18:00 UTC = 11:00 PDT -> next Pacific midnight 07:00 UTC next day
      final c = GeminiModelCooldowns(now: () => DateTime.utc(2026, 10, 27, 18));
      final until = c.recordFailure('m', 'RESOURCE_EXHAUSTED quota exceeded PerDay')!;
      expect(until, DateTime.utc(2026, 10, 28, 7, 1));
      // 2026-12-01 12:00 UTC = 04:00 PST -> 08:00 UTC next day
      final w = GeminiModelCooldowns(now: () => DateTime.utc(2026, 12, 1, 12));
      expect(w.recordFailure('m', 'quota per day')!, DateTime.utc(2026, 12, 2, 8, 1));
      c.recordReset('x', Duration.zero);
    });

    test('a clock that jumps forward clears the cooldown; unknown errors never start one', () {
      var now = DateTime.utc(2026, 10, 27, 12);
      final c = GeminiModelCooldowns(now: () => now);
      c.recordFailure('m', '429 rate limit');
      expect(c.isCooling('m'), isTrue);
      now = now.add(const Duration(minutes: 5));
      expect(c.isCooling('m'), isFalse);
      expect(c.recordFailure('m', 'SocketException: Failed host lookup'), isNull);
    });

    test('retry hints parse from server text and headers', () {
      final c = GeminiModelCooldowns(now: () => DateTime.utc(2026, 1, 1));
      expect(c.recordFailure('m', 'Please retry in 34.5s (429)'), DateTime.utc(2026, 1, 1, 0, 0, 35, 500));
      expect(GeminiModelCooldowns.parseRetryHeader('1m30s'), const Duration(seconds: 91));
      expect(GeminiModelCooldowns.parseRetryHeader('garbage'), isNull);
    });
  });

  group('native channels fail soft', () {
    test('EmergencyChannel survives MissingPluginException on every call', () async {
      final ch = EmergencyChannel(channel: const MethodChannel('probe/none'));
      expect(await ch.hasPermission(EmergencyPermission.sms), isFalse);
      expect(await ch.batteryPercent(), isNull);
      expect(await ch.placeCall('01700000000'), isFalse);
      await ch.requestPermissions();
      final r = await ch.sendSms(recipients: ['017', '018'], messages: ['hi']);
      expect(r.anyDelivered, isFalse);
      expect(r.failed.keys, ['017', '018']);
    });

    test('EmergencyChannel reports every recipient failed when the platform throws PlatformException', () async {
      const c = MethodChannel('probe/throws');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(c, (_) async => throw PlatformException(code: 'permission_denied'));
      final r = await EmergencyChannel(channel: c).sendSms(recipients: ['017'], messages: ['x']);
      expect(r.failed['017'], contains('permission_denied'));
    });

    test('BackgroundListeningService.start/stop never throw when the service cannot start', () async {
      const c = MethodChannel('com.ant.assistive.ant_app/background_listening');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        c,
        (_) async => throw PlatformException(code: 'foreground_service_start_failed'),
      );
      final s = BackgroundListeningService();
      await s.start();
      expect(s.isRunning, isFalse);
      await s.stop();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(c, null);
    });
  });

  group('UserProfile.fromJson tolerates upgrade-era documents', () {
    test('minimal, unknown enum values, and junk list entries do not throw', () {
      final p = UserProfile.fromJson({
        'uid': 'u1',
        'role': 'someFutureRole',
        'visionLevel': 'telepathic',
        'language': 'klingon',
        'onboardingStep': 'removedStep',
        'magicButtonContacts': [<String, dynamic>{}],
        'savedPlaces': [<String, dynamic>{'label': 'x'}],
      });
      expect(p.uid, 'u1');
      expect(p.onboardingComplete, isFalse);
      expect(p.magicButtonContacts.single.phoneNumber, '');
    });
  });

  group('DiagnosticsLog', () {
    test('disk use is bounded to two files and a bad directory is not a crash', () async {
      final dir = await Directory.systemTemp.createTemp('ant_diag_');
      final log = DiagnosticsLog(capacity: 50, maxSessionBytes: 2000);
      await log.attachToDirectory(dir);
      for (var i = 0; i < 400; i++) {
        log.add('line number $i ${'x' * 40}');
        if (i % 5 == 0) await Future<void>.delayed(Duration.zero);
      }
      await log.flush();
      await log.detach();
      final files = dir.listSync().whereType<File>().toList();
      expect(files.length, lessThanOrEqualTo(2));
      expect(files.fold<int>(0, (a, f) => a + f.lengthSync()), lessThan(2000 * 2 + 2000));
      expect(log.length, 50);
      await dir.delete(recursive: true);

      final bad = DiagnosticsLog();
      await bad.attachToDirectory(Directory('/proc/definitely/not/writable'));
      expect(bad.isPersisting, isFalse);
      bad.add('still works in memory');
      expect(bad.length, 1);
    });
  });
}
