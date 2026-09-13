/// Strips everything from a log line that a tester cannot consent to sharing
/// on someone else's behalf.
///
/// This is applied at the moment a line is recorded, not at the moment it is
/// sent. A buffer that holds the raw text and cleans it on export is one bug
/// away from shipping the lot, and the raw text here is a blind user's speech,
/// their disability answers, their family's phone numbers and their location.
///
/// What debugging actually needs from those lines is their *shape*: did a
/// final result arrive, how long was it, did it match. Almost never the words.
/// Every redaction below keeps the shape and drops the content.
library;

/// A quoted transcript — `heard "..."`, `matched choice: "..."`.
///
/// The quoted part is replaced with a word and character count. That is enough
/// to tell "the recognizer returned nothing" from "it returned a sentence and
/// the matcher refused it", which is the question these lines exist to answer.
final _quoted = RegExp(r'"([^"]*)"');

/// Runs of digits long enough to be a phone number, a pairing code or a uid
/// fragment. Four is the shortest thing worth hiding — a 6-digit pairing code
/// is live for fifteen minutes and redeemable by anyone who sees it.
final _digitRun = RegExp(r'\d{4,}');

/// Coordinates, in any of the shapes these logs produce.
final _coordinate = RegExp(r'-?\d{1,3}\.\d{4,}');

/// Firebase uids: 20+ of [A-Za-z0-9] with both cases or a digit present.
final _uid = RegExp(r'\b(?=[A-Za-z0-9]*[0-9])(?=[A-Za-z0-9]*[a-z])[A-Za-z0-9]{20,}\b');

String _describeQuoted(String inner) {
  final trimmed = inner.trim();
  if (trimmed.isEmpty) return '"<empty>"';
  final words = trimmed.split(RegExp(r'\s+')).length;
  return '"<$words ${words == 1 ? 'word' : 'words'}, ${trimmed.length} chars>"';
}

/// A stable short tag for a uid, so two lines about the same user can still be
/// tied together without the uid itself leaving the device.
String _tagFor(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return '<id:${hash.toRadixString(36).padLeft(4, '0').substring(0, 4)}>';
}

/// Redacts one line. Order matters: coordinates before the bare digit run,
/// or `23.7461` loses its decimals to the digit rule and stops being
/// recognisable as a coordinate at all.
String redactLogLine(String line) {
  var out = line.replaceAllMapped(_quoted, (m) => _describeQuoted(m.group(1)!));
  out = out.replaceAll(_coordinate, '<coord>');
  out = out.replaceAllMapped(_uid, (m) => _tagFor(m.group(0)!));
  out = out.replaceAllMapped(_digitRun, (m) => '<digits:${m.group(0)!.length}>');
  return out;
}
