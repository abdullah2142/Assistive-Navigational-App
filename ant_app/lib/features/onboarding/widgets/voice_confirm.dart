import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/localization/onboarding_strings.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import 'onboarding_voice.dart';

/// Reads a dictated value back and waits for the user to confirm it.
///
/// ## Why every voice input goes through this
///
/// A sighted user dictating a phone number glances at the field, sees the
/// recognizer dropped a digit, and fixes it before moving on. That glance
/// is the entire error-correction mechanism, and a blind user does not have
/// it. Without a read-back, a misheard digit is committed silently and only
/// surfaces later — as an emergency contact that does not ring, a pairing
/// code that never works, or a saved place that routes somewhere else.
///
/// So: nothing captured by voice is committed until it has been said back
/// and accepted. This is the shared implementation, so that behaviour is
/// identical everywhere rather than re-invented per screen (which is how
/// half the screens ended up without it).
///
/// The read-back is also *how the value is spelled out*, not just whether
/// it was heard. Digits are spaced ([spokenDigitsForReadback]) because a
/// text-to-speech engine reads "01712345678" as one enormous number, which
/// nobody can check by ear.
class VoiceConfirm {
  VoiceConfirm._();

  /// Speaks [value] back under [fieldLabel] and listens for yes/no.
  ///
  /// Returns true to accept, false to re-dictate, and null when the screen
  /// was left mid-confirmation ([isCancelled]) — callers must treat null as
  /// "abandon", never as either answer.
  ///
  /// Loops on an unclear answer rather than assuming. Assuming "yes" would
  /// commit something the user may have been trying to reject; assuming
  /// "no" would throw away something correct and make them say it all
  /// again. Neither is acceptable when the question is this cheap to repeat.
  static Future<bool?> readBackAndConfirm({
    required TtsService tts,
    required SttService stt,
    required AppLanguage language,
    required String fieldLabel,
    required String value,
    required bool Function() isCancelled,
    bool isDigits = false,
  }) async {
    final d = Dashboard.of(language);
    final s = Onboarding.of(language);
    final spoken = isDigits ? spokenDigitsForReadback(value) : value;

    while (!isCancelled()) {
      await tts.speak(d.confirmHeardValue(fieldLabel: fieldLabel, value: spoken), language: language);
      if (isCancelled()) return null;
      if (!await stt.ensureAvailable()) {
        // No microphone at all. Accepting is the right default here: the
        // value was already captured somehow (a typed field, or dictation
        // that worked before the mic became unavailable), and discarding a
        // user's input because we cannot ask about it is worse than
        // keeping it — they can still correct it afterwards.
        return true;
      }

      bool? answer;
      await stt.listenOnce(
        language: language,
        onResult: (text, isFinal) {
          if (!isFinal || answer != null) return;
          final trimmed = text.trim();
          if (trimmed.isEmpty) return;
          answer = classifyTraitYesNo(
            trimmed,
            presentPhrases: const [],
            absentPhrases: const [],
            bareYes: s.confirmYesWords,
            bareNo: s.confirmNoWords,
          );
        },
      );
      if (isCancelled()) return null;
      if (answer == true) {
        await tts.speak(d.confirmValueAccepted, language: language);
        return true;
      }
      if (answer == false) {
        await tts.speak(d.confirmValueRetry, language: language);
        return false;
      }
      // Unclear — the loop re-reads the value and asks again.
    }
    return null;
  }
}

/// Spaces digits out so a text-to-speech engine reads them one at a time.
///
/// "01712345678" is otherwise pronounced as a single seventeen-billion
/// number, which is unverifiable by ear — precisely defeating the purpose
/// of reading it back. Grouped in threes as well, since an unbroken run of
/// eleven spoken digits is beyond what most people can hold and check
/// against what they said.
String spokenDigitsForReadback(String digits) {
  final cleaned = digits.replaceAll(RegExp(r'\s+'), '');
  final groups = <String>[];
  for (var i = 0; i < cleaned.length; i += 3) {
    final end = (i + 3 < cleaned.length) ? i + 3 : cleaned.length;
    groups.add(cleaned.substring(i, end).split('').join(' '));
  }
  return groups.join(',  ');
}
