/// Romanised Bangla — "Banglish" — and the one rule that generalises.
///
/// ## Why this exists
///
/// Item 54: "it cant handle a lot of banglish terms like 'trip cancel koro'".
///
/// Both matchers in this app assume a sentence is either Bangla script or
/// English. Romanised Bangla is neither, and in Dhaka it is how people
/// actually speak to a phone. The first response to that was to add literal
/// Banglish phrases to each vocabulary — `trip cancel koro`, `map on koro`,
/// `caretaker ke janao` — which works for the phrase written down and for
/// nothing else. An audit of nineteen realistic utterances against that
/// approach matched ten.
///
/// ## The rule
///
/// Most of the misses were one thing. Bangla forms a command by attaching a
/// verb meaning roughly "do it" to a content word:
///
/// ```
///   cancel koro       cancel + do-it
///   map on koro       map on + do-it
///   lekha boro koro   writing big + do-it
///   sahajjo koro      help + do-it
/// ```
///
/// The auxiliary carries no intent. It is the Bangla equivalent of "please"
/// — present in almost every spoken command, meaningful in none of them. So
/// removing it lets `X koro` match whatever `X` already matched, for every
/// vocabulary in the app at once, including ones written later that never
/// think about Banglish at all.
///
/// That is the whole of this file. It is a suffix rule, not a transliterator:
/// there is no attempt here to convert Bangla into English or to guess at
/// meaning, because a wrong guess in a matcher that fires real actions is far
/// worse than a miss that falls through to Gemini.
///
/// ## Why it is applied as a second pass
///
/// [LocalIntentMatcher] tries the utterance as spoken first and only retries
/// a stripped form if nothing matched. Stripping can therefore only ever
/// *add* a match, never change or remove one — which matters because these
/// matchers fire emergencies, cancel journeys and change settings.
library;

/// Verbs that turn a content word into a command, as whole words.
///
/// Spelling is unstandardised, so the common romanisations of each are listed
/// rather than guessed at: `koro`/`koru`/`kor`/`korun` are all the same word
/// written by different people.
///
/// `kore` and `kora` are included because `kore dao` ("do it and give") and
/// `kora` are the same auxiliary in another form. They are only ever removed
/// alongside the rest of a command, never in isolation from meaning, because
/// removal cannot create a match on its own — something else in the sentence
/// still has to match.
const List<String> kBanglishImperatives = [
  'koro', 'koru', 'kor', 'korun', 'kore', 'kora', 'korbe', 'korben', 'korte',
  'dao', 'daw', 'deo', 'den', 'dio', 'diyo', 'den',
  'please', 'plz',
];

final RegExp _tokenSplit = RegExp(r'\s+');

/// The utterance with its command auxiliaries removed.
///
/// Whole words only. `kor` is a substring of a great many ordinary words, and
/// this codebase has already been bitten three times by substring matching —
/// "no" inside "know", "male" inside "female", "না" inside নারায়ণগঞ্জ.
///
/// Returns the input unchanged when there was nothing to strip, so a caller
/// can cheaply skip a redundant second pass.
String stripBanglishImperatives(String text) {
  final words = text.split(_tokenSplit);
  final kept = <String>[];
  for (final word in words) {
    final bare = word.toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
    if (bare.isEmpty) continue;
    if (kBanglishImperatives.contains(bare)) continue;
    kept.add(word);
  }
  // Everything was an auxiliary: "koro" on its own is not a command, it is
  // half of one, and handing back an empty string would have every matcher
  // evaluate nothing.
  if (kept.isEmpty) return text;
  return kept.join(' ');
}

/// Whether [text] carries an auxiliary worth stripping.
bool hasBanglishImperative(String text) {
  for (final word in text.split(_tokenSplit)) {
    final bare = word.toLowerCase().replaceAll(RegExp(r'[^\w]'), '');
    if (bare.isNotEmpty && kBanglishImperatives.contains(bare)) return true;
  }
  return false;
}
