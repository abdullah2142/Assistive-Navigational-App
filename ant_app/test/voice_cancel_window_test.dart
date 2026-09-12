// The cancel window is the safety net on anything dictated and sent. Its
// job is to be *quiet* when the transcript was fine and to catch the user
// when it wasn't — so both directions are tested, and so is the thing it
// must never do: cancel something the user didn't cancel.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';
import 'package:ant_app/core/services/tts_service.dart';

void main() {
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

  // The five-second window is gone from every path that ships: dictation lost
  // it first (the read-back is the confirmation), and the Magic Button lost it
  // when that reasoning was extended to the emergency. `run` and the narrow SOS
  // vocabulary below stay tested because restoring the window is a decision
  // somebody may make again, and because `cancelsEmergency` is the part that
  // took the most care to get right.
  group('read-back only', () {
    test('returns straight away, with no window to sit through', () async {
      final tts = _RecordingTts();
      final stopwatch = Stopwatch()..start();

      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: tts,
        language: AppLanguage.english,
        readBack: 'Messaging 2 people and calling for help now.',
        isCancelled: () => false,
      );
      stopwatch.stop();

      expect(outcome, CancelWindowOutcome.proceed);
      expect(tts.spoken.single, contains('Messaging 2 people'),
          reason: 'the read-back still happens — it is the confirmation now');
      expect(stopwatch.elapsed, lessThan(VoiceCancelWindow.window),
          reason: 'the point of the change is that it does not wait');
    });

    test('a caller that has gone away still stops it', () async {
      // The only remaining way out: the screen or flow being torn down under
      // it. The Magic Button passes a constant false here, because an SOS
      // does not stop just because a widget did.
      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: _RecordingTts(),
        language: AppLanguage.english,
        readBack: 'anything',
        isCancelled: () => true,
      );
      expect(outcome, CancelWindowOutcome.cancelled);
    });

    test('a failed read-back does not swallow the send', () async {
      // Losing the voice must not lose the message. This is the emergency
      // path: a TTS engine that throws cannot be allowed to mean "cancelled".
      final outcome = await VoiceCancelWindow.readBackOnly(
        tts: _ThrowingTts(),
        language: AppLanguage.english,
        readBack: 'anything',
        isCancelled: () => false,
      );
      expect(outcome, CancelWindowOutcome.proceed);
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
