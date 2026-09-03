/// Whether a real Google Cloud Speech-to-Text API key has been configured.
///
/// Mirrors `GeminiConfig`'s pattern exactly: every entry point that wants
/// genuinely continuous, cloud-quality speech recognition checks this flag
/// first and falls back to on-device `SttService` when it's false — same
/// "graceful degradation" philosophy as the rest of this app. The
/// *existing* on-device push-to-talk flow (the chat mic, hazard report,
/// My Settings, the passerby message composer) is untouched by this and
/// keeps working exactly as before regardless of whether this is
/// configured — this is purely additive, wired in first for
/// `PasserbyHelperOverlay`'s "say 'go back' any time" listener, which is
/// what genuinely needs a non-restarting stream (see its doc comment for
/// why the on-device recognizer couldn't do that).
///
/// Passed at build/run time, same mechanism as the Gemini key:
/// ```
/// flutter run --dart-define=CLOUD_STT_API_KEY=your-key-here
/// # or, via dart_defines.local.json (git-ignored):
/// flutter run --dart-define-from-file=dart_defines.local.json
/// ```
///
/// **Setup** (one-time, in the Google Cloud Console for the
/// `ant-assistive-nav` project — this is a *different* product from the
/// Gemini/AI-Studio key already configured, so it needs its own key even
/// though both are Google APIs):
/// 1. Console → APIs & Services → Library → enable "Cloud Speech-to-Text
///    API" for the `ant-assistive-nav` project (requires Blaze/billing,
///    already enabled as of Module 3 Round 3).
/// 2. Console → APIs & Services → Credentials → Create Credentials → API
///    key. Restrict it to the Speech-to-Text API (API restrictions tab)
///    rather than leaving it unrestricted.
/// 3. Add `"CLOUD_STT_API_KEY": "the-key"` to `ant_app/dart_defines.local.json`
///    alongside the existing `GEMINI_API_KEY` entry.
class CloudSttConfig {
  CloudSttConfig._();

  static const String apiKey = String.fromEnvironment('CLOUD_STT_API_KEY');

  static const bool isConfigured = apiKey != '';
}
