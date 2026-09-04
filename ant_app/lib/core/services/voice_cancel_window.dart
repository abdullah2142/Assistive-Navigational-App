import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../localization/app_language.dart';
import '../localization/dashboard_strings.dart';
import 'stt_service.dart';
import 'tts_service.dart';
import 'voice_matching.dart';

/// What the user did with a pending action during its cancel window.
enum CancelWindowOutcome {
  /// Nothing was said, or nothing meaningful was. The action goes ahead.
  proceed,

  /// The user stopped it. Nothing is sent.
  cancelled,

  /// The user wants to say it again. Nothing is sent, and the caller
  /// reopens dictation rather than dropping the whole flow.
  edit,
}

/// Reads back a dictated message, then gives the user a few seconds to stop
/// it before it is sent.
///
/// ## Why this is not a yes/no confirmation
///
/// [VoiceConfirm] asks "is this right?" and waits for an answer. That is
/// exactly right for a *value* — a phone number, a pairing code, a saved
/// address — where a single wrong digit fails silently and is discovered at
/// the worst possible moment, and where the user is only doing it once.
///
/// It is the wrong shape for free-form prose the user writes many times a
/// day. Asking a question costs a second recognition round trip on a
/// channel that has just demonstrated it is unreliable, and yes/no is the
/// *most* error-prone thing to recognize in Dhaka street noise: both words
/// are short and low-energy, and Bangla attaches its negation after the
/// verb, which this codebase has already been bitten by
/// (`kBanglaNegations`). A confirmation step that mishears "না" as "হ্যাঁ"
/// is worse than no confirmation at all, because the user believes they
/// stopped it.
///
/// So the burden is inverted. The common case — the transcript is fine —
/// costs the user nothing at all: they stay quiet and it sends. Only the
/// rare case costs an utterance, and that utterance is a distinctive
/// content word ("cancel", "বাতিল") rather than a monosyllable, which is
/// substantially easier to recognize under noise.
///
/// ## Where each belongs
///
/// The dividing line is whether anyone can catch the mistake later. A
/// garbled hazard description still reaches a human who can interpret it,
/// and clusters with other reports of the same thing; it degrades, it does
/// not corrupt. A wrong digit in an emergency contact corrupts, and nobody
/// finds out until the Magic Button dials a number that does not exist.
/// Prose gets this; values get [VoiceConfirm].
class VoiceCancelWindow {
  VoiceCancelWindow._();

  /// How long the user has to speak up.
  ///
  /// Five seconds, not the two or three a sighted confirmation toast would
  /// use. The user has just finished *listening* to a read-back, and has to
  /// parse it by ear, decide it is wrong, and start speaking — all of which
  /// happens after the audio ends, not during it. A window shorter than the
  /// reaction it is asking for is decoration rather than a safeguard.
  static const Duration window = Duration(seconds: 5);

  /// Stops the action.
  ///
  /// Deliberately excludes a bare "no". "No" is short, low-energy, and the
  /// single most-confused token in noisy recognition — and it is also a
  /// perfectly ordinary way to begin a sentence. Cancelling on it would
  /// mean losing a report the user had just finished dictating because they
  /// muttered while the window was open.
  static const cancelWords = [
    'cancel', 'stop', 'wait', 'dont send', "don't send", 'do not send', 'no dont',
    'বাতিল', 'থামো', 'দাঁড়াও', 'পাঠিও না', 'পাঠাবে না',
  ];

  /// Stops the action *and* asks for it to be dictated again.
  static const editWords = [
    'change it', 'change that', 'edit', 'redo', 'again', 'say again', 'let me redo',
    'not right', 'wrong', 'thats wrong', "that's wrong",
    'বদলাও', 'ঠিক নয়', 'ভুল', 'আবার বলব', 'আবার',
  ];

  /// Which outcome a heard utterance means, or null when it means nothing.
  ///
  /// Pure, so the vocabulary above is testable without a microphone.
  ///
  /// Edit is checked first: "that's wrong, cancel" contains both, and the
  /// more helpful reading of a user who says both is that they want another
  /// go rather than to abandon what they were doing.
  @visibleForTesting
  static CancelWindowOutcome? classify(String heard) {
    final words = voiceWords(heard);
    if (words.isEmpty) return null;
    bool has(List<String> phrases) => phrases.any((p) {
          final parts = voiceWords(p);
          if (parts.length == 1) return words.any((w) => containsTermInflected([w], parts.first));
          for (var i = 0; i + parts.length <= words.length; i++) {
            if (List.generate(parts.length, (j) => words[i + j] == parts[j]).every((m) => m)) {
              return true;
            }
          }
          return false;
        });
    if (has(editWords)) return CancelWindowOutcome.edit;
    if (has(cancelWords)) return CancelWindowOutcome.cancelled;
    return null;
  }

  /// A short triple tap, distinct from the two firm buzzes that mean "your
  /// turn to speak".
  ///
  /// The difference has to be felt, not counted carefully: this one is
  /// lighter and faster, so it reads as a clock ticking rather than as a
  /// prompt. A user who cannot see the screen has no other way to know a
  /// timer is running, and a cancel window nobody knows about is not a
  /// safeguard.
  static Future<void> signalWindowOpen() async {
    for (var i = 0; i < 3; i++) {
      await HapticFeedback.lightImpact();
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  /// Speaks [readBack], opens the window, and reports what the user did.
  ///
  /// [isCancelled] lets a screen that is being torn down abandon this
  /// cleanly; it returns [CancelWindowOutcome.cancelled] in that case,
  /// because sending something after the user has left the screen is the
  /// one outcome that is never defensible.
  static Future<CancelWindowOutcome> run({
    required TtsService tts,
    required SttService stt,
    required AppLanguage language,
    required String readBack,
    required bool Function() isCancelled,
    Duration? windowOverride,
  }) async {
    final d = Dashboard.of(language);
    final limit = windowOverride ?? window;

    await tts.speak(
      '$readBack ${d.cancelWindowPrompt(limit.inSeconds)}',
      language: language,
    );
    if (isCancelled()) return CancelWindowOutcome.cancelled;

    // No microphone means no way to hear a cancellation. Proceeding is
    // still right: the message was already captured and the user asked for
    // it to be sent — silently dropping their work because the mic died
    // would be the larger failure, and this action is reversible in a way
    // that a saved phone number is not.
    if (!await stt.ensureAvailable()) return CancelWindowOutcome.proceed;
    if (isCancelled()) return CancelWindowOutcome.cancelled;

    await signalWindowOpen();

    final decided = Completer<CancelWindowOutcome>();
    Timer? expiry;

    void settle(CancelWindowOutcome outcome) {
      if (decided.isCompleted) return;
      expiry?.cancel();
      decided.complete(outcome);
    }

    expiry = Timer(limit, () => settle(CancelWindowOutcome.proceed));

    unawaited(stt.listenOnce(
      language: language,
      // Only final results are acted on. An interim transcript is a guess
      // the recognizer is still revising, and "can't" on its way to
      // "cancel" would abort a send the user never asked to abort.
      onResult: (text, isFinal) {
        if (!isFinal) return;
        final outcome = classify(text);
        if (outcome != null) settle(outcome);
      },
      // Slightly beyond the window on both counts, so the recognizer is
      // still open at the moment the window closes rather than having
      // timed out a fraction early and gone deaf for the last of it.
      pauseFor: limit + const Duration(seconds: 1),
      listenFor: limit + const Duration(seconds: 2),
    ));

    final outcome = await decided.future;
    await stt.stop();
    if (isCancelled()) return CancelWindowOutcome.cancelled;
    return outcome;
  }
}
