/// Whether the session log keeps what was actually said, or only its shape.
///
/// ## Why this is a switch and not a decision
///
/// `log_redaction.dart` replaces every transcript, name, number, coordinate
/// and account id with a description of its shape before it is ever stored.
/// That is the right default and it stays the default: the log is written to
/// be *sent*, through a share sheet, by a tester who cannot read it — and the
/// content is a blind user's speech, their disability answers, their family's
/// phone numbers and their location.
///
/// But redaction also costs the one thing several open questions need. Item
/// 54 is the clearest case: whether romanised Bangla comes back from the
/// recognizer as Latin letters or as Bangla script decides how the matcher
/// has to be written, and `heard "<4 words, 17 chars>"` cannot answer it. The
/// same blindness hid the wake-word threshold until the redaction rule was
/// narrowed for it.
///
/// So this exists for a build going to a known, consenting circle:
///
/// ```
/// flutter build apk --dart-define=LOG_RAW_TRANSCRIPTS=true
/// ```
///
/// `release_google_build.sh` passes it, because that script only ever
/// distributes to the tester group. A build made without it redacts exactly
/// as before — a tree-shaken compile-time default, not a runtime setting
/// somebody could flip by accident.
///
/// ## What changes when it is on
///
/// Everything. Transcripts verbatim, phone numbers, pairing codes,
/// coordinates and uids. The report header says so in plain words, and so
/// does the settings tile the tester presses to send it — a log that quietly
/// contained more than the app promised would be worse than one that never
/// redacted at all.
class DiagnosticsConfig {
  const DiagnosticsConfig._();

  static const bool logRawTranscripts =
      bool.fromEnvironment('LOG_RAW_TRANSCRIPTS', defaultValue: false);
}
