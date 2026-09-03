/// Whether a real Gemini API key has been configured.
///
/// Mirrors `MapsConfig`'s pattern: every entry point into the AI Assistant
/// checks this flag first and falls back to Module 2's canned replies
/// instead of attempting a network call when it's false — consistent with
/// the app's "graceful degradation" philosophy (see `project_master_plan.md`).
///
/// Unlike the Maps key, this one is NOT hardcoded into source. A Gemini key
/// is a billable credential tied to a personal Google AI Studio account
/// (unlike the Maps key it doesn't sit behind a platform/bundle-ID
/// restriction), so it's passed at build/run time instead:
///
/// ```
/// flutter run --dart-define=GEMINI_API_KEY=your-key-here
/// # or, to avoid the key ever touching shell history:
/// flutter run --dart-define-from-file=dart_defines.local.json
/// ```
///
/// `dart_defines.local.json` (repo-root-relative: `ant_app/dart_defines.local.json`)
/// is git-ignored — `{"GEMINI_API_KEY": "..."}` — never commit a real key in it.
///
/// Speech-to-text (`SttService`) and text-to-speech (`TtsService`) both run
/// entirely on-device and need no key — only the Gemini conversational
/// engine is gated by this flag.
class GeminiConfig {
  GeminiConfig._();

  static const String apiKey = String.fromEnvironment('GEMINI_API_KEY');

  static const bool isConfigured = apiKey != '';

  /// Fast, low-latency tier — the right tradeoff for a conversational
  /// assistant that needs to feel responsive and keep API cost down (see
  /// "API Strategy & Cost Mitigation" in `project_master_plan.md`), not the
  /// heavier "Pro" tier the original module doc names. Change this single
  /// constant if a future key should use a different model.
  ///
  /// Deliberately pinned to a specific dated version rather than the
  /// `gemini-flash-latest` alias: live-tested both against the real API on
  /// 2026-09-01 and the alias was returning 503 "high demand" on every
  /// request (plausibly because every app defaulting to `-latest` hammers
  /// the same routing target) while this pinned version responded
  /// normally, function calling included. Trade-off: this will need
  /// bumping by hand again once Google deprecates it (their error messages
  /// name the replacement when that happens) — worth it for not being at
  /// the mercy of whatever the generic alias currently points to.
  ///
  /// Switched from `gemini-3.6-flash` to the "flash-lite" tier on
  /// 2026-09-03: after a full day of heavy live testing on the same key,
  /// `gemini-3.6-flash` started rejecting every call with "You exceeded
  /// your current quota" — a real, confirmed rate-limit exhaustion, not an
  /// app bug (the message that failed, "স্ক্রীন দেখাও", was being
  /// transcribed and sent correctly the whole time). Verified this lite
  /// tier directly against the live API before switching — it's not
  /// quota-exhausted (separate bucket from the flash tier) and correctly
  /// calls `open_passerby_helper` for that exact failing phrase. Lighter
  /// models generally carry more generous free-tier request quotas, so
  /// this should also be more resilient against hitting this again under
  /// the same kind of sustained testing.
  static const String modelName = 'gemini-3.5-flash-lite';
}
