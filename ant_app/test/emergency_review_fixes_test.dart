// Regressions from the adversarial review of Module 9. Every case here was
// verified against the real matcher before the fix, and each one is a way
// the emergency button was wrong in a direction that matters.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';

void main() {
  bool sos(String t, AppLanguage l, {String? recent}) =>
      LocalIntentMatcher.match(t, l, recentSetting: recent)?.name == 'trigger_emergency';

  group('distress is no longer vetoed by its own negation', () {
    // The old veto rejected any utterance containing a negation. But
    // describing distress is overwhelmingly negative — "I can't breathe",
    // "I can't move" — so the sentences that mattered most returned
    // nothing at all, silently.
    for (final phrase in [
      "help me i can't breathe",
      'help me i cannot move',
      "help me i can't get up",
      "save me i can't see anyone",
      "help me i don't know where i am",
    ]) {
      test('"$phrase"', () => expect(sos(phrase, AppLanguage.english), isTrue));
    }

    // Bangla marks negation post-verbally, so the particle sits at the end
    // of exactly these sentences.
    for (final phrase in [
      'বাঁচাও আমি নড়তে পারছি না',
      'সাহায্য করুন আমি দেখতে পাচ্ছি না',
      'সাহায্য করুন কেউ নেই এখানে',
    ]) {
      test('"$phrase"', () => expect(sos(phrase, AppLanguage.bangla), isTrue));
    }

    test('an actual refusal of help still does nothing', () {
      for (final phrase in ["i don't need help", 'not an emergency', "i'm fine", 'false alarm']) {
        expect(sos(phrase, AppLanguage.english), isFalse, reason: phrase);
      }
      expect(sos('সাহায্য লাগবে না', AppLanguage.bangla), isFalse);
    });
  });

  group('"help me" no longer fires on ordinary requests', () {
    // It is the most common opening line to any voice assistant. Firing an
    // SOS on it would text and telephone the user's family because they
    // asked for something mundane.
    for (final phrase in [
      'can you help me',
      'hey can you help me',
      'please help me with the volume',
      'help me put on my shoes',
      'i need help ordering food',
      'turn off emergency mode',
      'help me get to Gulshan',
    ]) {
      test('"$phrase"', () => expect(sos(phrase, AppLanguage.english), isFalse));
    }

    test('but a bare cry still does', () {
      expect(sos('help me', AppLanguage.english), isTrue);
      expect(sos('help me please', AppLanguage.english), isTrue);
      expect(sos('save me', AppLanguage.english), isTrue);
    });

    test('and an unmistakable word carries any sentence', () {
      expect(sos('emergency', AppLanguage.english), isTrue);
      expect(sos('sos', AppLanguage.english), isTrue);
      expect(sos('বাঁচাও', AppLanguage.bangla), isTrue);
    });
  });

  group('an abduction and a lost user are emergencies', () {
    test('being taken is not routing', () {
      // "take me" was a routing blocker; it is also the verb of being
      // abducted, and the substring check could not tell them apart.
      expect(sos('help me they are trying to take me', AppLanguage.english), isTrue);
      // The routing case still does not fire.
      expect(sos('take me to Gulshan', AppLanguage.english), isFalse);
      expect(sos('help me get to work', AppLanguage.english), isFalse);
    });

    test('a blind user who does not know where they are', () {
      expect(sos("help me i don't know where i am", AppLanguage.english), isTrue);
    });
  });

  group('the emergency wins every race', () {
    test('a pending settings follow-up does not swallow it', () {
      // With lastSettingChanged == 'text_size', 'again' and 'more' are
      // follow-up words — so "help me again" resized the font.
      expect(sos('help me again', AppLanguage.english, recent: 'text_size'), isTrue);
      expect(sos('emergency again', AppLanguage.english, recent: 'text_size'), isTrue);
    });

    test('an ordinary follow-up still works', () {
      final intent =
          LocalIntentMatcher.match('even bigger', AppLanguage.english, recentSetting: 'text_size');
      expect(intent?.args['setting'], 'text_size');
    });
  });

  group('cancelling an SOS takes a deliberate word', () {
    // The dictation vocabulary cancelled on "stop" and "wait" — what people
    // shout at an attacker — and on anything prefix-matching "again",
    // including "against".
    test('shouting at an attacker does not cancel it', () {
      for (final phrase in [
        'stop',
        'stop get away from me',
        'wait',
        'he is pushing me against the wall',
        'again',
        'wrong',
        'ভুল রাস্তায় চলে এসেছি',
        'আবার',
      ]) {
        expect(VoiceCancelWindow.cancelsEmergency(phrase), isFalse, reason: phrase);
      }
    });

    test('saying cancel does', () {
      for (final phrase in ['cancel', 'cancel it', 'no cancel', 'বাতিল', 'ক্যান্সেল']) {
        expect(VoiceCancelWindow.cancelsEmergency(phrase), isTrue, reason: phrase);
      }
    });

    test('silence does not', () {
      expect(VoiceCancelWindow.cancelsEmergency(''), isFalse);
      expect(VoiceCancelWindow.cancelsEmergency('   '), isFalse);
    });

    test('the SOS prompt does not advertise a redo that would kill it', () {
      for (final language in AppLanguage.values) {
        final d = Dashboard.of(language);
        final sosPrompt = d.cancelWindowPromptEmergency(5);
        expect(sosPrompt, isNot(equals(d.cancelWindowPrompt(5))));
        // The generic prompt offers "change it"; that phrase must not
        // appear in the emergency one, where it cancelled outright.
        expect(sosPrompt.toLowerCase(), isNot(contains('change it')));
        expect(sosPrompt.contains('বদলাও'), isFalse);
      }
    });

    test('the dictation window is unchanged', () {
      // These fixes must not have narrowed the hazard-report window.
      expect(VoiceCancelWindow.classify('cancel'), CancelWindowOutcome.cancelled);
      expect(VoiceCancelWindow.classify('change it'), CancelWindowOutcome.edit);
    });
  });
}
