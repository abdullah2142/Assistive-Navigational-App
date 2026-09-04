// The cancel window is the safety net on anything dictated and sent. Its
// job is to be *quiet* when the transcript was fine and to catch the user
// when it wasn't — so both directions are tested, and so is the thing it
// must never do: cancel something the user didn't cancel.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';

void main() {
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
