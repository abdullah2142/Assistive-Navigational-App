/// Turns a dictated number reading into plain digits — handles both bare
/// digit words ("zero"/"oh" through "nine", and their Bangla equivalents)
/// and the "double"/"triple" convention common in South Asian spoken
/// English for reading out phone numbers and codes ("double three" = "33",
/// "triple oh" = "000"). Confirmed live as a real gap without this: STT
/// transcribed the literal words "double"/"triple" into the field instead
/// of expanding them, since neither the phone-number nor the pairing-code
/// dictation understood the convention at all — they only ever looked for
/// digit *characters* already in the transcript.
///
/// Any digit characters already present in a token (some recognizers do
/// convert digit words to numerals themselves) are honored too, each one
/// still subject to whatever "double"/"triple" multiplier preceded it —
/// this only ever adds a capability, never requires the words to spell
/// everything out. That includes **Bengali numerals** (০-৯), which is what
/// Cloud STT actually returns under a `bn-BD` language code when a Bangla
/// speaker reads a number aloud — see [_asAsciiDigit].
/// First Bengali numeral, ০ (U+09E6); the block runs ০-৯ contiguously.
const int _bengaliZeroCodeUnit = 0x09E6;

/// Normalizes a single character to an ASCII digit, or returns null if it
/// isn't a digit at all.
///
/// Dart's `\d` is ASCII-only, so a transcript of Bengali numerals used to
/// match nothing: the characters survived token cleanup (they're inside the
/// Bangla Unicode block the cleanup regex deliberately keeps), found no
/// entry in the digit-*word* map either, and were dropped on the floor by
/// the "unrecognized word" fallthrough. A Bangla-speaking user dictating
/// their phone number got a silently empty field — the worst possible
/// failure mode for a user who can't see that nothing was entered.
String? _asAsciiDigit(String ch) {
  final code = ch.codeUnitAt(0);
  if (code >= 0x30 && code <= 0x39) return ch;
  if (code >= _bengaliZeroCodeUnit && code <= _bengaliZeroCodeUnit + 9) {
    return String.fromCharCode(0x30 + code - _bengaliZeroCodeUnit);
  }
  return null;
}

String spokenTextToDigits(String text) {
  const digitWords = {
    'zero': '0', 'oh': '0', 'o': '0', 'nil': '0',
    'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5',
    'six': '6', 'seven': '7', 'eight': '8', 'nine': '9',
    'শূন্য': '0', 'এক': '1', 'দুই': '2', 'তিন': '3', 'চার': '4',
    'পাঁচ': '5', 'ছয়': '6', 'সাত': '7', 'আট': '8', 'নয়': '9',
  };
  const doubleWords = {'double', 'ডাবল'};
  const tripleWords = {'triple', 'ট্রিপল'};

  final tokens = text.toLowerCase().trim().split(RegExp(r'\s+'));
  final buffer = StringBuffer();
  var repeat = 1;
  for (final rawToken in tokens) {
    // Strips punctuation but keeps digits and Bangla letters (ঀ-৿)
    // — a bare `\w` alone doesn't cover the Bangla Unicode block.
    final token = rawToken.replaceAll(RegExp(r'[^\wঀ-৿]'), '');
    if (token.isEmpty) continue;
    if (doubleWords.contains(token)) {
      repeat = 2;
      continue;
    }
    if (tripleWords.contains(token)) {
      repeat = 3;
      continue;
    }
    final digitsInToken = token.split('').map(_asAsciiDigit).whereType<String>().join();
    if (digitsInToken.isNotEmpty) {
      // A preceding "double"/"triple" multiplies only the single digit
      // right after it, not every digit that happens to follow — confirmed
      // live as a real bug without this split: when a recognizer merges a
      // run like "3, 1, 0" into one token ("310") instead of three separate
      // ones, applying `repeat` to the whole loop below multiplied *every*
      // digit in it ("triple 3 1 0" -> "333111000" instead of "33310").
      for (var i = 0; i < digitsInToken.length; i++) {
        buffer.write(digitsInToken[i] * (i == 0 ? repeat : 1));
      }
      repeat = 1;
      continue;
    }
    final mapped = digitWords[token];
    if (mapped != null) {
      buffer.write(mapped * repeat);
      repeat = 1;
    }
    // Anything else (an unrecognized word) is silently skipped — filler
    // like "um" or a mis-transcribed word shouldn't corrupt the number.
  }
  return buffer.toString();
}
