/// Turns model output into something a speech engine should say out loud.
///
/// Every reply in this app is written by a language model and then read to a
/// user who, very often, cannot see the screen it is also printed on. Models
/// write for a screen: they bullet things, they bold the important clause,
/// they put the route name in backticks. A TTS engine does not render any of
/// that — it **pronounces** it. Reported from the 22 September session as
/// the assistant "dictating symbols": a reply that reads
///
/// ```text
/// **Labaid Hospital** is 400m away:
/// - turn left
/// - cross at the signal
/// ```
///
/// is spoken as "asterisk asterisk Labaid Hospital asterisk asterisk is 400
/// metres away colon dash turn left dash cross at the signal". The
/// information is still in there and the user has to listen past the noise
/// to find it, every single time.
///
/// ## What it deliberately keeps
///
/// Sentence punctuation — `.` `,` `?` `!` and the Bangla danda `।` — is not
/// decoration. It is what gives the engine its phrasing and its pauses, and
/// it is what `ChatController`'s chunked-streaming narration splits on to
/// decide when a sentence is complete enough to start speaking. Stripping it
/// would flatten the delivery and break the chunker in the same move.
///
/// Digits, `%`, and currency stay too: "400m" and "20%" are the answer, not
/// formatting around it.
library;

/// Markdown link — `[Labaid](https://…)` — keeping only the visible text.
/// Run before the emphasis rules, so the brackets are gone before anything
/// tries to read what is inside them.
final _link = RegExp(r'\[([^\]]+)\]\((?:[^)]*)\)');

/// Fenced and inline code. The fence markers are noise; what is inside them
/// is usually a place name or a number the user still wants.
final _fence = RegExp(r'```[a-zA-Z]*\n?');

/// Paired markdown emphasis, unwrapped to the text inside it.
///
/// Matched as *pairs* rather than as a character class, longest delimiter
/// first, so `***both***` is not left with a stranded `*` — one asterisk
/// spoken where there were two is the version of this bug that is worse
/// than no fix at all. `[^…\n]` keeps each match inside one line, so an
/// unclosed marker cannot swallow the rest of the reply.
final _emphasisPairs = <RegExp>[
  RegExp(r'\*\*\*([^*\n]+)\*\*\*'),
  RegExp(r'\*\*([^*\n]+)\*\*'),
  RegExp(r'\*([^*\n]+)\*'),
  RegExp(r'___([^_\n]+)___'),
  RegExp(r'__([^_\n]+)__'),
  RegExp(r'_([^_\n]+)_'),
  RegExp(r'~~([^~\n]+)~~'),
  RegExp(r'`([^`\n]+)`'),
];

/// Whatever emphasis punctuation survived the pairs above — an unclosed
/// `**`, a lone backtick. Spoken, every one of these is a word.
final _emphasisResidue = RegExp(r'[*`~_]+');

/// A list bullet or heading marker at the start of a line.
///
/// Replaced with nothing and the line break turned into a full stop by
/// [_bulletToSentence], because a bulleted list read as one breathless
/// run-on is its own failure — the pause is the only thing that tells a
/// listener where one item ends and the next begins.
final _leadingMarker = RegExp(r'^[ \t]*(?:[-*+•]|#{1,6}|\d+[.)])[ \t]+', multiLine: true);

/// A horizontal rule, or any other run of three-plus structural characters.
final _rule = RegExp(r'^[ \t]*(?:[-*_=]{3,})[ \t]*$', multiLine: true);

/// Table pipes and block-quote markers.
final _blockMarkers = RegExp(r'^[ \t]*>[ \t]?|\|', multiLine: true);

/// Emoji and other pictographs.
///
/// A screen reader announces these by their CLDR name — "grinning face",
/// "warning sign" — in the middle of a sentence about a kerb. Dropped
/// entirely rather than translated: the sentence never depended on them.
final _pictographs = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2190}-\u{21FF}\u{2B00}-\u{2BFF}]',
  unicode: true,
);

/// Collapses the whitespace a stripped marker leaves behind.
final _spaceRun = RegExp(r'[ \t]+');

/// A line break that now needs to become a spoken pause.
final _lineBreaks = RegExp(r'\n{1,}');

/// Punctuation left stranded at the start of a line once its marker is gone.
final _strandedLead = RegExp(r'^[ \t]*[:;,.]+[ \t]*', multiLine: true);

/// Repeated sentence punctuation — `!!!`, `...` — flattened to one.
/// Engines read a run of them as a run.
final _repeatedPunct = RegExp(r'([.!?।,:])\1{1,}');

/// Strips screen-only formatting from [raw], leaving what should be spoken.
///
/// Safe on text that has no formatting at all, which is most of it — that
/// path costs a handful of regex misses and returns an equal string.
String forSpeech(String raw) {
  if (raw.isEmpty) return raw;

  var out = raw
      .replaceAll(_fence, '')
      .replaceAllMapped(_link, (m) => m.group(1) ?? '')
      .replaceAll(_rule, '')
      .replaceAll(_blockMarkers, '')
      .replaceAll(_pictographs, '');

  // Bullets become sentences before the emphasis pass, so a line that was
  // `- **left**` has its bullet handled while the line start is still
  // recognisable.
  out = out.replaceAllMapped(_leadingMarker, (_) => '');

  for (final pair in _emphasisPairs) {
    out = out.replaceAllMapped(pair, (m) => m.group(1) ?? '');
  }

  out = out
      .replaceAll(_emphasisResidue, '')
      .replaceAll(_strandedLead, '')
      // Each line was a list item or a paragraph; either way the listener
      // needs a boundary there, and a bare space gives them none.
      .replaceAllMapped(_lineBreaks, (_) => '. ')
      .replaceAll(_spaceRun, ' ')
      .replaceAllMapped(_repeatedPunct, (m) => m.group(1) ?? '');

  // The line-to-sentence rule above is unconditional, so it can land a full
  // stop on a line that already ended in punctuation — "400m away:" leading
  // into its own list becomes "400m away:." Whatever was already there wins:
  // it is what the writer chose, and a colon before a list is exactly the
  // pause the listener wants.
  // `replaceAllMapped`, not `replaceAll`: Dart's `replaceAll` takes its
  // replacement as a **literal**, so a `$1` in it is spoken as "dollar one"
  // rather than expanded — which is precisely the class of bug this whole
  // file exists to stop.
  out = out.replaceAllMapped(
      RegExp(r'([.!?।:;,])[ \t]*\.(?=\s|$)'), (m) => m.group(1) ?? '');
  // A leading orphan from a line that was nothing but a marker.
  out = out.replaceAll(RegExp(r'^[ \t.]+'), '');
  // A space before sentence punctuation, left by a stripped marker.
  out = out.replaceAllMapped(RegExp(r'[ \t]+([.!?।])'), (m) => m.group(1) ?? '');
  // Trailing whitespace, and the orphan full stop the final newline of a
  // model reply turns into — but never a full stop the writer put there
  // themselves, which is the end of the last sentence.
  out = out.replaceAll(RegExp(r'\s+$'), '');
  out = out.replaceAllMapped(RegExp(r'([.!?।])\.$'), (m) => m.group(1) ?? '');

  return out.trim();
}
