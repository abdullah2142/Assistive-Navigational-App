import 'dart:async';
import 'dart:typed_data';

import 'package:ant_app/core/services/wake_word_audio_source.dart';
import 'package:ant_app/core/services/wake_word_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Wake-word suspension: who owns the microphone, and when.
///
/// The reported failure this file exists for: with "Hey ANT" *and*
/// auto-listen both on, neither worked — the hazard hub read out its options
/// and took no answer, and the wake word stopped firing afterwards. With one
/// on at a time, each worked.
///
/// Two distinct defects produced that, and both are ordering bugs rather
/// than logic bugs, which is why they need a controllable recorder to
/// reproduce:
///
/// 1. `start()` did not know about suspensions at all. A suspension taken
///    while a start was in flight — routine, because the release schedules a
///    restart half a second later and the command the user just spoke opens
///    a screen inside that window — let the recorder come up *inside* the
///    suspension and take the microphone from the recognizer.
/// 2. The decision to restart was inferred from whether the recorder
///    happened to be live when the suspension was taken. In exactly the case
///    above it was not, so the wake word was never brought back.
///
/// Everything below drives the real `WakeWordService` with a fake recorder
/// whose handshake takes a controllable amount of time, which is the only
/// way those two orderings are reachable off-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The real 500 ms is an Android audio-teardown allowance, not a
    // behavioural constant — see its doc comment.
    WakeWordService.restartHandoff = const Duration(milliseconds: 10);
  });

  tearDown(() {
    WakeWordService.restartHandoff = const Duration(milliseconds: 500);
  });

  /// Waits past the restart handoff so an assertion sees the settled state.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  WakeWordService serviceWith(_FakeAudioSource source) =>
      WakeWordService(audioSource: source, loadModels: () async => true);

  group('suspension contract', () {
    test('pauseAround runs its action and returns the value', () async {
      final service = WakeWordService(loadModels: () async => false);
      var ran = false;

      final result = await service.pauseAround(() async {
        ran = true;
        return 42;
      });

      expect(ran, isTrue);
      expect(result, 42);
    });

    test('pauseAround nests — an inner release must not lift the outer hold', () async {
      // This is the shape the hub creates: one suspension for the whole
      // sheet, and one per listen inside it.
      final source = _FakeAudioSource();
      final service = serviceWith(source);
      await service.start(onDetected: () {});
      expect(source.openStreams, 1);

      await service.pauseAround(() async {
        expect(service.isListening, isFalse, reason: 'outer hold must silence the recorder');
        await service.pauseAround(() async {});
        // The inner release brought the depth back to 1, not 0.
        await settle();
        expect(service.isListening, isFalse, reason: 'inner release must not reopen the mic');
      });

      await settle();
      expect(service.isListening, isTrue, reason: 'the outer release brings it back');
      expect(source.openStreams, 2);
    });

    test('a throw inside pauseAround still releases the suspension', () async {
      // Otherwise one failed listen would leave the wake word suspended for
      // the rest of the session, silently.
      final service = WakeWordService(loadModels: () async => false);

      await expectLater(
        service.pauseAround(() async => throw StateError('listen failed')),
        throwsStateError,
      );

      expect(service.suspendDepth, 0);
      expect(await service.pauseAround(() async => 'ok'), 'ok');
    });

    test('resume with nothing held is a no-op, not an error', () async {
      // dispose() calls resume() unconditionally, including on a screen that
      // never got as far as suspending.
      final service = WakeWordService(loadModels: () async => false);

      expect(service.resume, returnsNormally);
      expect(service.resume, returnsNormally);
      expect(service.suspendDepth, 0);
    });
  });

  group('a start that races a suspension', () {
    test('start() while suspended does not open the microphone', () async {
      final source = _FakeAudioSource();
      final service = serviceWith(source);

      service.suspend();
      final started = await service.start(onDetected: () {});

      expect(started, isTrue, reason: 'the caller must not fall back to push-to-talk-only');
      expect(service.isListening, isFalse);
      expect(source.openStreams, 0, reason: 'the suspending flow owns the mic');
    });

    test('a suspension taken while start() is loading wins', () async {
      // The exact reported ordering. The hazard hub's initState suspends
      // while the dashboard's restart is still loading models.
      final source = _FakeAudioSource();
      final modelsLoaded = Completer<bool>();
      final service = WakeWordService(audioSource: source, loadModels: () => modelsLoaded.future);

      final starting = service.start(onDetected: () {});
      service.suspend(); // the hub opens
      modelsLoaded.complete(true);
      await starting;

      expect(source.openStreams, 0, reason: 'must not steal the mic from the hub');
      expect(service.isListening, isFalse);
    });

    test('a suspension taken during the recorder handshake hands the mic straight back', () async {
      final source = _FakeAudioSource()..blockNextStream = true;
      final service = serviceWith(source);

      final starting = service.start(onDetected: () {});
      await Future<void>.delayed(Duration.zero);
      service.suspend();
      source.releaseStream();
      await starting;

      expect(service.isListening, isFalse);
      expect(source.stops, greaterThan(0), reason: 'the stream that came up must be closed again');
    });

    test('the wake word comes back after a suspension it was never listening through', () async {
      // The second half of the regression: because the recorder was not live
      // when the hub suspended, the old code decided there was nothing to
      // restore and the wake word stayed dead for the rest of the session.
      final source = _FakeAudioSource();
      final service = serviceWith(source);

      service.suspend();
      await service.start(onDetected: () {});
      expect(service.isListening, isFalse);

      service.resume();
      await settle();

      expect(service.isListening, isTrue, reason: '"Hey ANT" must work again after the hub closes');
      expect(source.openStreams, 1);
    });

    test('two concurrent starts open one stream, not two', () async {
      // initState and didUpdateWidget can both ask, and two recorders on one
      // microphone is the contention this whole file is about.
      final source = _FakeAudioSource();
      final service = serviceWith(source);

      await Future.wait([
        service.start(onDetected: () {}),
        service.start(onDetected: () {}),
      ]);

      expect(source.openStreams, 1);
    });
  });

  group('explicit off', () {
    test('stop() means off — a later release must not resurrect it', () async {
      // Turning the toggle off while a listen session is in flight.
      final source = _FakeAudioSource();
      final service = serviceWith(source);
      await service.start(onDetected: () {});

      service.suspend();
      await service.stop(); // the user turns "Hey ANT" off
      service.resume();
      await settle();

      expect(service.isEnabled, isFalse);
      expect(service.isListening, isFalse);
    });

    test('a suspension released while disabled stays quiet', () async {
      final source = _FakeAudioSource();
      final service = serviceWith(source);

      await service.pauseAround(() async {});
      await settle();

      expect(source.openStreams, 0, reason: 'never enabled, so nothing to restore');
    });
  });

  group('warm restarts', () {
    // The measured symptom: the classifier needs 16 embedding windows before
    // it can score at all, so clearing them on every restart left "Hey ANT"
    // deaf for ~2 s after each voice exchange.
    test('a suspension keeps the feature buffers so the model resumes warm', () async {
      final source = _FakeAudioSource();
      final service = serviceWith(source);
      await service.start(onDetected: () {});
      service.debugMelFrames.addAll(List.generate(80, (_) => List.filled(32, 0.5)));
      service.debugEmbeddings.addAll(List.generate(20, (_) => List.filled(96, 0.1)));

      await service.pauseAround(() async {});
      await settle();

      expect(service.isListening, isTrue);
      expect(service.debugMelFrames, hasLength(80));
      expect(service.debugEmbeddings, hasLength(20));
    });

    test('a detection poisons the buffers, so the next start is cold', () async {
      // The retained window would otherwise *be* the phrase that just fired,
      // and one fresh embedding is not enough to stop it scoring the same
      // again — the wake word would trigger twice off one utterance.
      final source = _FakeAudioSource();
      final service = serviceWith(source);
      await service.start(onDetected: () {});
      service.debugMelFrames.addAll(List.generate(80, (_) => List.filled(32, 0.5)));
      service.debugEmbeddings.addAll(List.generate(20, (_) => List.filled(96, 0.1)));

      service.debugSimulateDetection();
      await service.pauseAround(() async {});
      await settle();

      expect(service.isListening, isTrue);
      expect(service.debugEmbeddings, isEmpty);
      expect(service.debugWillRestartWarm, isFalse);
    });

    test('a first start is always cold', () async {
      final source = _FakeAudioSource();
      final service = serviceWith(source);

      await service.start(onDetected: () {});

      expect(service.debugWillRestartWarm, isFalse);
      expect(service.debugMelFrames, isEmpty);
    });
  });
}

/// A recorder that never touches a microphone, and whose handshake can be
/// held open on demand so a test can land a suspension inside it.
class _FakeAudioSource implements WakeWordAudioSource {
  int openStreams = 0;
  int stops = 0;
  bool blockNextStream = false;
  Completer<void>? _gate;

  void releaseStream() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<Uint8List>> startStream() async {
    if (blockNextStream) {
      blockNextStream = false;
      _gate = Completer<void>();
      await _gate!.future;
    }
    openStreams++;
    // Never emits — the detection pipeline needs the real TFLite models, and
    // everything under test here is the ownership state machine around it.
    return const Stream<Uint8List>.empty();
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}
