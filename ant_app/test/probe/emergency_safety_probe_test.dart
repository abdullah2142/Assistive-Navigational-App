// QA probe for the emergency / Magic Button area (key: emergency_safety).
// Everything here PASSES today and pins behaviour that was verified to work.
// Offline, deterministic (fake clock), no Firebase/GPS/TTS/STT.
import 'dart:async';

import 'package:ant_app/core/config/emergency_config.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/emergency_channel.dart';
import 'package:ant_app/core/services/emergency_payload.dart';
import 'package:ant_app/core/services/emergency_plan.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/safe_haven_finder.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/models/trusted_contact.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

const _chan = MethodChannel('com.ant.assistive.ant_app/emergency');

class _Tts extends TtsService {
  final spoken = <String>[];
  bool throws = false;
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
    if (throws) throw StateError('tts dead');
  }

  @override
  Future<void> stop() async {}
}

/// Delivers scripted (delay, text, isFinal) results while "listening".
class _Stt extends SttService {
  _Stt([this.script = const []]);
  final List<(Duration, String, bool)> script;
  bool available = true;
  int listens = 0;
  @override
  Future<bool> ensureAvailable() async => available;
  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    listens++;
    for (final (d, t, f) in script) {
      Timer(d, () => onResult(t, f));
    }
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}

class _Alerts implements AlertService {
  int created = 0;
  @override
  Future<bool> createAlert({
    required String disabledUserUid,
    required GuardianAlertType type,
    double? lat,
    double? lng,
    int? batteryPercent,
    List<String> notifiedContacts = const [],
  }) async {
    created++;
    return true;
  }

  @override
  Future<bool> publishLocation(
          {required String disabledUserUid, required double lat, required double lng}) async =>
      true;
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _NoPlanner implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

UserProfile _profile({
  List<TrustedContact> contacts = const [
    TrustedContact(name: 'Ma', phoneNumber: '01711111111', isPrimary: true),
  ],
  AppLanguage language = AppLanguage.english,
}) =>
    UserProfile(uid: 'u1', role: UserRole.disabledUser, magicButtonContacts: contacts, language: language);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async => null);
    messenger.setMockMethodCallHandler(_chan, (c) async {
      calls.add(c.method);
      switch (c.method) {
        case 'hasPermission':
          return true;
        case 'batteryPercent':
          return 40;
        case 'sendSms':
          return {'delivered': (c.arguments as Map)['recipients'], 'failed': {}};
        case 'placeCall':
          return true;
      }
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(_chan, null));

  EmergencyService svc(_Tts tts, _Stt stt, [_Alerts? alerts]) => EmergencyService(
      tts: tts, stt: stt, alerts: alerts ?? _Alerts(), planner: _NoPlanner(), channel: EmergencyChannel(channel: _chan));

  Future<void> advance(WidgetTester t, int seconds) async {
    for (var i = 0; i < seconds * 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  group('cancel window boundary (voice)', () {
    Future<CancelWindowOutcome> runWindow(WidgetTester t, Duration cancelAt, {bool isFinal = true}) async {
      final stt = _Stt([(cancelAt, 'cancel', isFinal)]);
      CancelWindowOutcome? out;
      unawaited(VoiceCancelWindow.run(
        tts: _Tts(), stt: stt, language: AppLanguage.english, readBack: 'x',
        isCancelled: () => false, emergency: true,
      ).then((o) => out = o));
      await advance(t, 8);
      return out!;
    }

    // The window opens after a ~180 ms haptic burst, so offsets are measured
    // from the moment the recogniser is listening.
    testWidgets('cancel at 4.9 s still cancels', (t) async {
      expect(await runWindow(t, const Duration(milliseconds: 4900)), CancelWindowOutcome.cancelled);
    });
    testWidgets('cancel at 5.1 s is too late and proceeds', (t) async {
      expect(await runWindow(t, const Duration(milliseconds: 5100)), CancelWindowOutcome.proceed);
    });
    testWidgets('silence proceeds only after the full 5 s', (t) async {
      final stt = _Stt();
      CancelWindowOutcome? out;
      unawaited(VoiceCancelWindow.run(
        tts: _Tts(), stt: stt, language: AppLanguage.english, readBack: 'x',
        isCancelled: () => false, emergency: true,
      ).then((o) => out = o));
      await advance(t, 4);
      expect(out, isNull);
      await advance(t, 2);
      expect(out, CancelWindowOutcome.proceed);
    });
    testWidgets('an interim "cancel" is ignored; only a final result counts (design)', (t) async {
      expect(await runWindow(t, const Duration(seconds: 2), isFinal: false), CancelWindowOutcome.proceed);
    });
    testWidgets('a dead microphone proceeds rather than dropping the SOS', (t) async {
      final stt = _Stt()..available = false;
      // With no microphone the window still runs its full five seconds, so the
      // on-screen Cancel button and a typed "cancel" have time to be used.
      CancelWindowOutcome? out;
      unawaited(VoiceCancelWindow.run(
        tts: _Tts(), stt: stt, language: AppLanguage.english, readBack: 'x',
        isCancelled: () => false, emergency: true,
      ).then((o) => out = o));
      await advance(t, 2);
      expect(out, isNull);
      await advance(t, 7);
      expect(out, CancelWindowOutcome.proceed);
    });
    testWidgets('a dead TTS engine does not abort the window', (t) async {
      final tts = _Tts()..throws = true;
      CancelWindowOutcome? out;
      unawaited(VoiceCancelWindow.run(
        tts: tts, stt: _Stt(), language: AppLanguage.english, readBack: 'x',
        isCancelled: () => false, emergency: true,
      ).then((o) => out = o));
      await advance(t, 7);
      expect(out, CancelWindowOutcome.proceed);
    });
    testWidgets('a closed screen (isCancelled) cancels instead of sending', (t) async {
      final out = await VoiceCancelWindow.run(
        tts: _Tts(), stt: _Stt(), language: AppLanguage.english, readBack: 'x',
        isCancelled: () => true, emergency: true,
      );
      expect(out, CancelWindowOutcome.cancelled);
    });
  });

  group('cancel vocabulary for an SOS', () {
    test('shouting at an attacker does not cancel', () {
      for (final s in ['stop get away from me', 'wait please', 'he is pushing me against the wall', 'no', 'edit']) {
        expect(VoiceCancelWindow.cancelsEmergency(s), isFalse, reason: s);
      }
    });
    test('the deliberate words cancel, in either script and case', () {
      for (final s in ['Cancel!', 'cancel it', 'ক্যান্সেল', 'বাতিল', 'ami bolchi CANCEL']) {
        expect(VoiceCancelWindow.cancelsEmergency(s), isTrue, reason: s);
      }
    });
    test('cancelled / cancellation do not cancel (exact word)', () {
      expect(VoiceCancelWindow.cancelsEmergency('cancellation'), isFalse);
    });
  });

  group('trigger lifecycle', () {
    testWidgets('tap-cancel during the countdown stops it; nothing is sent; can re-trigger', (t) async {
      final tts = _Tts();
      final service = svc(tts, _Stt());
      final first = service.trigger(profile: _profile());
      await advance(t, 1);
      expect(service.phase.value, EmergencyPhase.countdown);
      expect(service.cancelPending(), isTrue);
      expect(service.cancelPending(), isTrue, reason: 'cancelling twice is idempotent and harmless');
      final out = await first;
      expect(out.cancelled, isTrue);
      expect(calls, isNot(contains('sendSms')));
      expect(calls, isNot(contains('placeCall')));
      expect(service.phase.value, EmergencyPhase.idle);
      // cancel then immediate re-trigger starts clean (flag reset)
      final second = service.trigger(profile: _profile());
      await advance(t, 1);
      expect(service.phase.value, EmergencyPhase.countdown);
      expect(service.cancelPending(), isTrue);
      expect((await second).cancelled, isTrue);
    });

    testWidgets('a second trigger while one runs is refused and does not duplicate anything', (t) async {
      final alerts = _Alerts();
      final service = svc(_Tts(), _Stt(), alerts);
      final first = service.trigger(profile: _profile());
      await advance(t, 1);
      final dup = await service.trigger(profile: _profile());
      expect(dup.reason, 'already running');
      expect(dup.cancelled, isFalse);
      await advance(t, 40);
      await first;
      expect(calls.where((c) => c == 'sendSms').length, lessThanOrEqualTo(1));
      expect(alerts.created, 0);
      expect(service.isRunning, isFalse);
    });

    testWidgets('cancel while still announcing speaks the cancelled line and sends nothing', (t) async {
      final tts = _Tts();
      final service = svc(tts, _Stt());
      final run = service.trigger(profile: _profile());
      expect(service.phase.value, EmergencyPhase.announcing);
      expect(service.cancelPending(), isTrue);
      final out = await run;
      expect(out.cancelled, isTrue);
      expect(tts.spoken.last, Dashboard.of(AppLanguage.english).emergencyCancelled);
      expect(calls, isNot(contains('sendSms')));
      await advance(t, 1); // let the trailing haptic burst finish
    });

    testWidgets('no usable contact: user is told, nothing is dialled', (t) async {
      final tts = _Tts();
      final service = svc(tts, _Stt());
      final run = service.trigger(
          profile: _profile(contacts: const [TrustedContact(name: 'x', phoneNumber: '12')]));
      await advance(t, 2);
      final out = await run;
      expect(out.reason, 'no contacts');
      expect(tts.spoken.last, Dashboard.of(AppLanguage.english).emergencyNoContacts);
      expect(calls, isNot(contains('sendSms')));
    });

    testWidgets('Bangla session speaks Bangla throughout the countdown', (t) async {
      final tts = _Tts();
      final service = svc(tts, _Stt());
      final run = service.trigger(profile: _profile(language: AppLanguage.bangla));
      await advance(t, 1);
      service.cancelPending();
      await run;
      for (final s in tts.spoken) {
        expect(RegExp(r'[ঀ-৿]').hasMatch(s), isTrue, reason: s);
      }
    });

    testWidgets('a dead TTS never stops the escalation reaching the end', (t) async {
      final tts = _Tts()..throws = true;
      final service = svc(tts, _Stt());
      var done = false;
      unawaited(service.trigger(profile: _profile()).then((_) => done = true));
      await advance(t, 40);
      expect(done, isTrue);
      expect(service.isRunning, isFalse);
    });

    testWidgets('live mode: permissions denied is spoken, not silent', (t) async {
      messenger.setMockMethodCallHandler(_chan, (c) async => c.method == 'hasPermission' ? false : null);
      final tts = _Tts();
      final service = svc(tts, _Stt());
      unawaited(service.trigger(profile: _profile(), confirm: false));
      await advance(t, 30);
      expect(tts.spoken.last, Dashboard.of(AppLanguage.english).emergencyNoPermission);
    }, skip: EmergencyConfig.isRehearsal);

    testWidgets('live mode: SMS refused for everyone is spoken as NOT sent', (t) async {
      messenger.setMockMethodCallHandler(_chan, (c) async {
        if (c.method == 'hasPermission') return true;
        if (c.method == 'sendSms') throw PlatformException(code: 'no_sim');
        if (c.method == 'placeCall') return false;
        return null;
      });
      final tts = _Tts();
      final service = svc(tts, _Stt());
      unawaited(service.trigger(profile: _profile(), confirm: false));
      await advance(t, 30);
      final d = Dashboard.of(AppLanguage.english);
      expect(tts.spoken, contains(d.emergencyNotSent));
      expect(tts.spoken, isNot(contains(d.emergencySent(1))));
    }, skip: EmergencyConfig.isRehearsal);
  });

  group('contacts and payload', () {
    test('primary first, invalid dropped, dashes/spaces stripped, exact duplicates removed', () {
      final out = EmergencyPlan.smsRecipients(const [
        TrustedContact(name: 'a', phoneNumber: '017 1111-1111'),
        TrustedContact(name: 'b', phoneNumber: 'abc'),
        TrustedContact(name: 'c', phoneNumber: '01822222222', isPrimary: true),
        TrustedContact(name: 'd', phoneNumber: '01711111111'),
      ]);
      expect(out, ['01822222222', '01711111111']);
      expect(EmergencyPlan.callTarget(const [TrustedContact(name: 'a', phoneNumber: '01711111111')]), '01711111111');
      expect(EmergencyPlan.callTarget(const []), isNull);
    });

    test('every SMS part is one SMS in both languages, with and without location/name/battery', () {
      for (final lang in AppLanguage.values) {
        for (final name in [null, '', 'রহিম', 'A very long name that goes on and on and on and on and on and on']) {
          for (final loc in [true, false]) {
            for (final bat in [null, 4, 100]) {
              final parts = EmergencyPayload.messages(
                language: lang, name: name,
                lat: loc ? 23.7561 : null, lng: loc ? 90.3872 : null, batteryPercent: bat,
              );
              expect(parts.length, lessThanOrEqualTo(2));
              for (final p in parts) {
                expect(EmergencyPayload.fitsOnePart(p), isTrue, reason: '$lang $name $loc $bat -> $p');
              }
              if (loc) expect(parts.join(' '), contains('maps.google.com/?q=23.756100,90.387200'));
              if (!loc) expect(parts.join(' ').contains('maps.google'), isFalse);
            }
          }
        }
      }
    });

    test('southern/western hemisphere coordinates keep their sign in the link', () {
      expect(EmergencyPayload.mapsLink(-1.5, -70.25), 'https://maps.google.com/?q=-1.500000,-70.250000');
    });
  });

  group('safe haven', () {
    const origin = LatLng(23.7561, 90.3872);
    test('hospital exactly at the 1 km edge is kept, just past it is dropped', () {
      final inside = SafeHaven(label: 'in', source: HavenSource.discovered, location: LatLng(23.7561 + 0.00899, 90.3872));
      final outside = SafeHaven(label: 'out', source: HavenSource.discovered, location: LatLng(23.7561 + 0.0092, 90.3872));
      final ranked = SafeHavenFinder.rank(origin: origin, savedPlaces: const [], discovered: [outside, inside]);
      expect(ranked.map((h) => h.label), ['in']);
    });
    test('nothing known and nothing found is null (stay put), offline included', () {
      expect(SafeHavenFinder.best(origin: origin, savedPlaces: const []), isNull);
    });
    test('nearest discovered first; saved work/school never chosen', () {
      final best = SafeHavenFinder.best(
        origin: origin,
        savedPlaces: const [SavedPlace(label: 'Work', kind: SavedPlaceKind.work, lat: 23.7562, lng: 90.3873)],
        discovered: const [
          SafeHaven(label: 'far', source: HavenSource.discovered, location: LatLng(23.760, 90.3872)),
          SafeHaven(label: 'near', source: HavenSource.discovered, location: LatLng(23.757, 90.3872)),
        ],
      );
      expect(best?.label, 'near');
    });
    test('same point has zero distance and a valid compass index', () {
      expect(SafeHavenFinder.metresBetween(origin, origin), 0);
      expect(SafeHavenFinder.compassIndex(SafeHavenFinder.bearingDegrees(origin, origin)), inInclusiveRange(0, 7));
    });
  });
}
