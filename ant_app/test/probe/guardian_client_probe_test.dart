import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/utils/spoken_text.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/guardian/models/guardian_alert.dart';
import 'package:ant_app/features/guardian/models/live_location.dart';
import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/guardian/services/live_location_publisher.dart';
import 'package:ant_app/features/dashboard/providers/caretaker_inbox_providers.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/widgets/caretaker_inbox_listener.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

class _Tts implements TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);
  @override
  Future<void> stop() async {}
  @override
  void setVoiceId(String voiceId) {}
}

CommunicationMessage _m(String id, String text, {DateTime? at, String from = 'c1', String to = 'u1'}) =>
    CommunicationMessage(
        id: id, fromUid: from, toUid: to, type: CommunicationType.memo, text: text, createdAt: at);

UserProfile _paired() => UserProfile(uid: 'u1', role: UserRole.disabledUser, pairedUserId: 'c1');
UserProfile _solo() => UserProfile(uid: 'u1', role: UserRole.disabledUser);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  extraProbes();
  setUpAll(() {
    AudioplayersPlatformInterface.instance = _FakeAudio();
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalAudio();
  });
  late StreamController<List<CommunicationMessage>> feed;
  late _Tts tts;
  var subscribed = 0;

  Future<ProviderContainer> mount(WidgetTester t, UserProfile p) async {
    feed = StreamController<List<CommunicationMessage>>();
    tts = _Tts();
    subscribed = 0;
    final c = ProviderContainer(overrides: [
      ttsServiceProvider.overrideWithValue(tts),
      incomingCaretakerMessagesProvider('u1').overrideWith((ref) {
        subscribed++;
        ref.onDispose(() {});
        return feed.stream;
      }),
    ]);
    addTearDown(c.dispose);
    addTearDown(() {
      feed.close();
    });
    await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(home: CaretakerInboxListener(profile: p, child: const SizedBox())),
    ));
    return c;
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(const Duration(milliseconds: 400));
    await t.pump();
  }

  testWidgets('history in the first snapshot is never read aloud; later memo is spoken exactly once', (t) async {
    await mount(t, _paired());
    feed.add([_m('old1', 'old memo')]);
    await settle(t);
    expect(tts.spoken, isEmpty);
    // same snapshot re-delivered (metadata change / reconnect) plus a new memo
    feed.add([_m('old1', 'old memo'), _m('n1', 'come home')]);
    await settle(t);
    feed.add([_m('old1', 'old memo'), _m('n1', 'come home')]);
    await settle(t);
    expect(tts.spoken.where((s) => s.contains('come home')).length, 1);
    expect(tts.spoken.where((s) => s.contains('old memo')), isEmpty);
  });

  testWidgets('two memos arriving together are spoken oldest first', (t) async {
    await mount(t, _paired());
    feed.add(const []);
    await settle(t);
    final now = DateTime.now();
    feed.add([
      _m('b', 'second', at: now),
      _m('a', 'first', at: now.subtract(const Duration(minutes: 1))),
    ]);
    await settle(t);
    expect(tts.spoken.indexWhere((s) => s.contains('first')), lessThan(tts.spoken.indexWhere((s) => s.contains('second'))));
    expect(tts.spoken.length, 2);
  });

  testWidgets('a solo user opens no Firestore subscription at all', (t) async {
    await mount(t, _solo());
    await settle(t);
    expect(subscribed, 0);
  });

  testWidgets('a memo that fails to deliver does not block the next one', (t) async {
    final c = await mount(t, _paired());
    feed.add(const []);
    await settle(t);
    feed.add([_m('x', '   ')]);
    await settle(t);
    feed.add([_m('x', '   '), _m('y', 'hello there')]);
    await settle(t);
    expect(tts.spoken.where((s) => s.contains('hello there')).length, 1);
    expect(c.read(chatControllerProvider).messages, isNotEmpty);
  });

  group('forSpeech on caretaker text', () {
    test('emoji-only text becomes silence rather than a spoken name', () {
      expect(forSpeech('❤️'), isEmpty);
      expect(forSpeech('Come home 😀 now'), 'Come home now');
    });
    test('markdown bold / bullets are not read as symbols', () {
      expect(forSpeech('**Wait** at the stop'), 'Wait at the stop');
    });
    test('Bangla survives untouched', () {
      expect(forSpeech('ভাত খেয়ে নাও'), 'ভাত খেয়ে নাও');
    });
  });
}

class _FakeAudio extends AudioplayersPlatformInterface {
  @override
  Future<void> create(String playerId) async {}
  @override
  Future<void> dispose(String playerId) async {}
  @override
  Future<int?> getCurrentPosition(String playerId) async => 0;
  @override
  Future<int?> getDuration(String playerId) async => 0;
  @override
  Stream<AudioEvent> getEventStream(String playerId) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _FakeGlobalAudio extends GlobalAudioplayersPlatformInterface {
  @override
  Future<void> init() async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _BoomFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('firestore unavailable');
}

Position _pos(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1,
      speedAccuracy: 0,
    );

class _Pub implements AlertService {
  final published = <String>[];
  @override
  Future<bool> publishLocation({required String disabledUserUid, required double lat, required double lng}) async {
    published.add(disabledUserUid);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void extraProbes() {
  group('alert / location services never throw into an emergency', () {
    test('createAlert returns false instead of throwing when Firestore is broken', () async {
      final ok = await AlertService(firestore: _BoomFirestore()).createAlert(
        disabledUserUid: 'u1',
        type: GuardianAlertType.magicButton,
        lat: 23.7,
        lng: 90.4,
      );
      expect(ok, isFalse);
    });
    test('publishLocation returns false instead of throwing', () async {
      expect(
        await AlertService(firestore: _BoomFirestore()).publishLocation(disabledUserUid: 'u1', lat: 1, lng: 2),
        isFalse,
      );
    });
  });

  group('live location publisher lifecycle', () {
    test('switching to another user cancels the first user stream (no cross-account publishing)', () async {
      final a = StreamController<Position>.broadcast();
      final b = StreamController<Position>.broadcast();
      final alerts = _Pub();
      var n = 0;
      final p = LiveLocationPublisher(alerts: alerts, positionStream: () => n++ == 0 ? a.stream : b.stream);
      p.start(uid: 'u1', isPaired: true);
      p.start(uid: 'u2', isPaired: true);
      await Future<void>.delayed(Duration.zero);
      expect(a.hasListener, isFalse);
      a.add(_pos(23.7, 90.4));
      b.add(_pos(23.8, 90.4));
      await Future<void>.delayed(Duration.zero);
      expect(alerts.published, ['u2']);
      p.stop();
      expect(b.hasListener, isFalse);
    });
    test('stop() is idempotent and a stopped publisher ignores late fixes', () async {
      final a = StreamController<Position>.broadcast();
      final alerts = _Pub();
      final p = LiveLocationPublisher(alerts: alerts, positionStream: () => a.stream);
      p.start(uid: 'u1', isPaired: true);
      p.stop();
      p.stop();
      a.add(_pos(23.7, 90.4));
      await Future<void>.delayed(Duration.zero);
      expect(alerts.published, isEmpty);
      expect(p.isRunning, isFalse);
    });
    test('an unpaired start never opens the position stream', () {
      var opened = 0;
      LiveLocationPublisher(alerts: _Pub(), positionStream: () {
        opened++;
        return const Stream.empty();
      }).start(uid: 'u1', isPaired: false);
      expect(opened, 0);
    });
  });

  group('hazard report vocabulary', () {
    final bn = Dashboard.of(AppLanguage.bangla);
    final en = Dashboard.of(AppLanguage.english);
    const serverCategories = {'crime', 'roadHazard', 'accessibilityBlock'};
    for (final c in HazardCategory.values) {
      test('${c.name}: server-known category, unique sub-keys, exactly one Other, labels in both languages', () {
        expect(serverCategories, contains(c.name));
        final keys = en.hazardSubCategoryKeys(c);
        expect(keys.toSet().length, keys.length);
        expect(keys.where(en.isOtherSubCategoryKey).length, 1);
        for (final k in keys) {
          expect(en.hazardSubCategoryLabel(k).trim(), isNotEmpty, reason: k);
          expect(bn.hazardSubCategoryLabel(k).trim(), isNotEmpty, reason: k);
          expect(RegExp(r'[ঀ-৿]').hasMatch(bn.hazardSubCategoryLabel(k)) || en.isOtherSubCategoryKey(k), isTrue,
              reason: 'Bangla label for $k is not Bangla');
        }
      });
    }
    test('report JSON carries the stable English keys, not labels', () {
      final j = const HazardReport(
        reporterUid: 'u1',
        category: HazardCategory.roadHazard,
        subCategory: 'openManhole',
        lat: 23.7,
        lng: 90.4,
      ).toJson();
      expect(j['category'], 'roadHazard');
      expect(j['subCategory'], 'openManhole');
      expect(j['reporterUid'], 'u1');
    });
  });

  group('models degrade rather than crash on partial documents', () {
    test('alert with nothing but a type', () {
      final a = GuardianAlert.fromJson('a1', {'type': 'magicButton'});
      expect(a.resolved, isFalse);
      expect(a.createdAt, isNull);
      expect(a.type, GuardianAlertType.magicButton);
    });
    test('message with missing text and unknown type', () {
      final m = CommunicationMessage.fromJson('m', {'fromUid': 'a', 'toUid': 'b', 'type': 'hologram'});
      expect(m.text, '');
      expect(m.type, CommunicationType.memo);
    });
    test('live location with integer coordinates', () {
      final l = LiveLocation.fromJson('u', {'lat': 23, 'lng': 90});
      expect(l.lat, 23.0);
    });
  });
}
