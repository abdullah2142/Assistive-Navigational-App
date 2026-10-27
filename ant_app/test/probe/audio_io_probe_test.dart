import 'dart:async';
import 'dart:typed_data';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/earcon_service.dart';
import 'package:ant_app/core/services/recognizer_faults.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/wake_word_audio_source.dart';
import 'package:ant_app/core/services/wake_word_service.dart';
import 'package:ant_app/core/utils/cancellable_delay.dart';
import 'package:ant_app/core/utils/spoken_text.dart';
import 'package:ant_app/core/utils/wav_encoder.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for the audio stack (audio_io area). Everything here
/// passes today; failing behaviours live in probe_bugs/audio_io_bugs_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------- forSpeech
  group('forSpeech edge cases', () {
    test('whitespace-only, emoji-only and empty input speak nothing', () {
      expect(forSpeech(''), '');
      expect(forSpeech('  \n\n '), '');
      expect(forSpeech('⚠️'), '');
      expect(forSpeech('👍👍'), '');
    });
    test('digits, Bangla digits, units and currency survive', () {
      expect(forSpeech('Walk 3.5 km then 1,000 m'), 'Walk 3.5 km then 1,000 m');
      expect(forSpeech('১২৩ নম্বর বাস, ৫০০ মিটার'), '১২৩ নম্বর বাস, ৫০০ মিটার');
      expect(forSpeech('Fare ৳30 or 20%'), 'Fare ৳30 or 20%');
      expect(forSpeech('Call 999.'), 'Call 999.');
    });
    test('decimal-numbered lines are not mistaken for list markers', () {
      expect(forSpeech('2.5 km ahead'), '2.5 km ahead');
      expect(forSpeech('1.2.3 version'), '1.2.3 version');
    });
    test('danda runs collapse but a single one is kept', () {
      expect(forSpeech('শেষ।।'), 'শেষ।');
      expect(forSpeech('শেষ।'), 'শেষ।');
    });
    test('abbreviations keep their full stops', () {
      expect(forSpeech('Dr. Rahman, 3 p.m.'), 'Dr. Rahman, 3 p.m.');
    });
    test('urgent exclamation survives emphasis stripping', () {
      expect(forSpeech('**Stop!** Car coming!!!'), 'Stop! Car coming!');
    });
    test('arrows and warning signs are dropped, destination kept', () {
      expect(forSpeech('Bus 5 → Farmgate ⚠️ danger'), 'Bus 5 Farmgate danger');
    });
    test('unclosed emphasis markers do not swallow later lines', () {
      final out = forSpeech('**bold start\nturn left');
      expect(out, isNot(contains('*')));
      expect(out, contains('turn left'));
    });
    test('very long input stays linear-time enough', () {
      final sw = Stopwatch()..start();
      forSpeech(('**a** - b\n' * 5000));
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  // -------------------------------------------------------------- wav encoder
  group('wrapPcm16AsWav', () {
    int u32(Uint8List b, int o) => b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;
    test('0 samples gives a valid 44-byte header with empty data', () {
      final w = wrapPcm16AsWav(Uint8List(0), sampleRate: 16000, numChannels: 1);
      expect(w.length, 44);
      expect(u32(w, 4), 36);
      expect(u32(w, 40), 0);
    });
    test('header fields match the payload for 16 kHz mono', () {
      final pcm = Uint8List.fromList(List.filled(3200, 7));
      final w = wrapPcm16AsWav(pcm, sampleRate: 16000, numChannels: 1);
      expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(w.sublist(36, 40)), 'data');
      expect(u32(w, 4), 36 + 3200);
      expect(u32(w, 24), 16000);
      expect(u32(w, 28), 32000); // byte rate
      expect(w[32] | w[33] << 8, 2); // block align
      expect(u32(w, 40), 3200);
      expect(w.length, 44 + 3200);
    });
    test('stereo 44.1 kHz computes byte rate and block align', () {
      final w = wrapPcm16AsWav(Uint8List(8), sampleRate: 44100, numChannels: 2);
      expect(u32(w, 28), 44100 * 4);
      expect(w[32] | w[33] << 8, 4);
    });
    test('odd byte count is copied verbatim (caller owns alignment)', () {
      final w = wrapPcm16AsWav(Uint8List(5), sampleRate: 16000, numChannels: 1);
      expect(u32(w, 40), 5);
      expect(w.length, 49);
    });
  });

  // ------------------------------------------------------------------ earcons
  group('earcons', () {
    List<int> samples(Uint8List wav) => [
          for (var i = 44; i + 1 < wav.length; i += 2)
            (() {
              final r = wav[i] | wav[i + 1] << 8;
              return r >= 0x8000 ? r - 0x10000 : r;
            })()
        ];
    test('both cues are distinct, non-clipping and start/end near zero', () {
      final a = EarconService.toneFor(Earcon.listening);
      final b = EarconService.toneFor(Earcon.stopped);
      expect(a, isNot(equals(b)));
      for (final w in [a, b]) {
        final s = samples(w);
        expect(s.reduce((x, y) => x.abs() > y.abs() ? x : y).abs(), lessThan(32767));
        expect(s.first.abs(), lessThan(200));
        expect(s.last.abs(), lessThan(2000));
      }
    });
  });

  // -------------------------------------------------------- cancellable delay
  group('CancellableDelay', () {
    test('zero and negative durations complete true immediately-ish', () async {
      final d = CancellableDelay();
      expect(await d.wait(Duration.zero), isTrue);
      expect(await d.wait(const Duration(milliseconds: -50)), isTrue);
    });
    test('cancel racing a firing timer never completes twice or throws', () async {
      final d = CancellableDelay();
      final f = d.wait(const Duration(milliseconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      d.cancel();
      d.cancel();
      expect(await f, anyOf(isTrue, isFalse));
    });
    test('wait after cancel is false and arms no timer', () async {
      final d = CancellableDelay()..cancel();
      expect(await d.wait(const Duration(hours: 1)), isFalse);
    });
    test('a wait started from inside a cancelled waiter is refused', () async {
      final d = CancellableDelay();
      var second = true;
      final f = d.wait(const Duration(hours: 1)).then((ok) async {
        second = await d.wait(const Duration(hours: 1));
      });
      d.cancel();
      await f;
      expect(second, isFalse);
    });
  });

  // ----------------------------------------------------------- recognizer faults
  group('RecognizerFaults', () {
    test('only the dead-stream StateError is routed', () {
      final f = RecognizerFaults.forTesting();
      var n = 0;
      f.listen(() => n++);
      f.report(StateError('something else'));
      f.report(Exception('Cannot add new events after calling close'));
      expect(n, 0);
      f.report(StateError('Bad state: Cannot add new events after calling close'));
      expect(n, 1);
      expect(f.faultCount, 1);
    });
    test('a listener that unsubscribes inside the callback does not break the loop', () {
      final f = RecognizerFaults.forTesting();
      late VoidCallback off;
      var other = 0;
      off = f.listen(() => off());
      f.listen(() => other++);
      f.report(StateError('Cannot add new events after calling close'));
      expect(other, 1);
    });
  });

  // ------------------------------------------------------------- locale pick
  group('locale choice', () {
    test('Bangla prefers bn-BD over bn-IN; English prefers en-US/IN over en-AU', () {
      expect(SttService.pickLocaleId(['en_AU', 'bn_IN', 'bn_BD'], AppLanguage.bangla)!.toLowerCase().replaceAll('_', '-'), 'bn-bd');
      final en = SttService.pickLocaleId(['en_AU', 'en_US'], AppLanguage.english)!;
      expect(en.toLowerCase(), isNot(contains('au')));
    });
    test('no match gives null (system default), never a throw', () {
      expect(SttService.pickLocaleId(['hi_IN'], AppLanguage.bangla), isNull);
      expect(SttService.pickLocaleId([], AppLanguage.english), isNull);
    });
  });

  // ------------------------------------------------------------ wake word
  group('WakeWordService', () {
    setUp(() {
      WakeWordService.restartHandoff = const Duration(milliseconds: 10);
      WakeWordService.recorderRetryBase = const Duration(milliseconds: 10);
      WakeWordService.recorderRetryMax = const Duration(milliseconds: 80);
    });
    tearDown(() {
      WakeWordService.restartHandoff = const Duration(milliseconds: 500);
      WakeWordService.recorderRetryBase = const Duration(seconds: 2);
      WakeWordService.recorderRetryMax = const Duration(seconds: 60);
    });

    test('threshold is clamped to the dial range at both ends', () {
      final s = WakeWordService(loadModels: () async => false);
      s.threshold = -3;
      expect(s.threshold, WakeWordService.minThreshold);
      s.threshold = 99;
      expect(s.threshold, WakeWordService.maxThreshold);
      s.threshold = double.infinity;
      expect(s.threshold, WakeWordService.maxThreshold);
      s.threshold = 0.42;
      expect(s.threshold, 0.42);
    });

    test('permission denied makes start() report false and opens nothing', () async {
      final src = _Src(permission: false);
      final s = WakeWordService(audioSource: src, loadModels: () async => true);
      expect(await s.start(onDetected: () {}), isFalse);
      expect(src.opened, 0);
      expect(s.isListening, isFalse);
    });

    test('missing model assets make start() report false and open nothing', () async {
      final src = _Src();
      final s = WakeWordService(audioSource: src, loadModels: () async => false);
      expect(await s.start(onDetected: () {}), isFalse);
      expect(src.opened, 0);
    });

    test('stop() during the recorder handshake leaves no open recorder', () async {
      final src = _Src()..gate = Completer<void>();
      final s = WakeWordService(audioSource: src, loadModels: () async => true);
      final started = s.start(onDetected: () {});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await s.stop();
      src.gate!.complete();
      await started;
      expect(s.isListening, isFalse);
      expect(src.stops, greaterThan(0));
    });

    test('dispose is idempotent-safe with a recorder that throws on stop', () async {
      final src = _Src()..throwOnStop = true;
      final s = WakeWordService(audioSource: src, loadModels: () async => true);
      await s.start(onDetected: () {});
      await s.dispose();
    });

    test('release of a suspension below zero is a no-op', () async {
      final s = WakeWordService(audioSource: _Src(), loadModels: () async => true);
      s.resume();
      s.resume();
      expect(s.suspendDepth, 0);
    });
  });

  // ------------------------------------------------------- real TtsService
  group('TtsService against a faked flutter_tts channel', () {
    late _TtsChannel ch;
    setUp(() {
      ch = _TtsChannel()..install();
    });
    tearDown(() => ch.uninstall());

    test('markdown and emoji are stripped before the engine sees the text', () async {
      final tts = TtsService();
      await tts.speak('**Stop** 👍 now');
      expect(ch.spokenTexts, ['Stop now']);
    });

    test('empty, whitespace and emoji-only text never reach the engine', () async {
      final tts = TtsService();
      await tts.speak('');
      await tts.speak('   \n ');
      await tts.speak('🚌');
      expect(ch.spokenTexts, isEmpty);
    });

    test('overlapping speaks reach the engine strictly in order, one at a time', () async {
      final tts = TtsService();
      ch.speakDelay = const Duration(milliseconds: 15);
      final a = tts.speak('one');
      final b = tts.speak('two');
      final c = tts.speak('three');
      await Future.wait([a, b, c]);
      expect(ch.spokenTexts, ['one', 'two', 'three']);
      expect(ch.maxConcurrent, 1);
    });

    test('stop() abandons queued utterances', () async {
      final tts = TtsService();
      ch.speakDelay = const Duration(milliseconds: 30);
      final a = tts.speak('first');
      final b = tts.speak('queued');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tts.stop();
      await Future.wait([a, b]);
      expect(ch.spokenTexts, ['first']);
    });

    test('speech after stop() works again', () async {
      final tts = TtsService();
      await tts.stop();
      await tts.speak('hello');
      expect(ch.spokenTexts, ['hello']);
    });

    test('a failing utterance does not wedge later ones', () async {
      final tts = TtsService();
      ch.failTexts.add('bad');
      try {
        await tts.speak('bad');
      } catch (_) {}
      await tts.speak('good');
      expect(ch.spokenTexts, contains('good'));
    });

    test('language switch sets the locale before each utterance', () async {
      final tts = TtsService();
      await tts.speak('hi', language: AppLanguage.english);
      await tts.speak('নমস্কার', language: AppLanguage.bangla);
      expect(ch.languages.length, 2);
      expect(ch.languages.first.toLowerCase(), startsWith('en'));
      expect(ch.languages.last.toLowerCase(), startsWith('bn'));
    });

    test('no installed voice for the locale still speaks (engine default)', () async {
      ch.voices = [];
      final tts = TtsService();
      await tts.speak('নমস্কার', language: AppLanguage.bangla);
      expect(ch.spokenTexts, ['নমস্কার']);
    });

    test('engine voice lookup throwing still speaks', () async {
      ch.voicesThrow = true;
      final tts = TtsService();
      await tts.speak('hello');
      expect(ch.spokenTexts, ['hello']);
    });

    test('control: under fakeAsync a second utterance is dispatched when the first completes', () {
      fakeAsync((async) {
        final tts = TtsService();
        tts.speak('first').ignore();
        tts.speak('second').ignore();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(ch.spokenTexts, ['first', 'second']);
      });
    });

    test('pickVoice is deterministic regardless of engine ordering', () {
      final v1 = {'name': 'bn-bd-x-b', 'locale': 'bn-BD'};
      final v2 = {'name': 'bn-bd-x-a', 'locale': 'bn-BD'};
      expect(TtsService.pickVoice([v1, v2], 'bn-BD')!['name'], 'bn-bd-x-a');
      expect(TtsService.pickVoice([v2, v1], 'bn-BD')!['name'], 'bn-bd-x-a');
      expect(TtsService.pickVoice([], 'bn-BD'), isNull);
    });
  });
}

typedef VoidCallback = void Function();

class _Src implements WakeWordAudioSource {
  _Src({this.permission = true});
  final bool permission;
  int opened = 0;
  int stops = 0;
  Completer<void>? gate;
  bool throwOnStop = false;
  @override
  Future<bool> hasPermission() async => permission;
  @override
  Future<Stream<Uint8List>> startStream() async {
    if (gate != null) await gate!.future;
    opened++;
    return StreamController<Uint8List>().stream;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (throwOnStop) throw StateError('already stopped');
  }

  @override
  Future<void> dispose() async {
    if (throwOnStop) throw StateError('x');
  }
}

/// Fakes the `flutter_tts` and `audioplayers` platform channels.
class _TtsChannel {
  final List<String> spokenTexts = [];
  final List<String> languages = [];
  final Set<String> failTexts = {};
  Duration speakDelay = Duration.zero;
  int _concurrent = 0;
  int maxConcurrent = 0;
  List<Map<String, String>> voices = [
    {'name': 'en-us-x-a', 'locale': 'en-US'},
    {'name': 'bn-bd-x-a', 'locale': 'bn-BD'},
  ];
  bool voicesThrow = false;

  /// If set, 'speak' calls never reply (engine lost the completion callback).
  bool hang = false;
  final List<String> calls = [];

  static const _tts = MethodChannel('flutter_tts');
  static const _ap = MethodChannel('xyz.luan/audioplayers');
  static const _apg = MethodChannel('xyz.luan/audioplayers.global');

  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_tts, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getEngines':
          return ['com.google.android.tts'];
        case 'getDefaultEngine':
          return 'com.google.android.tts';
        case 'getVoices':
          if (voicesThrow) throw PlatformException(code: 'x');
          return voices;
        case 'setLanguage':
          languages.add(call.arguments.toString());
          return 1;
        case 'speak':
          final text = (call.arguments is Map ? (call.arguments as Map)['text'] : call.arguments).toString();
          if (hang) return Completer<dynamic>().future;
          _concurrent++;
          if (_concurrent > maxConcurrent) maxConcurrent = _concurrent;
          await Future<void>.delayed(speakDelay);
          _concurrent--;
          if (failTexts.contains(text)) throw PlatformException(code: 'speak failed');
          spokenTexts.add(text);
          return 1;
        default:
          return 1;
      }
    });
    m.setMockMethodCallHandler(_ap, (call) async => null);
    m.setMockMethodCallHandler(_apg, (call) async => null);
  }

  void uninstall() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_tts, null);
    m.setMockMethodCallHandler(_ap, null);
    m.setMockMethodCallHandler(_apg, null);
  }
}
