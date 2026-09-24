import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_speech/endless_streaming_service.dart';
import 'package:google_speech/generated/google/cloud/speech/v1/cloud_speech.pb.dart'
    show StreamingRecognizeResponse;
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

  /// The recorder's stream, relayed through a controller this class owns
  /// rather than handed to `google_speech` directly.
  ///
  /// Handing `startStream`'s stream straight to `endlessStreamingRecognize`
  /// gives this class no way to stop the flow: the package subscribes
  /// internally, and `stop()` can only dispose it. Stopping the recorder
  /// first is necessary but **not sufficient** — frames already emitted are
  /// queued as pending microtasks and are still delivered after `dispose()`
  /// has closed the package's own sink, which is the
  /// "Bad state: Cannot add new events after calling close" the zone guard
  /// caught **41 times in one session** on 22 September, in bursts of four
  /// or five every time a listen ended and the wake word restarted.
  ///
  /// With a relay in between, [stop] can cancel the upstream subscription —
  /// which drops anything still queued — and then close the relay, which
  /// ends the package's input stream the way it expects rather than pulling
  /// it out from underneath.
  StreamSubscription<List<int>>? _audioSub;
  StreamController<List<int>>? _audioRelay;
  bool _ownsAudioRecorder = false;

  static const int _sampleRate = 16000;

  bool get isListening => _listening;

  /// Note on strength: the API supports a per-context `boost` (0-20), but
  /// `google_speech`'s own `SpeechContext` wrapper takes only `phrases` and
  /// drops the boost field on its way to the protobuf. So these go with
  /// Google's default weighting, which is the mild one. If the hints turn out
  /// to help but not enough, that wrapper is where the ceiling is — not here.

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

    /// Optional PCM stream opened by another feature. It keeps recognition
    /// and recording on one microphone session.
    Stream<Uint8List>? audioSource,

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

    /// Proper nouns to tell the recognizer are likely in this session.
    ///
    /// Reported directly: a user says a Dhaka location and the transcript
    /// comes back as something unrelated. That is the normal failure mode for
    /// rare proper nouns — a general model is weighted towards common
    /// vocabulary, and thana names sound like ordinary words. Phrase hints
    /// exist for precisely this, cost nothing per request, and this app never
    /// used them.
    List<String> phraseHints = const [],
  }) async {
    if (!CloudSttConfig.isConfigured) return false;
    if (isListening) return audioSource == null;
    if (audioSource == null && !await _recorder.hasPermission()) {
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
          speechContexts: [
            if (phraseHints.isNotEmpty) SpeechContext(phraseHints),
          ],
        ),
        // The entire point of this service — kept explicit even though
        // it's the default, since accidentally flipping this would
        // silently reintroduce the exact restart behavior this replaces.
        singleUtterance: false,
        interimResults: true,
      );

      final audioStream =
          audioSource ??
          await _recorder.startStream(
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
              // Resume automatically once whatever interrupted us is done.
              //
              // The default is `pause`, which the package documents as "pauses
              // automatically, resumes *manually*" — nothing in this app ever
              // resumed it, so any interruption killed the session silently and
              // the user carried on talking into a recorder that had stopped.
              // Seen on device 10 September in the passerby picker, where this
              // app's own narration ducked its own dictation session:
              //
              //   02:19:13.564  onAudioFocusChange(-3) -> record
              //   02:19:15.513  onAudioFocusChange(1)  -> record
              //
              // `record` treats a duck request as a full focus loss, so -3 is
              // enough to trigger it. The narration ordering is fixed separately
              // (see `PasserbyMessagePicker._autoListenLoop`); this is what keeps
              // a phone call, an alarm or another app from doing the same.
              //
              // Deliberately not `none`, unlike the wake word: pausing a
              // dictation session the user deliberately started, while something
              // else has the speakers, is the right behaviour. It just has to
              // come back afterwards.
              audioInterruption: AudioInterruptionMode.pauseResume,
            ),
          );
      _ownsAudioRecorder = audioSource == null;

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

      // `sync: false` on purpose: a synchronous controller would deliver
      // each frame during the recorder's own emit, which puts the cancel in
      // `stop()` back in the same race it is there to remove.
      final relay = StreamController<List<int>>();
      _audioRelay = relay;
      _audioSub = audioStream.cast<List<int>>().listen(
        (frame) {
          if (relay.isClosed) return;
          relay.add(frame);
        },
        onError: (Object e) {
          if (!relay.isClosed) relay.addError(e);
        },
        onDone: () {
          if (!relay.isClosed) unawaited(relay.close());
        },
        cancelOnError: false,
      );

      service.endlessStreamingRecognize(
        config,
        relay.stream,
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

    // Order is the whole fix here, and each step is load-bearing.
    //
    // 1. Cancel the relay's upstream subscription. This is what stopping the
    //    recorder alone could not do: it drops every frame already queued
    //    behind it, so nothing is left in flight to be delivered later.
    await _audioSub?.cancel();
    _audioSub = null;

    // 2. Close the relay, which ends `google_speech`'s input stream the way
    //    the package expects — a normal done event — rather than having its
    //    sink disposed out from under a live source.
    final relay = _audioRelay;
    _audioRelay = null;
    if (relay != null && !relay.isClosed) await relay.close();

    // 3. Only then silence the hardware. Kept before the service dispose for
    //    the original reason this order was chosen: a recorder still running
    //    while the destination goes away is how the first version of this bug
    //    happened.
    if (_ownsAudioRecorder) {
      try {
        await _recorder.stop();
      } catch (_) {
        // Already stopped — fine.
      }
    }
    _ownsAudioRecorder = false;
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
