import 'package:flutter/foundation.dart';

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

  bool matches(String heard) => matchScore(heard) > 0;

  /// How well [heard] fits this choice, 0 (no match) to 1 (every word of the
  /// target accounted for).
  ///
  /// A score rather than a yes/no because several choices on a screen can
  /// legitimately match the same utterance, and the caller has to be able to
  /// tell which fits *best*. Confirmed on device: "Low vision" selected "No
  /// vision", because both share the word "vision", `fuzzyVoiceMatch` accepts
  /// half a target's words, and "No vision" was simply listed first. The
  /// discriminating word — the whole content of the answer — was the one
  /// being ignored. Setting a blind user's vision level to the opposite of
  /// what they said is not a near miss.
  double matchScore(String heard) {
    var best = fuzzyMatchScore(heard, label);
    for (final synonym in synonyms) {
      final score = fuzzyMatchScore(heard, synonym);
      if (score > best) best = score;
    }
    return best;
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
bool fuzzyVoiceMatch(String spoken, String target) => fuzzyMatchScore(spoken, target) > 0;

/// The fraction of [target]'s words accounted for by [spoken], or 0 when that
/// falls below the half-match threshold.
///
/// [fuzzyVoiceMatch] is this reduced to a yes/no, kept because most callers
/// only want that.
double fuzzyMatchScore(String spoken, String target) {
  final s = spoken.toLowerCase().trim();
  final t = target.toLowerCase().trim();
  if (s.isEmpty || t.isEmpty) return 0;
  if (s == t) return 1;

  final sWords = _wordsOf(s);
  final tWords = _wordsOf(t);
  if (tWords.isEmpty) return 0;

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
    //
    // Words of three letters or fewer require an exact hit and never take
    // the near-miss path: there is no room in them for a "near" miss that
    // is not simply a different word.
    //
    // This used to read `.clamp(3, word.length)`, which **throws** when the
    // word is shorter than 3 — `clamp` rejects a lower limit above its upper
    // one. Any label or synonym containing a two-letter word therefore blew
    // up mid-match, and the exception escaped through `matches()` into the
    // `onResult` callback, killing the whole recognition attempt. The screen
    // then looked like it was simply ignoring the user. It broke "I am
    // ready" on the command tour (the word "am") and every place name typed
    // at the frequent-places prompt, because the skip list contains "no
    // thanks" and the check runs against every skip word before the name is
    // ever accepted. Both were reported as "doesn't take my answer".
    if (word.length <= 3) continue;
    final minLen = (word.length * 0.7).ceil();
    for (final heardWord in sWords) {
      if (heardWord.length < minLen) continue;
      if (heardWord.contains(word.substring(0, minLen)) || word.contains(heardWord)) {
        matchedWords++;
        break;
      }
    }
  }
  if (matchedWords < (tWords.length / 2).ceil()) return 0;
  return matchedWords / tWords.length;
}

/// Splits on whitespace and common label punctuation (the em dash in
/// labels like "Bangla — Male voice"), dropping single-character
/// fragments — those are never meaningful words to match against on their
/// own, only noise from splitting on punctuation.
Set<String> _wordsOf(String text) => text
    .split(RegExp(r'[\s—–\-]+'))
    // Punctuation stripped, or "vision." never equals "vision" and every
    // exact match at the end of a sentence silently degrades into the
    // near-miss path. Cloud STT punctuates, so this is the common case, not
    // the edge one.
    .map((w) => w.replaceAll(RegExp(r'[^\wঀ-৿]'), ''))
    .where((w) => w.length > 1)
    .toSet();

/// Classifies a yes/no answer about some trait ("are you deaf?", "do
/// crowded places make you anxious?") — deliberately *not* built on
/// [fuzzyVoiceMatch]/[OnboardingVoiceChoice], because word-overlap scoring
/// is fundamentally wrong for this shape of question. Confirmed live as a
/// real bug: "I can hear my assistant" and the "Yes" choice's synonym
/// "can't hear" share the single word "hear", which was enough to satisfy
/// [fuzzyVoiceMatch]'s 50%-of-target-words threshold for a 2-word target —
/// so a clear, unambiguous statement of *good* hearing could match the
/// "I'm deaf" answer, purely because negation isn't something word-overlap
/// counting can see at all. No amount of adding more synonyms fixes that;
/// the matching *shape* itself was wrong for a question with two directly
/// opposite answers.
///
/// [presentPhrases] and [absentPhrases] must each already have any
/// necessary negation baked into the phrase itself ("can't hear" go in
/// [presentPhrases] whole, not decomposed into "hear" + a generic
/// negation flag) — deliberately not a generic negation-flip step, since
/// negation changes meaning in opposite directions depending on *what's*
/// being negated (negating a capability word like "hear" flips toward
/// "trait present"; negating a difficulty word like "deaf" flips toward
/// "trait absent") and conflating the two re-introduces the same class of
/// bug this exists to avoid.
///
/// Returns `null` when nothing recognizable was said, or when both sides
/// matched (a genuinely mixed signal) — the caller should treat that as
/// "didn't understand" and ask again, never guess.
bool? classifyTraitYesNo(
  String heard, {
  required List<String> presentPhrases,
  required List<String> absentPhrases,
  List<String> bareYes = const ['yes', 'yeah', 'yep', 'yup', 'sure', 'correct', 'জি', 'হ্যাঁ', 'হ্যা'],
  List<String> bareNo = const ['no', 'nope', 'nah', 'না', 'নাহ'],
}) {
  final trimmed = heard.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();

  // The specific phrase lists are checked FIRST, before any bare yes/no.
  //
  // They used to be checked second, and that was a real bug with a very
  // bad failure mode: Bangla negates *after* the verb, so the app's own
  // suggested Deaf answer — "কানে শুনি না" ("I don't hear with my ears") —
  // ends in the bare-no particle "না" and is short enough to hit the bare
  // shortcut below. A Deaf user repeating back the exact phrase the app
  // had just read out to them was classified as hearing perfectly well,
  // and the entire Deaf/Hard-of-Hearing accommodation silently never
  // turned on.
  //
  // Ordering is the fix, not more phrases: a phrase from these lists
  // already has its negation baked in (see this function's doc comment)
  // and is strictly more specific than a bare particle, so it must win.
  // Longest match wins, rather than "any match on both sides is a tie".
  //
  // The lists overlap by construction: "bother me" is a present phrase and
  // "don't bother me" is an absent one, and the second contains the first.
  // Treating both as equal made "they don't bother me" — an ordinary,
  // unambiguous English answer — score as a conflict and return null, so the
  // question was asked again and again. The longer phrase is the more
  // specific one and is what the user actually said.
  final present = _longestMatch(lower, trimmed, presentPhrases);
  final absent = _longestMatch(lower, trimmed, absentPhrases);
  if (present != absent) return present > absent;

  // Homophones of a bare answer, accepted only when they are the *whole*
  // utterance.
  //
  // Confirmed on device: answering "no" to a yes/no question, Cloud STT's
  // command_and_search model returned interim results of "No." and then a
  // final of "Know." Whole-word matching — which exists precisely so that
  // the "no" inside "know" cannot fire — then found nothing, and the
  // question was asked again. The user reported the screen refusing to take
  // "no" for an answer, and it was.
  //
  // Restricted to a one-word utterance on purpose. "I know" and "you know"
  // are ordinary speech and must not be read as refusals; a bare "Know." in
  // reply to a yes/no question is a misheard "no" essentially every time.
  if (_spokenWords(lower).length == 1) {
    if (_bareNoHomophones.contains(lower.replaceAll(RegExp(r'[^\wঀ-৿]'), ''))) return false;
  }

  // Common negative openers that are neither a bare particle nor
  // trait-specific. "not really" is one of the most natural ways to say no
  // to a question about yourself, and nothing above recognized it.
  for (final opener in _bareNoOpeners) {
    if (lower == opener || lower.startsWith('$opener ') || lower.startsWith('$opener,')) return false;
  }

  // Whole words, never substrings — "no" lives inside "know", "another"
  // and "normal"; "yes" inside "yesterday". Same lesson as [fuzzyVoiceMatch]
  // matching "male" inside "female": "I know I do" came back as a flat
  // refusal.
  final words = _spokenWords(lower);
  final first = words.isEmpty ? '' : lower.split(RegExp(r'\s+')).first.replaceAll(RegExp(r'[^\wঀ-৿]'), '');

  // An utterance that *opens* with yes or no is answering the question,
  // however long it runs on afterwards — "no it doesn't bother me at all".
  // The length guard below exists for the opposite case, a long sentence
  // that merely contains the word somewhere, and it used to reject these
  // too.
  if (bareNo.any((w) => first == w.toLowerCase())) return false;
  if (bareYes.any((w) => first == w.toLowerCase())) return true;

  // Otherwise only a short utterance may be decided by a bare particle: a
  // longer sentence that happens to contain "yes" in passing shouldn't.
  if (trimmed.length > 15) return null;
  if (bareNo.any((w) => words.contains(w.toLowerCase()))) return false;
  if (bareYes.any((w) => words.contains(w.toLowerCase()))) return true;
  return null;
}

/// Length of the longest phrase in [phrases] found in the utterance, or 0.
///
/// Length, not a boolean, so an overlapping pair resolves to the more
/// specific phrase — see [classifyTraitYesNo].
int _longestMatch(String lower, String original, List<String> phrases) {
  var best = 0;
  for (final phrase in phrases) {
    if (phrase.length <= best) continue;
    if (lower.contains(phrase.toLowerCase()) || original.contains(phrase)) best = phrase.length;
  }
  return best;
}

/// What a bare "no" is most often misheard as.
///
/// Only ever consulted for a single-word utterance — see [classifyTraitYesNo].
const _bareNoHomophones = {'know', 'noh', 'nou'};

/// Negative answers that open a sentence and settle it.
const _bareNoOpeners = [
  'not really', 'not at all', 'not particularly', 'not much', 'not usually',
  'never', 'rarely',
  'তেমন না', 'একদম না', 'না তেমন',
];

/// Whitespace-separated words with punctuation stripped. Keeps ASCII word
/// characters and the whole Bangla Unicode block (ঀ-৿) — the same class
/// `spokenTextToDigits` uses — so the Bangla danda in "না।" is removed
/// while the word itself survives.
Set<String> _spokenWords(String text) => text
    .split(RegExp(r'\s+'))
    .map((w) => w.replaceAll(RegExp(r'[^\wঀ-৿]'), ''))
    .where((w) => w.isNotEmpty)
    .toSet();

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
  /// Spoken once if the microphone turns out to be unusable.
  ///
  /// Optional only so existing callers keep compiling; every onboarding
  /// screen should pass `s.voiceUnavailableSpoken`. Silence here is what
  /// made a mute build look like a broken app.
  String? unavailableMessage,
  required bool Function() isCancelled,
}) async {
  if (choices.isEmpty) return;
  final labels = choices.map((c) => c.label).join(' / ');
  debugPrint('[OnboardingVoice] listenForVoiceChoice starting — choices: $labels');
  if (isCancelled()) {
    debugPrint('[OnboardingVoice] already cancelled before first listen — never spoke or listened');
    return;
  }
  // After this many unmatched attempts in a row, the full option list is
  // read out automatically — a user who doesn't know (or forgets) they can
  // ask for "help" shouldn't be stuck in a "sorry, didn't catch that" loop
  // forever with no way forward. Saying "help" explicitly still works
  // immediately at any point; this is just a safety net for whoever
  // doesn't think to.
  const missesBeforeAutoHelp = 2;
  var misses = 0;
  while (!isCancelled()) {
    if (!await stt.ensureAvailable()) {
      debugPrint('[OnboardingVoice] stt.ensureAvailable() returned false — mic unavailable');
      // Say so. The screen is still fully operable by touch, and a user who
      // cannot see it has no other way to learn that listening has stopped.
      // Spoken only on the first attempt: `misses` is 0 only before any
      // listening has happened, so re-entering the loop cannot repeat it.
      if (unavailableMessage != null && misses == 0 && !isCancelled()) {
        try {
          await tts.speak(unavailableMessage, language: language);
        } catch (e) {
          debugPrint('[OnboardingVoice] could not speak the mic-unavailable notice: $e');
        }
      }
      return;
    }
    OnboardingVoiceChoice? matched;
    var wantsHelp = false;
    await stt.listenOnce(
      language: language,
      onResult: (text, isFinal) {
        if (!isFinal || matched != null || wantsHelp) return;
        final trimmed = text.trim();
        debugPrint('[OnboardingVoice] heard (final): "$trimmed"');
        if (trimmed.isEmpty) return;
        if (helpText != null && isHelpRequest(trimmed)) {
          wantsHelp = true;
          return;
        }
        // Best score wins, rather than first past the post. See
        // `OnboardingVoiceChoice.matchScore` for the live failure this fixes.
        var bestScore = 0.0;
        for (final choice in choices) {
          final score = choice.matchScore(trimmed);
          if (score > bestScore) {
            bestScore = score;
            matched = choice;
          }
        }
        if (matched != null) {
          debugPrint('[OnboardingVoice] matched choice: "${matched!.label}" '
              '(score ${bestScore.toStringAsFixed(2)})');
        }
      },
    );
    if (isCancelled()) {
      debugPrint('[OnboardingVoice] cancelled after listenOnce returned — step changed or disposed');
      return;
    }
    final result = matched;
    if (result != null) {
      result.onSelect();
      return;
    }
    if (wantsHelp && helpText != null) {
      debugPrint('[OnboardingVoice] help requested — speaking full option list');
      misses = 0;
      await tts.speak(helpText, language: language);
      continue;
    }
    misses++;
    debugPrint('[OnboardingVoice] no match this attempt (miss #$misses)');
    if (helpText != null && misses >= missesBeforeAutoHelp) {
      misses = 0;
      await tts.speak(helpText, language: language);
    } else {
      await tts.speak(retryHint, language: language);
    }
  }
}
