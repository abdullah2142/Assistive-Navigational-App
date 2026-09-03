import '../../../core/localization/app_language.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';

/// One voice-selectable option on an onboarding screen — the label spoken
/// by the user (compared against, fuzzily) and what happens once it's
/// recognized. Mirrors the tap target it's paired with (usually a
/// `BigChoiceCard`) so voice and touch always agree on what's available.
///
/// [synonyms] gives this choice "wiggle room" beyond its exact on-screen
/// label — confirmed live as a real gap without this: on the role
/// selection screen, saying "myself" (paraphrasing the *description*,
/// "Set up navigation help for myself", rather than repeating the label
/// "I need assistance" verbatim) wasn't recognized at all, because a
/// single word like "myself" shares no words with "I need assistance" and
/// [fuzzyVoiceMatch]'s word-overlap threshold has nothing to work with.
/// Each synonym is checked independently as its own short phrase (not
/// merged into one long target), so a single distinguishing word matches
/// cleanly on its own instead of getting diluted against a whole sentence.
class OnboardingVoiceChoice {
  const OnboardingVoiceChoice({required this.label, this.synonyms = const [], required this.onSelect});
  final String label;
  final List<String> synonyms;
  final void Function() onSelect;

  bool matches(String heard) {
    if (fuzzyVoiceMatch(heard, label)) return true;
    for (final synonym in synonyms) {
      if (fuzzyVoiceMatch(heard, synonym)) return true;
    }
    return false;
  }
}

/// Forgiving whole-*word* match: a near-miss transcript ("no vision" heard
/// as "no visions", or a dropped syllable in Bangla) still lands on the
/// right choice instead of forcing the user to repeat themselves for a
/// trivial STT slip — but matching only ever happens at word granularity,
/// deliberately never a raw substring check across the whole phrase.
///
/// Confirmed live as a real bug from the earlier, simpler version of this
/// function (a plain `spoken.contains(target) || target.contains(spoken)`
/// check first): saying "male voice" matched the *female* voice option,
/// because the label text "female" itself contains "male" as a literal
/// substring ("fe-MALE"). Comparing whole word tokens instead of raw
/// characters is what a English/Bangla word actually *means* to a
/// listener — "male" and "female" are different words even though one's
/// spelling contains the other's.
bool fuzzyVoiceMatch(String spoken, String target) {
  final s = spoken.toLowerCase().trim();
  final t = target.toLowerCase().trim();
  if (s.isEmpty || t.isEmpty) return false;
  if (s == t) return true;

  final sWords = _wordsOf(s);
  final tWords = _wordsOf(t);
  if (tWords.isEmpty) return false;

  var matchedWords = 0;
  for (final word in tWords) {
    if (sWords.contains(word)) {
      matchedWords++;
      continue;
    }
    // Near-miss fallback for exactly this one target word — only applies
    // against heard words at least as long as a large majority of it, so a
    // short, different word (like "male" against "female") is never long
    // enough to qualify as a near-miss of a longer, unrelated word.
    final minLen = (word.length * 0.7).ceil().clamp(3, word.length);
    for (final heardWord in sWords) {
      if (heardWord.length < minLen) continue;
      if (heardWord.contains(word.substring(0, minLen)) || word.contains(heardWord)) {
        matchedWords++;
        break;
      }
    }
  }
  return matchedWords >= (tWords.length / 2).ceil();
}

/// Splits on whitespace and common label punctuation (the em dash in
/// labels like "Bangla — Male voice"), dropping single-character
/// fragments — those are never meaningful words to match against on their
/// own, only noise from splitting on punctuation.
Set<String> _wordsOf(String text) =>
    text.split(RegExp(r'[\s—–\-]+')).where((w) => w.length > 1).toSet();

/// Every phrasing recognized as "I need the options read out", not just the
/// literal words "help"/"hint" — deliberately broad (explicit user
/// feedback: this shouldn't be a fixed set of magic words, it should catch
/// the *intent* behind "I don't know what to say", "can you repeat that",
/// "I didn't catch that", "what were the choices", "I'm confused", etc.).
/// There's no LLM call in this tight listen-loop to do real intent
/// classification (Gemini isn't wired into per-utterance recognition, and
/// calling out to it here would add real network latency to something
/// meant to feel instant) — this is a wide phrase-containment heuristic
/// instead, covering the natural ways someone actually says this rather
/// than a handful of exact trigger words.
const _helpTriggersEn = [
  'help',
  'hint',
  'option',
  'choice',
  'repeat',
  'again',
  "didn't catch",
  'didnt catch',
  "didn't hear",
  'didnt hear',
  "didn't understand",
  'didnt understand',
  "don't understand",
  'dont understand',
  "don't know",
  'dont know',
  'not sure',
  "i'm not sure",
  'im not sure',
  'confused',
  'what can i say',
  'what should i say',
  'what do i say',
  'what were',
  'what was that',
  'come again',
  'pardon',
  'read them',
  'read that',
  'read it',
  'list them',
  'tell me again',
  'one more time',
];
const _helpTriggersBn = [
  'সাহায্য',
  'সাহায‍্য',
  'হেল্প',
  'অপশন',
  'বিকল্প',
  'আবার',
  'পুনরায়',
  'একবার',
  'রিপিট',
  'বুঝিনি',
  'বুঝি নাই',
  'বুঝি নি',
  'বুঝতে পারিনি',
  'বুঝতে পারি নাই',
  'বুঝলাম না',
  'বুঝছি না',
  'শুনিনি',
  'শুনি নাই',
  'শুনতে পাইনি',
  'কানে আসেনি',
  'জানি না',
  'জানিনা',
  'জানি নাই',
  'বলতে পারছি না',
  'দ্বিধা',
  'কনফিউজড',
  'গুলিয়ে গেছে',
  'কী বলব',
  'কি বলব',
  'কী বলবো',
  'কি বলবো',
  'কী বলি',
  'কি বলি',
  'কী ছিল',
  'কি ছিল',
  'কী বললে',
  'কি বললে',
  'কী বললেন',
  'কি বললেন',
  'কী বলছিলে',
  'কী বলছিলেন',
  'তালিকা',
  'কী কী আছে',
  'কি কি আছে',
  'অপশনগুলো',
  'বিকল্পগুলো',
  'কী কী বিকল্প',
  'একটু বুঝায়ে বলেন',
  'একটু বুঝিয়ে বলুন',
  'আস্তে বলেন',
  'আস্তে বলুন',
  'ধীরে বলুন',
  'স্লো করে বলেন',
];

/// Whether [text] is a request to hear the full option list rather than an
/// attempt at answering — checked as short-utterance substring containment
/// against a broad phrase set (see doc comment on the trigger lists above),
/// not exact-word matching. English triggers are often multi-word, so this
/// checks containment rather than reusing [fuzzyVoiceMatch], which expects
/// both sides to already be a specific label.
///
/// Public (not just used by [listenForVoiceChoice]) — screens that drive
/// their own bespoke voice loop instead of the generic choice mechanism
/// (e.g. `PasserbyMessagesScreen`, which mixes suggestion-toggling with
/// free-text dictation) still want the same "help"/"hint"/"বিকল্প" etc.
/// recognition, not a second, differently-tuned copy of it.
bool isHelpRequest(String text) {
  final lower = text.toLowerCase().trim();
  if (lower.length > 45) return false; // a real answer, not a request for help
  return _helpTriggersEn.any(lower.contains) || _helpTriggersBn.any(text.contains);
}

/// Listens indefinitely for one of [choices] to be spoken, re-prompting
/// with [retryHint] between attempts rather than silently looping — same
/// "separate the listening from the silence" fix the hazard-report and
/// passerby-composer flows got after live testing showed a silent retry
/// loop felt broken rather than patient. Returns as soon as one choice
/// matches (after calling its `onSelect`) or [isCancelled] reports true
/// (the screen was left, e.g. via back or a manual tap already handled it).
///
/// [helpText] — the full option list, if the caller has one — is deliberately
/// never spoken up front (explicit user feedback: forcing a full read-out of
/// every option before the user can even respond makes the assistant feel
/// slow and unresponsive to someone who already knows what they want). It's
/// offered only when asked for ("help"/"hint"/"বিকল্প" etc., recognized here)
/// so a user who needs it can always get it without derailing one who doesn't.
Future<void> listenForVoiceChoice({
  required SttService stt,
  required TtsService tts,
  required AppLanguage language,
  required List<OnboardingVoiceChoice> choices,
  String? helpText,
  required String retryHint,
  required bool Function() isCancelled,
}) async {
  if (choices.isEmpty) return;
  // After this many unmatched attempts in a row, the full option list is
  // read out automatically — a user who doesn't know (or forgets) they can
  // ask for "help" shouldn't be stuck in a "sorry, didn't catch that" loop
  // forever with no way forward. Saying "help" explicitly still works
  // immediately at any point; this is just a safety net for whoever
  // doesn't think to.
  const missesBeforeAutoHelp = 2;
  var misses = 0;
  while (!isCancelled()) {
    if (!await stt.ensureAvailable()) return;
    OnboardingVoiceChoice? matched;
    var wantsHelp = false;
    await stt.listenOnce(
      language: language,
      onResult: (text, isFinal) {
        if (!isFinal || matched != null || wantsHelp) return;
        final trimmed = text.trim();
        if (trimmed.isEmpty) return;
        if (helpText != null && _isHelpRequest(trimmed)) {
          wantsHelp = true;
          return;
        }
        for (final choice in choices) {
          if (choice.matches(trimmed)) {
            matched = choice;
            break;
          }
        }
      },
    );
    if (isCancelled()) return;
    final result = matched;
    if (result != null) {
      result.onSelect();
      return;
    }
    if (wantsHelp && helpText != null) {
      misses = 0;
      await tts.speak(helpText, language: language);
      continue;
    }
    misses++;
    if (helpText != null && misses >= missesBeforeAutoHelp) {
      misses = 0;
      await tts.speak(helpText, language: language);
    } else {
      await tts.speak(retryHint, language: language);
    }
  }
}
