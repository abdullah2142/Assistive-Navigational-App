// The cancel window is the safety net on anything dictated and sent. Its
// job is to be *quiet* when the transcript was fine and to catch the user
// when it wasn't — so both directions are tested, and so is the thing it
// must never do: cancel something the user didn't cancel.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/core/services/stt_service.dart';

void main() {
  // `VoiceCancelWindow.run` fires a haptic when the window opens, and
  // `HapticFeedback` reaches a platform channel.
  TestWidgetsFlutterBinding.ensureInitialized();

  group("English heard in a Bangla session", _phoneticBanglaTests);
  group('what stops a send', () {
    for (final phrase in ['cancel', 'Cancel!', 'stop', 'wait', "don't send that", 'বাতিল', 'থামো']) {
      test('"$phrase" cancels', () {
        expect(VoiceCancelWindow.classify(phrase), CancelWindowOutcome.cancelled);
      });
    }
  });

  group('what asks for another go', () {
    for (final phrase in ['change it', "that's wrong", 'edit', 'say again', 'বদলাও', 'ভুল']) {
      test('"$phrase" re-dictates', () {
        expect(VoiceCancelWindow.classify(phrase), CancelWindowOutcome.edit);
      });
    }

    test('saying both means try again, not abandon', () {
      expect(VoiceCancelWindow.classify('no that is wrong, cancel it'), CancelWindowOutcome.edit);
    });
  });

  group('what must NOT stop a send', () {
    // A cancel window that fires on ordinary speech is worse than none: the
    // user finishes dictating a hazard report, mutters, and silently loses
    // it without ever being told.
    const innocuous = [
      '',
      '   ',
      'yes',
      'okay',
      'hmm',
      'uh huh',
      'thanks',
      // Bare "no" is deliberately excluded from the cancel vocabulary — see
      // the doc comment. It is the most-confused token in noisy recognition
      // and a normal way to start a sentence.
      'no',
      'no problem',
      'the road is blocked',
      'there is water on the street',
      'হ্যাঁ',
      'রাস্তা বন্ধ',
    ];
    for (final phrase in innocuous) {
      test('"$phrase" lets it send', () {
        expect(VoiceCancelWindow.classify(phrase), isNull);
      });
    }
  });

  // Two paths, two rules, and the line between them is whether a mistake can
  // be *raised by accident*.
  //
  // Dictated prose — a passer-by message, a hazard description — is read back
  // and sent. The user chose to dictate it, heard it repeated, and a garbled
  // one still reaches a human who can make sense of it, so five seconds of
  // silence on every single one is pure cost.
  //
  // The Magic Button keeps its window. An SOS can be triggered by a
  // volume-down hold nobody meant, and what follows is a message and a phone
  // call to somebody's family that cannot be taken back. See
  // `the window is long enough to react to` below for that half.
  group('read-back only — for things the user deliberately dictated', () {
    test('returns straight away, with no window to sit through', () async {
      final tts = _RecordingTts();
      final stopwatch = Stopwatch()..start();

      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: tts,
        language: AppLanguage.english,
        readBack: 'Show this to a passer-by: I need help crossing the road.',
        isCancelled: () => false,
      );
      stopwatch.stop();

      expect(outcome, CancelWindowOutcome.proceed);
      expect(tts.spoken.single, contains('I need help crossing the road'),
          reason: 'the read-back still happens — it is the confirmation here');
      expect(stopwatch.elapsed, lessThan(VoiceCancelWindow.window),
          reason: 'the point of the change is that it does not wait');
    });

    test('a caller that has gone away still stops it', () async {
      // The only way out on this path: the sheet being dismissed under it.
      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: _RecordingTts(),
        language: AppLanguage.english,
        readBack: 'anything',
        isCancelled: () => true,
      );
      expect(outcome, CancelWindowOutcome.cancelled);
    });

    test('a failed read-back does not swallow the send', () async {
      // Losing the voice must not lose the message: a TTS engine that throws
      // cannot be allowed to mean "the user cancelled".
      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: _ThrowingTts(),
        language: AppLanguage.english,
        readBack: 'anything',
        isCancelled: () => false,
      );
      expect(outcome, CancelWindowOutcome.proceed);
    });
  });

  // The other half of the split: the SOS keeps its window, and these are the
  // properties it depends on. Written against `run` directly because no test
  // drives `EmergencyService` end to end — it would need fakes for the SMS
  // channel, the alert service and routing — so this is where the behaviour
  // the Magic Button relies on is actually pinned down.
  group('the SOS window — for an alarm that can be raised by accident', () {
    test('silence sends, and only after the full window', () async {
      // Defaulting to *proceed* is the whole design: requiring a confirmed
      // "yes" would mean an unconscious or panicking user is never helped.
      // But it must not send early, or the window is decorative.
      final stt = _SilentStt();
      final stopwatch = Stopwatch()..start();

      final outcome = await VoiceCancelWindow.run(
        tts: _RecordingTts(),
        stt: stt,
        language: AppLanguage.english,
        readBack: 'about to send',
        isCancelled: () => false,
        emergency: true,
        windowOverride: const Duration(milliseconds: 300),
      );
      stopwatch.stop();

      expect(outcome, CancelWindowOutcome.proceed);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(250),
          reason: 'the user has to actually get the time they were promised');
    });

    test('"cancel" inside the window stops it', () async {
      final outcome = await VoiceCancelWindow.run(
        tts: _RecordingTts(),
        stt: _SayingStt('cancel'),
        language: AppLanguage.english,
        readBack: 'about to send',
        isCancelled: () => false,
        emergency: true,
        windowOverride: const Duration(seconds: 5),
      );
      expect(outcome, CancelWindowOutcome.cancelled);
    });

    test('shouting at an attacker does not stop it', () async {
      // The narrow SOS vocabulary, exercised through `run` rather than just
      // `cancelsEmergency`: "stop" is what somebody in trouble shouts, and it
      // must not cancel the call for help.
      final outcome = await VoiceCancelWindow.run(
        tts: _RecordingTts(),
        stt: _SayingStt('stop it get away from me'),
        language: AppLanguage.english,
        readBack: 'about to send',
        isCancelled: () => false,
        emergency: true,
        windowOverride: const Duration(milliseconds: 300),
      );
      expect(outcome, CancelWindowOutcome.proceed);
    });

    test('no microphone still sends', () async {
      // No way to hear a cancellation is not a reason to abandon an
      // emergency.
      final outcome = await VoiceCancelWindow.run(
        tts: _RecordingTts(),
        stt: _UnavailableStt(),
        language: AppLanguage.english,
        readBack: 'about to send',
        isCancelled: () => false,
        emergency: true,
        windowOverride: const Duration(milliseconds: 300),
      );
      expect(outcome, CancelWindowOutcome.proceed);
    });

    test('the read-back names the time and the word that stops it', () {
      for (final language in AppLanguage.values) {
        final line = Dashboard.of(language).emergencyAbout(3, VoiceCancelWindow.window.inSeconds);
        expect(line, contains('3'), reason: 'how many people');
        expect(line, contains('${VoiceCancelWindow.window.inSeconds}'),
            reason: 'how long they have');
      }
      // And the word itself, in the language it will be said in.
      expect(Dashboard.of(AppLanguage.english).emergencyAbout(3, 5).toLowerCase(), contains('cancel'));
      expect(Dashboard.of(AppLanguage.bangla).emergencyAbout(3, 5), contains('বাতিল'));
    });
  });

  group('the window is long enough to react to', () {
    test('at least as long as it takes to hear, decide and speak', () {
      // The user is reacting to audio that has only just finished. Anything
      // shorter than a few seconds is decoration, not a safeguard.
      expect(VoiceCancelWindow.window.inSeconds, greaterThanOrEqualTo(4));
    });

    test('the spoken prompt states the escape route and the time', () {
      for (final language in AppLanguage.values) {
        final d = Dashboard.of(language);
        final prompt = d.cancelWindowPrompt(VoiceCancelWindow.window.inSeconds);
        expect(prompt, contains('${VoiceCancelWindow.window.inSeconds}'));
        // The word the user has to say must be in the sentence that tells
        // them to say it — nobody can be expected to remember it from a
        // different screen.
        final hasCancelWord = VoiceCancelWindow.cancelWords
            .any((w) => prompt.toLowerCase().contains(w.toLowerCase()));
        expect(hasCancelWord, isTrue, reason: 'prompt for $language names no cancel word: $prompt');
      }
    });

    test('the Bangla prompt is actually Bangla', () {
      final prompt = Dashboard.of(AppLanguage.bangla).cancelWindowPrompt(5);
      expect(RegExp(r'[ঀ-৿]').hasMatch(prompt), isTrue);
    });
  });
}

/// English said inside a Bangla session.
///
/// The recognizer runs in one locale for the whole session, so a user who
/// says the English word "cancel" while the app is in Bangla never gets Latin
/// text back — it arrives as `ক্যান্সেল`. Reported from the device: "cancel
/// bolar poreo cancel hocche na, tobe বাতিল, দাঁড়াও catch koreche banglay".
void _phoneticBanglaTests() {
  test('English "cancel" heard in a Bangla session still cancels', () {
    expect(VoiceCancelWindow.classify('ক্যান্সেল'), CancelWindowOutcome.cancelled);
    expect(VoiceCancelWindow.classify('ক্যানসেল'), CancelWindowOutcome.cancelled);
  });

  test('the Bangla words that already worked still do', () {
    // The tester confirmed these were fine; they must not regress.
    expect(VoiceCancelWindow.classify('বাতিল'), CancelWindowOutcome.cancelled);
    expect(VoiceCancelWindow.classify('দাঁড়াও'), CancelWindowOutcome.cancelled);
  });

  test('and so does plain English in an English session', () {
    expect(VoiceCancelWindow.classify('cancel'), CancelWindowOutcome.cancelled);
  });

  test('the emergency vocabulary already had this and keeps it', () {
    expect(VoiceCancelWindow.cancelsEmergency('ক্যান্সেল'), isTrue);
  });
}

class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

class _ThrowingTts implements TtsService {
  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async =>
      throw StateError('no audio route');

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

/// Never hears anything — the window closes on its own.
class _SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {}

  @override
  Future<void> stop() async {}
}

class _SayingStt extends SttService {
  _SayingStt(this._utterance);
  final String _utterance;

  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    onResult(_utterance, true);
  }

  @override
  Future<void> stop() async {}
}

class _UnavailableStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => false;

  @override
  Future<void> stop() async {}
}
