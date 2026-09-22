import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../localization/app_language.dart';
import 'cloud_stt_service.dart';
import 'recognizer_faults.dart';
import 'locale_preference.dart';
import 'wake_word_service.dart';

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

/// Thin wrapper around the device's built-in speech recognizer.
///
/// This is the pragmatic swap for the module plan's "Google Cloud
/// Speech-to-Text via gRPC streaming": the project has no billing-enabled
/// GCP project to call that API from (see `GeminiConfig`'s doc comment),
/// so real-time transcription instead runs entirely on-device via
/// `speech_to_text` — free, works with no backend, and degrades to
/// "unavailable" cleanly on a device/simulator that has no recognizer
/// installed rather than crashing. Wake-word detection (Porcupine) is
/// deliberately not implemented for the same reason (needs a Picovoice
/// account); every mic button in the app is push-to-talk instead.
class SttService {
  SttService({WakeWordService? wakeWord, CloudSttService? cloudStt, RecognizerFaults? faults})
      : _wakeWord = wakeWord,
        _cloudStt = cloudStt,
        _faults = faults ?? RecognizerFaults.instance {
    _unlistenFaults = _faults.listen(_onRecognizerFault);
  }

  final RecognizerFaults _faults;
  VoidCallback? _unlistenFaults;

  /// When the session currently in progress opened.
  ///
  /// A fault arriving within [_faultGrace] of a session starting cannot be
  /// about *that* session — it is the tail of the previous one, delivered
  /// late from a stream that is already gone. Tearing down the new session
  /// on the strength of the old one's death would turn a harmless log line
  /// into a microphone that closes the instant it opens. In the tester logs
  /// the gap between a fault and the next session start is never under ten
  /// seconds, so this only has to be wide enough to cover the overlap.
  DateTime? _sessionStartedAt;
  static const Duration _faultGrace = Duration(seconds: 1);

  /// Item 49 — the recognizer's stream dies out of band.
  ///
  /// Not catchable where it happens: `google_speech` throws it from inside
  /// its own zone after its controller is closed, so it reaches
  /// `PlatformDispatcher.onError` and nothing else. Swallowing it was right
  /// while it was believed to be harmless; the tester logs show that nine of
  /// thirty-seven fired mid-utterance, leaving this service listening to a
  /// stream that will never deliver and the caller awaiting a future that
  /// will never complete. The microphone stays *shown as open* and is
  /// permanently deaf, which is very likely behind some of the standing "it
  /// didn't hear me" reports.
  ///
  /// Stopping is the whole fix: `stop()` already completes both pending
  /// completers, so `listenOnce` returns and the ordinary auto-listen and
  /// wake-word paths open a fresh session by themselves.
  void _onRecognizerFault() {
    final pending = _sessionDone ?? _cloudSessionDone;
    if (pending == null || pending.isCompleted) return;
    final startedAt = _sessionStartedAt;
    if (startedAt != null && DateTime.now().difference(startedAt) < _faultGrace) {
      debugPrint('[Stt] ignoring a stream fault that arrived as this session opened');
      return;
    }
    _faults.noteSessionLost();
    unawaited(stop());
  }

  /// How long to wait after this app finishes speaking before opening a
  /// microphone.
  ///
  /// Not a buffer-drain allowance — measured on device, the recognizer
  /// transcribed narration that had stopped a full second earlier, because
  /// Cloud STT reports interim results about two seconds late and had
  /// captured audio right at the boundary. Two separate flows were broken by
  /// it on the same night: the Show Screen picker committed "What you need?"
  /// (the tail of its own prompt) as the user's message, and the Show Screen
  /// overlay heard its own "say 'go back'" and dismissed itself.
  ///
  /// A screen must narrate with the microphone shut, and then leave a beat
  /// before opening it.
  static const Duration narrationSettle = Duration(milliseconds: 600);

  final SpeechToText _speech = SpeechToText();
  final WakeWordService? _wakeWord;
  final CloudSttService? _cloudStt;
  bool _initialized = false;
  Completer<void>? _sessionDone;
  Completer<void>? _cloudSessionDone;

  /// One-time device capability + permission check, cached after the first
  /// call. Returns `false` (never throws) if the device has no speech
  /// recognizer, the OS denies microphone/speech permission, or anything
  /// else goes wrong — callers should show the same "voice unavailable"
  /// messaging the UI already had before this module existed.
  Future<bool> ensureAvailable() async {
    if (_initialized) return _speech.isAvailable;
    try {
      // `onStatus` is wired once here (it's a single listener for this
      // `SpeechToText` instance's whole lifetime, not per-`listen()` call)
      // so every future `listenOnce()` can await the real end of a session
      // via `_sessionDone` — see the doc comment on `listenOnce` for why
      // that matters.
      _initialized = await _speech.initialize(
        onStatus: _handleStatus,
        onError: (e) => debugPrint('[Stt] recognition error: ${e.errorMsg} (permanent=${e.permanent})'),
      );
    } catch (_) {
      _initialized = false;
    }
    return _initialized;
  }

  void _handleStatus(String status) {
    if (status == SpeechToText.doneStatus) {
      _sessionDone?.complete();
      _sessionDone = null;
    }
  }

  bool get isListening => _speech.isListening;

  /// Best-effort match of the app's UI language to a locale the device's
  /// recognizer actually supports. Locale identifier formatting
  /// (`bn_BD` vs `bn-BD`) varies by platform/OS version in ways this
  /// wrapper can't predict without a real device, so instead of guessing a
  /// single hardcoded string, it scans whatever `locales()` reports first.
  ///
  /// `locales()` only enumerates locales with a downloaded *offline*
  /// language pack, though — confirmed live, a real device's list had
  /// English, Hindi, and a dozen others but no Bangla at all, meaning
  /// Bangla speech was silently being recognized as English/Hindi
  /// ("jibberish"). Android's recognizer still generally accepts an
  /// explicit locale id outside that list and falls through to
  /// network-based recognition for it when one isn't installed offline
  /// (almost certainly how Google's own Gemini app gets working Bangla on
  /// the same device) — so for Bangla specifically, rather than give up to
  /// the system default (which is what was silently mistranscribing it),
  /// pass the standard `bn-BD` id directly and let the recognizer attempt
  /// it. English still resolves purely from the scanned list, unchanged.
  /// The locale id to ask the recognizer for, or null to accept the system
  /// default.
  ///
  /// Ordering lives in [pickPreferredLocale] because the text-to-speech
  /// side has exactly the same problem and had exactly the same bug — see
  /// `locale_preference.dart`. Pure and separated from the plugin so the
  /// rule is testable without a microphone.
  @visibleForTesting
  static String? pickLocaleId(List<String> available, AppLanguage language) =>
      pickPreferredLocale(available, language == AppLanguage.bangla ? 'bn' : 'en');

  Future<String?> _resolveLocaleId(AppLanguage language) async {
    final prefix = language == AppLanguage.bangla ? 'bn' : 'en';
    try {
      final available = await _speech.locales();
      debugPrint('[Stt] wanted prefix="$prefix", device locales=${available.map((l) => l.localeId).toList()}');
      final match = pickLocaleId(
        available.map((l) => l.localeId).toList(),
        language,
      );
      if (match != null) {
        debugPrint('[Stt] resolved locale="$match"');
        return match;
      }
      if (language == AppLanguage.bangla) {
        debugPrint('[Stt] no offline Bangla pack found — trying bn-BD directly (online recognition)');
        return 'bn-BD';
      }
      debugPrint('[Stt] no locale matched prefix="$prefix" — falling back to system default');
    } catch (e) {
      debugPrint('[Stt] locales() lookup failed: $e — falling back to system default');
    }
    return null;
  }

  /// Runs a single push-to-talk listening session. Calls [onResult] with
  /// the best-guess transcript every time the recognizer updates it
  /// (`isFinal: false` for interim words, `true` once it settles) so the
  /// caller can show live captions. Stops automatically after a pause in
  /// speech; [stop] also ends it early (e.g. the user tapping the mic
  /// button again).
  ///
  /// The returned future doesn't complete until the session is genuinely
  /// over (the platform's `done` status, fired once all results have been
  /// delivered) — deliberately not just `SpeechToText.listen()`'s own
  /// future, which resolves the moment the recognizer *starts*. A caller
  /// that raced ahead on that earlier signal (confirmed live: the wake-word
  /// listener restarting its own microphone stream a fraction of a second
  /// after `listenOnce` was called) would fight this session for the mic
  /// and get cut off before the user finished speaking their command.
  ///
  /// Also pauses wake-word listening for the duration of the session (see
  /// `WakeWordService.pauseAround`) whenever one was injected — every
  /// caller gets that coordination automatically, rather than each having
  /// to remember it separately. Confirmed live as a real, recurring bug
  /// when it *wasn't* centralized this way: any mic button that didn't
  /// know to stop wake-word first (the passerby message picker's, e.g.)
  /// hit the same mic-contention race the main chat mic button was
  /// eventually fixed for.
  ///
  /// Prefers `CloudSttService` (genuinely continuous, cloud-quality
  /// recognition — confirmed live to fix the on-device recognizer's
  /// Bangla-locale gibberish problem) whenever one was injected and
  /// `CloudSttConfig.isConfigured`, adapting its open stream to this
  /// method's single-utterance contract with a `pauseFor` silence timer
  /// in Dart (Cloud STT's API is built around "keep listening," not "listen
  /// once," so this method does the "once" part). Falls back to the
  /// on-device recognizer transparently — same signature, same behavior
  /// from the caller's perspective either way — if Cloud STT isn't
  /// configured or fails to start.
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    // Both 1.2s and 1.8s got cut off mid-sentence live in the main chat —
    // reverted to the original 3s there per explicit user preference. The
    // "late reply" feeling reported alongside that is a separate thing
    // (the Gemini API round trip itself, which starts only after this
    // timer expires) — not this value. Callers with a different natural
    // pause length (e.g. composing a passerby message, where 3s alone was
    // still reported as cutting off too early) can override it.
    Duration pauseFor = const Duration(seconds: 3),
    // Hard ceiling on total session length regardless of pauses — not what
    // decides when a message is "done" (that's purely `pauseFor`, i.e.
    // silence), just a backstop against a session that somehow never ends.
    // Default kept generous rather than the old fixed 30s, which cut off
    // a longer message outright even mid-sentence; callers who genuinely
    // want a short ceiling can still pass one.
    Duration listenFor = const Duration(minutes: 5),
    // How long to wait for the user to *start* speaking, when that should
    // differ from [_initialSilenceTimeout]'s generous default.
    //
    // The one caller that wants it shorter is a *continuation* listen — a
    // window opened purely to find out whether somebody who paused
    // mid-sentence is still going. Eight seconds of silence is right when
    // the user has just been asked a question and is gathering their
    // thoughts; it is far too long to sit there after they have already
    // started answering. See `listenForVoiceChoice`.
    Duration? initialSilence,

    /// Proper nouns this session is likely to hear — see [placeNameHints].
    ///
    /// Only reaches Cloud STT; the on-device recognizer has no equivalent.
    /// That asymmetry is fine: the on-device path is already the degraded one,
    /// and this is a recall improvement on top, not a correctness requirement.
    List<String> phraseHints = const [],
  }) async {
    final wakeWord = _wakeWord;
    if (wakeWord != null) {
      await wakeWord.pauseAround(
        () => _listenOnceInner(
            language: language,
            onResult: onResult,
            pauseFor: pauseFor,
            listenFor: listenFor,
            initialSilence: initialSilence,
            phraseHints: phraseHints),
      );
    } else {
      await _listenOnceInner(
          language: language,
          onResult: onResult,
          pauseFor: pauseFor,
          listenFor: listenFor,
          initialSilence: initialSilence,
          phraseHints: phraseHints);
    }
  }

  Future<void> _listenOnceInner({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    required Duration pauseFor,
    required Duration listenFor,
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    await _signalListening();
    final cloud = _cloudStt;
    // No `CloudSttConfig.isConfigured` check here: `CloudSttService.start()`
    // makes exactly that check and returns false, which lands in the same
    // fallback two lines down. Testing it twice only made the cloud branch
    // unreachable from a test, which is how a mid-stream failure went
    // unnoticed long enough to reach testers.
    if (cloud != null) {
      final usedCloud = await _listenOnceViaCloud(
        cloud,
        language: language,
        onResult: onResult,
        pauseFor: pauseFor,
        listenFor: listenFor,
        initialSilence: initialSilence,
        phraseHints: phraseHints,
      );
      if (usedCloud) return;
      debugPrint('[Stt] Cloud STT unavailable — falling back to on-device recognizer');
    }
    await _listenOnceOnDevice(
      language: language,
      onResult: onResult,
      // The on-device recognizer has a single pause setting covering both the
      // wait to start and the gap after speech, so a caller asking for a
      // shorter start window gets it applied to both here.
      pauseFor: initialSilence != null && initialSilence < pauseFor ? initialSilence : pauseFor,
      listenFor: listenFor,
    );
  }

  /// Adapts `CloudSttService`'s open-ended stream into this method's
  /// single-utterance contract: stop as soon as a final result arrives
  /// (matching how every caller already treats the first `isFinal: true`
  /// as "the utterance is complete, act on it now"), or after [pauseFor]
  /// of silence if the user never says anything, or at the [listenFor]
  /// ceiling regardless — whichever comes first. Returns `false` (having
  /// started nothing) if Cloud STT couldn't start at all, so the caller
  /// falls back to the on-device recognizer.
  // How long to wait for the user to *start* talking at all, before any
  // speech has been heard yet — deliberately longer than `pauseFor` (which
  // governs the gap *after* speech has begun). Confirmed live as a real,
  // recurring bug when a single timeout was used for both: the natural
  // reaction-time gap between a wake-word buzz and the user actually
  // starting to speak occasionally exceeded the short post-speech pause
  // window (3s for the main chat), silently ending the session — and
  // everything the user then said was never captured at all.
  static const Duration _initialSilenceTimeout = Duration(seconds: 8);

  Future<bool> _listenOnceViaCloud(
    CloudSttService cloud, {
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    required Duration pauseFor,
    required Duration listenFor,
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    final startWindow = initialSilence ?? _initialSilenceTimeout;
    final done = Completer<void>();
    _cloudSessionDone = done;
    _sessionStartedAt = DateTime.now();
    Timer? silenceTimer;
    Timer? ceilingTimer;
    var heardSpeech = false;
    var lastText = '';
    var finalDelivered = false;
    // Set when the recognition stream dies mid-session. The session then
    // reports failure so the caller retries on the on-device recognizer,
    // instead of the user talking to a microphone that is recording into
    // nothing.
    var streamFailed = false;
    // The recorder teardown, so this method can wait for the microphone to
    // actually be free before it returns. `finish()` is called from inside
    // the recognition stream's own callback and cannot await anything, and
    // leaving the stop unawaited meant `listenOnce` returned — releasing the
    // wake-word suspension — while Cloud STT's `AudioRecorder` was still
    // closing. Two recorders overlapping on one microphone is precisely the
    // contention every other piece of this coordination exists to prevent.
    Future<void>? stopping;

    void finish(String reason, {bool synthesizeFinal = false}) {
      if (done.isCompleted) return;
      debugPrint('[Stt] cloud session ending ($reason)');
      if (synthesizeFinal && !finalDelivered) {
        // The server never sent its own final result before *this* (a
        // Dart-side timeout, not a real end-of-speech signal from Cloud
        // STT) ended the session — without synthesizing one here, every
        // caller waiting specifically for `isFinal: true` to act (send the
        // chat message, select a hazard-report option by voice,
        // auto-submit a passerby message) would simply never hear back at
        // all. Confirmed live as the single root cause behind several very
        // different-looking symptoms — text sitting unsent in the chat
        // box, voice category selection never registering, the passerby
        // overlay no longer auto-opening.
        finalDelivered = true;
        onResult(lastText, true);
      }
      done.complete();
      _cloudSessionDone = null;
      silenceTimer?.cancel();
      ceilingTimer?.cancel();
      stopping = cloud.stop();
    }

    void resetSilenceTimer() {
      silenceTimer?.cancel();
      silenceTimer = Timer(heardSpeech ? pauseFor : startWindow, () => finish('silence', synthesizeFinal: true));
    }

    final started = await cloud.start(
      language: language,
      phraseHints: phraseHints,
      onResult: (text, isFinal) {
        debugPrint('[Stt] cloud heard "$text" (isFinal=$isFinal)');
        lastText = text;
        if (isFinal) finalDelivered = true;
        onResult(text, isFinal);
        if (text.trim().isNotEmpty) heardSpeech = true;
        if (isFinal) {
          finish('final result');
        } else {
          resetSilenceTimer();
        }
      },
      onStreamError: (_) {
        streamFailed = true;
        // Do not synthesize a final result: there is no transcript, and
        // inventing an empty one would look like the user stayed silent.
        finish('cloud stream error');
      },
    );
    if (!started) {
      debugPrint('[Stt] cloud failed to start');
      return false;
    }

    resetSilenceTimer();
    ceilingTimer = Timer(listenFor, () => finish('listenFor ceiling', synthesizeFinal: true));
    await done.future;
    // Cancelled here as well as in `finish()`, because the completer can be
    // completed from outside — `stop()` does exactly that so this method
    // cannot hang. On that path `finish()` never runs, so these timers used
    // to survive their own session and fire into the *next* one: they logged
    // "silence" and called `cloud.stop()` on a session that had just begun.
    //
    // Watched live. Listen sessions degraded from a full 8-second window to
    // ending 64ms after they started, each stale timer killing the next
    // session and leaving one more behind, until the microphone was
    // effectively dead while still reporting that it was listening.
    silenceTimer?.cancel();
    // Not `?.`, unlike the line above, and the asymmetry is real rather than
    // sloppy: `ceilingTimer` is assigned unconditionally before the await, so
    // it is always live here, while `silenceTimer` is assigned inside
    // `resetSilenceTimer()` — a closure the analyzer cannot prove ran.
    ceilingTimer.cancel();
    // Null when the session ended via `SttService.stop()` rather than
    // `finish()` — that path stops the recorder itself, and awaits it.
    //
    // Bounded, because awaiting it at all is a deliberate risk: if the
    // recorder's platform side ever wedges, an unbounded await here never
    // returns, `listenOnce` never returns, the wake-word suspension is never
    // released, and "Hey ANT" is dead until the app is relaunched — with the
    // mic stuck on. A late teardown costs an overlapping recorder for a
    // moment; a hung one costs the whole voice interface.
    await stopping?.timeout(
      const Duration(seconds: 2),
      onTimeout: () => debugPrint('[Stt] cloud recorder did not stop within 2s — releasing the mic anyway'),
    );
    if (streamFailed) {
      // Nothing usable was transcribed, so returning true here would leave
      // the caller believing the user simply said nothing. The most likely
      // cause is the Cloud Speech quota running out, which is enforced
      // mid-stream — this is the only place that can be noticed.
      debugPrint('[Stt] cloud session failed mid-stream — falling back to on-device');
      return false;
    }
    return true;
  }

  Future<void> _listenOnceOnDevice({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    required Duration pauseFor,
    required Duration listenFor,
  }) async {
    if (!await ensureAvailable()) return;
    final localeId = await _resolveLocaleId(language);
    final done = Completer<void>();
    _sessionDone = done;
    _sessionStartedAt = DateTime.now();
    await _speech.listen(
      onResult: (result) => onResult(result.recognizedWords, result.finalResult),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        // Was `true` — confirmed live as the real cause of sessions ending
        // well before the user actually stopped talking (misread at the
        // time as a duration limit): `error_no_match` fires on a merely
        // *transient* recognition hiccup (a brief unclear word, a beat of
        // background noise — very much not "give up entirely"), especially
        // with the online Bangla recognition path, and `cancelOnError`
        // killed the whole session on that alone rather than just letting
        // it keep listening for more speech.
        cancelOnError: false,
        listenMode: ListenMode.confirmation,
        pauseFor: pauseFor,
        listenFor: listenFor,
      ),
    );
    // Bounded by `listenFor` plus a buffer, not awaited unbounded —
    // `SpeechToText.listen()` can silently no-op if the recognizer fails to
    // actually start (no exception, `done` then never fires), which would
    // otherwise hang this forever.
    await done.future.timeout(listenFor + const Duration(seconds: 5), onTimeout: () {});
  }

  /// Stops whichever recognizer is actually active. Every caller of this
  /// (manual re-tap to cancel, every mic-using widget's `dispose()`) needs
  /// this to work regardless of which path a given session took — a stop
  /// that only touched the on-device recognizer would silently leave an
  /// active Cloud STT stream running (until its own `listenOnce`-level
  /// timers eventually caught up), a real bug once there were two possible
  /// backends instead of one. Safe to call both unconditionally: stopping
  /// a backend that was never started is a no-op on either side.
  /// The "start speaking now" cue.
  ///
  /// Two buzzes rather than one, and `heavyImpact` rather than `light`.
  /// Reported from real use: the light single tap was easy to miss
  /// entirely, especially in a pocket, on a busy street, or by a user
  /// whose attention is on traffic — and a cue you cannot feel is the same
  /// as no cue, which leaves someone talking into a microphone that is not
  /// open yet.
  ///
  /// Distinct from the single buzz navigation uses for a turn and the
  /// double-then-pause for arrival, so the three stay tellable apart —
  /// `07_module_plan_haptics.md`'s whole point is a small, learnable
  /// vocabulary rather than a rich one.
  Future<void> _signalListening() async {
    HapticFeedback.heavyImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    HapticFeedback.heavyImpact();
    // A short beat before the mic opens, so the buzz is not still running
    // while the user starts their first word.
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  Future<void> stop() async {
    await _speech.stop();
    await _cloudStt?.stop();
    // Defensive: `done` should follow `stop()` naturally, but if it doesn't
    // (or never fires for some platform-specific reason), don't leave a
    // pending `listenOnce()` caller awaiting forever.
    if (_sessionDone case final pending? when !pending.isCompleted) {
      pending.complete();
    }
    _sessionDone = null;
    // Same defensive completion for an in-progress Cloud STT session — an
    // external `stop()` call (the user re-tapping the mic to cancel, a
    // widget's `dispose()`) bypasses `_listenOnceViaCloud`'s own `finish()`
    // entirely, so without this its `await done.future` would hang forever
    // instead of `listenOnce()` actually returning.
    if (_cloudSessionDone case final pending? when !pending.isCompleted) {
      pending.complete();
    }
    _cloudSessionDone = null;
    _sessionStartedAt = null;
  }

  /// Releases the fault subscription. One `SttService` lives for the life of
  /// the app, so this matters to tests rather than to the app.
  void dispose() {
    _unlistenFaults?.call();
    _unlistenFaults = null;
  }
}
