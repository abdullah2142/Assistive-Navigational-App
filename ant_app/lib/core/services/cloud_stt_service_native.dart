import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_speech/endless_streaming_service.dart';
import 'package:google_speech/generated/google/cloud/speech/v1/cloud_speech.pb.dart' show StreamingRecognizeResponse;
import 'package:google_speech/google_speech.dart';
import 'package:record/record.dart';

import '../config/cloud_stt_config.dart';
import '../localization/app_language.dart';

/// Genuinely continuous speech recognition via Google Cloud Speech-to-Text's
/// streaming API — one open connection that keeps listening through pauses,
/// rather than the repeated discrete sessions `SttService` (on-device
/// `speech_to_text`) has to use to approximate "continuous" listening.
///
/// That restart-based approximation is what caused two confirmed-live bugs
/// this was built to fix: the mic indicator visibly flickering on every
/// restart, and `error_no_match` (a merely transient recognition hiccup)
/// sometimes ending a whole listening session outright. Neither can happen
/// here — there's no restart, just one stream that keeps running until
/// [stop] is called.
///
/// Gated behind [CloudSttConfig.isConfigured] — every caller must check
/// that first (same pattern as [GeminiConfig]/[MapsConfig]) and fall back
/// to the on-device `SttService` when it's false, exactly like this app's
/// other optional cloud features degrade gracefully without one.
class CloudSttService {
  final AudioRecorder _recorder = AudioRecorder();
  EndlessStreamingService? _streamingService;
  StreamSubscription<StreamingRecognizeResponse>? _resultSub;
  bool _listening = false;

  static const int _sampleRate = 16000;

  bool get isListening => _listening;

  /// Starts continuous recognition. [onResult] fires for every interim and
  /// final transcript, same contract as `SttService.listenOnce`'s
  /// callback — but this keeps running past any pause in speech rather
  /// than ending, until [stop] is called. Returns `false` (without
  /// starting anything) if the API key isn't configured or the microphone
  /// permission isn't available, so callers can fall back to on-device STT
  /// exactly like every other optional-capability check in this app.
  Future<bool> start({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    /// Called if the recognition stream dies *after* a successful start.
    ///
    /// Without this the caller cannot know: `start()` has already returned
    /// true, so `SttService` believes cloud recognition is running and never
    /// tries the on-device recognizer. The user is left in a "sorry, I didn't
    /// catch that" loop with a microphone that is recording into nothing.
    ///
    /// The case that makes this matter is quota. A Cloud Speech quota cap is
    /// enforced mid-stream, not at connect time, so the *only* signal that
    /// the free tier ran out arrives here.
    void Function(Object error)? onStreamError,
  }) async {
    if (!CloudSttConfig.isConfigured) return false;
    if (isListening) return true;
    if (!await _recorder.hasPermission()) {
      debugPrint('[CloudStt] mic permission not granted');
      return false;
    }

    try {
      final service = EndlessStreamingService.viaApiKey(CloudSttConfig.apiKey);
      _streamingService = service;

      final config = StreamingRecognitionConfig(
        config: RecognitionConfig(
          encoding: AudioEncoding.LINEAR16,
          languageCode: language.ttsLocale,
          sampleRateHertz: _sampleRate,
          model: RecognitionModel.command_and_search,
          enableAutomaticPunctuation: true,
        ),
        // The entire point of this service — kept explicit even though
        // it's the default, since accidentally flipping this would
        // silently reintroduce the exact restart behavior this replaces.
        singleUtterance: false,
        interimResults: true,
      );

      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
          // Confirmed live as a real problem: the app's own TTS narration
          // (the Passerby overlay's "Showing your screen now..." announcement,
          // e.g.) was getting picked back up by this same microphone stream
          // and mistaken for user speech. Both default to `false` in this
          // package — echoCancel engages the platform's acoustic echo
          // canceler (built for exactly this: filtering out audio the
          // device is itself playing), noiseSuppress helps with general
          // background noise on top of that.
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      _resultSub = service.endlessStream.listen(
        (response) {
          if (response.results.isEmpty) return;
          final result = response.results.first;
          if (result.alternatives.isEmpty) return;
          onResult(result.alternatives.first.transcript, result.isFinal);
        },
        onError: (Object e) {
          debugPrint('[CloudStt] stream error: $e');
          // Stop first, so the caller's fallback is not competing with this
          // recorder for the microphone.
          _listening = false;
          unawaited(stop());
          onStreamError?.call(e);
        },
      );

      service.endlessStreamingRecognize(
        config,
        audioStream.cast<List<int>>(),
        // Cloud Speech-to-Text's own hard cap on a single streaming
        // request is ~5 minutes; restarting under the hood at 4 is a
        // buffer under that, and — unlike the on-device approximation —
        // invisible to the caller, since `EndlessStreamingService` hands
        // off between the old and new underlying request without ever
        // closing the audio source or missing audio in between.
        restartTime: const Duration(minutes: 4),
      );

      _listening = true;
      debugPrint('[CloudStt] continuous listening started (${language.name})');
      return true;
    } catch (e) {
      debugPrint('[CloudStt] failed to start: $e');
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    _listening = false;
    await _resultSub?.cancel();
    _resultSub = null;
    // Recorder first, streaming service second.
    //
    // The other order closed the streaming service's sink while the recorder
    // was still delivering audio into it, and every screen transition after a
    // listen logged "Bad state: Cannot add new events after calling close"
    // (seen on device, caught by the zone guard rather than crashing).
    // Silencing the source before closing the destination leaves nothing in
    // flight to land on a closed stream.
    try {
      await _recorder.stop();
    } catch (_) {
      // Already stopped — fine.
    }
    _streamingService?.dispose();
    _streamingService = null;
  }

  Future<void> dispose() async {
    await stop();
    try {
      await _recorder.dispose();
    } catch (_) {
      // Same reasoning as `WakeWordService.dispose` — nothing to release,
      // and this runs from container teardown where a throw is noise.
    }
  }
}
