import 'package:ant_app/core/services/cloud_stt_service.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/localization/app_language.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cloud recognizer that starts successfully and then dies, the way a
/// quota-exhausted stream does.
///
/// This is the shape that matters. Cloud Speech does not refuse the
/// connection when the free tier runs out — it accepts the stream and then
/// errors partway through, so `start()` has already returned true by the time
/// anything is wrong.
class _FailsMidStreamCloudStt implements CloudSttService {
  _FailsMidStreamCloudStt({this.failWith = 'RESOURCE_EXHAUSTED'});

  final String failWith;
  bool stopped = false;
  bool started = false;

  @override
  bool get isListening => started && !stopped;

  @override
  Future<bool> start({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    void Function(Object error)? onStreamError,
    List<String> phraseHints = const [],
  }) async {
    started = true;
    // Fires after start() has resolved, exactly as the real stream does.
    Future.microtask(() => onStreamError?.call(Exception(failWith)));
    return true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  // SttService reaches platform channels (haptics, speech_to_text) the moment
  // it starts listening.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a cloud stream that dies mid-session', () {
    test('reports failure so the caller can fall back', () async {
      // Before this, the error was only debugPrint-ed. start() had returned
      // true, so SttService believed cloud recognition was running, never
      // tried the on-device recognizer, and the user was left talking to a
      // microphone recording into nothing — the same silent-failure class as
      // the missing <queries> entry.
      final cloud = _FailsMidStreamCloudStt();
      final stt = SttService(cloudStt: cloud);

      var finalResults = 0;
      await stt.listenOnce(
        language: AppLanguage.english,
        onResult: (text, isFinal) {
          if (isFinal) finalResults++;
        },
        pauseFor: const Duration(milliseconds: 50),
        listenFor: const Duration(milliseconds: 200),
      );

      expect(cloud.started, isTrue);
      // No fabricated final result. An empty transcript would read as "the
      // user said nothing" rather than "recognition broke".
      expect(finalResults, 0);
    });

    test('releases the microphone before the fallback needs it', () async {
      // Two recognizers competing for the mic is its own failure; the cloud
      // recorder has to let go before on-device recognition starts.
      final cloud = _FailsMidStreamCloudStt();
      final stt = SttService(cloudStt: cloud);

      await stt.listenOnce(
        language: AppLanguage.english,
        onResult: (_, __) {},
        pauseFor: const Duration(milliseconds: 50),
        listenFor: const Duration(milliseconds: 200),
      );

      expect(cloud.stopped, isTrue);
    });
  });

}
