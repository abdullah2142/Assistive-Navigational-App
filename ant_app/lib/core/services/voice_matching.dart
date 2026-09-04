/// Flexible, word-level matching for spoken commands.
///
/// ## Why this exists
///
/// Every voice matcher in this app started life as a list of exact phrases
/// checked with `String.contains`. That only ever recognizes the sentence
/// the author happened to imagine. "switch to dark mode" worked; "make the
/// screen darker", "can you darken this", "I'd like the theme dark please"
/// and "dark, please" all silently fell through to a Gemini round trip — or,
/// in the closed-choice screens, to "sorry, I didn't catch that" on a
/// perfectly clear answer. For a user whose only interface is their voice,
/// being told to phrase it the app's way is the failure mode.
///
/// So matching here is on **word presence, not word order or adjacency**. A
/// spec names the distinctive words that carry the meaning; the utterance
/// matches if those words are in it *somewhere*, however the speaker chose
/// to arrange them and whatever they put in between.
///
/// ## Why that isn't just "match more loosely"
///
/// Loosening a matcher that fires real actions is dangerous in a specific
/// way: free chat has far more room for an innocent sentence to collide
/// with a keyword than a closed option list does. "it's getting dark
/// outside" must never flip the theme. So a spec has three parts:
///
/// - [VoicePhrase.anchors] — the content words that carry the meaning. At
///   least one must appear.
/// - [VoicePhrase.context] — words that make an ambiguous anchor
///   unambiguous ("dark" + "mode"/"screen"/"theme"). Required whenever the
///   anchor alone could plausibly appear in ordinary conversation.
/// - [VoicePhrase.blockers] — words that veto the match outright
///   (negations, and question framings like "is there a pothole?", which
///   must never file a hazard report).
///
/// The result is looser about *phrasing* and stricter about *evidence* than
/// the substring checks it replaces.
library;

/// Splits an utterance into comparable words.
///
/// Keeps ASCII word characters and the whole Bangla Unicode block (ঀ-৿),
/// dropping punctuation including the Bangla danda (।) — the same class
/// `spokenTextToDigits` uses. Lowercased for English; Bengali script has no
/// case, so it passes through unchanged.
List<String> voiceWords(String text) => text
    .toLowerCase()
    .split(RegExp(r'\s+'))
    .map((w) => w.replaceAll(RegExp(r'[^\wঀ-৿]'), ''))
    .where((w) => w.isNotEmpty)
    .toList();

/// Whether [words] contains [term] as a whole word — or, for a multi-word
/// term ("curb cut", "hey ant"), as a contiguous run of whole words.
///
/// Never a substring test. "no" lives inside "know", "male" inside
/// "female", and "না" inside নারায়ণগঞ্জ — every one of which has been a
/// real, live bug in this codebase.
bool containsTerm(List<String> words, String term) {
  final termWords = voiceWords(term);
  if (termWords.isEmpty) return false;
  if (termWords.length == 1) return words.contains(termWords.first);
  for (var i = 0; i + termWords.length <= words.length; i++) {
    var all = true;
    for (var j = 0; j < termWords.length; j++) {
      if (words[i + j] != termWords[j]) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

bool containsAny(List<String> words, List<String> terms) =>
    terms.any((t) => containsTerm(words, t));

/// Like [containsTerm], but tolerant of a grammatical ending on the spoken
/// word.
///
/// Bangla marks case by attaching a postposition directly to the noun:
/// অফিস ("office") becomes অফিসে ("to the office"), গুলশান becomes গুলশানে,
/// বাসা becomes বাসায়. A user asking to be taken to a saved place will
/// almost always say the inflected form, while the place is *saved* under
/// the bare one — so strict word equality failed on the single most common
/// way a Bangla speaker names a destination.
///
/// Only a *trailing* extension counts, and only on a stem long enough that
/// the match still means something ([_minStemLength]). That keeps this from
/// degenerating back into the substring matching this file exists to
/// replace: "না" can never prefix-match নারায়ণগঞ্জ, because a two-character
/// stem is not allowed to.
bool containsTermInflected(List<String> words, String term) {
  if (containsTerm(words, term)) return true;
  final termWords = voiceWords(term);
  if (termWords.length != 1) return false;
  final stem = termWords.first;
  if (stem.length < _minStemLength) return false;
  return words.any((w) => w.length > stem.length && w.startsWith(stem) && w.length - stem.length <= 3);
}

/// Short words carry too little evidence to allow a suffix match — see
/// [containsTermInflected].
const int _minStemLength = 3;

bool containsAnyInflected(List<String> words, List<String> terms) =>
    terms.any((t) => containsTermInflected(words, t));

/// One recognizable meaning, described by the words that carry it rather
/// than by a sentence.
class VoicePhrase {
  const VoicePhrase({
    required this.anchors,
    this.context = const [],
    this.requireContext = false,
    this.blockers = const [],
  });

  /// The distinctive words. At least one must be present. Terms may be
  /// multi-word ("auto listen") and are matched as whole words either way.
  final List<String> anchors;

  /// Words that disambiguate an anchor which could otherwise show up in
  /// ordinary conversation.
  final List<String> context;

  /// When true, a bare anchor is not enough — one [context] word must also
  /// be present. Set this for any anchor that is an everyday English or
  /// Bangla word ("dark", "light", "short", "fixed"). Leave it false for
  /// anchors that are already unmistakable ("manhole", "wheelchair").
  final bool requireContext;

  /// Any of these present anywhere vetoes the match. Use for negation and
  /// for question framings that turn a statement into an enquiry.
  final List<String> blockers;

  bool matches(List<String> words) {
    if (blockers.isNotEmpty && containsAny(words, blockers)) return false;
    if (!containsAny(words, anchors)) return false;
    if (requireContext && !containsAny(words, context)) return false;
    return true;
  }
}

/// Words that turn a statement into a question, in both languages.
///
/// Shared because the same handful ruin the same way everywhere: "is there
/// a pothole ahead?" must not file a pothole report, "what is dark mode?"
/// must not switch the theme, and "should I go to Gulshan?" is not yet a
/// routing request. Deliberately not exhaustive — only framings that
/// genuinely invert intent, not every word a question might contain.
const kQuestionBlockers = <String>[
  'is there',
  'are there',
  'was there',
  // "is it bigger now" is someone checking, not asking for another change.
  'is it',
  'was it',
  'are you',
  'what is',
  "what's",
  'what does',
  'how do',
  'how does',
  'should i',
  'can i',
  'do i',
  'did i',
  'why is',
  'কি আছে',
  'আছে কি',
  'কী',
  'কেন',
  'কীভাবে',
];

/// Bangla negation particles, as whole words.
///
/// Bangla negates *after* the verb ("যাব না"), which is why these have to be
/// checked as words rather than as substrings: "না" is also the opening of
/// নারায়ণগঞ্জ (Narayanganj), নাখালপাড়া and নারিন্দা — all real Dhaka
/// destinations whose route requests a substring check silently swallowed.
const kBanglaNegations = <String>['না', 'নাই', 'নেই', 'নয়', 'নি'];

const kEnglishNegations = <String>[
  "don't",
  'dont',
  'do not',
  "doesn't",
  "doesnt",
  'not',
  'never',
  "can't",
  'cant',
  'cannot',
  'can not',
  "won't",
  'wont',
  'no longer',
];

/// Every negation term, for phrases where any negation should veto.
const kAllNegations = <String>[...kEnglishNegations, ...kBanglaNegations];

/// Picks between two mutually exclusive readings of one utterance.
///
/// Returns null when both or neither match. Both is the important case:
/// "switch from dark mode to light mode" names each of them, and there is
/// no word-presence rule that can tell which one the speaker wanted. The
/// honest answer is to decline and let a language model read the sentence,
/// which is what every caller does with a null. Guessing here silently set
/// the theme the user was switching *away from*.
T? exclusive<T>(List<String> words, VoicePhrase first, T firstValue, VoicePhrase second, T secondValue) {
  final a = first.matches(words);
  final b = second.matches(words);
  if (a == b) return null;
  return a ? firstValue : secondValue;
}
