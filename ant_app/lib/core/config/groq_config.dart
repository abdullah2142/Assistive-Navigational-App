/// Whether a real Groq API key has been configured.
///
/// Replaces the old Gemini/Google-Cloud split (see `GeminiConfig` and
/// `CloudSttConfig`, both superseded by this): one Groq key now drives both
/// the conversational engine (`GroqAssistantService`, chat completions
/// against `chatModel`) and cloud speech-to-text (`CloudSttService`,
/// transcription against `whisperModel`) — Groq's free tier needs no
/// billing account and no credit card, just this key.
///
/// Passed at build/run time, same mechanism the Gemini key used:
/// ```
/// flutter run --dart-define=GROQ_API_KEY=your-key-here
/// # or, to avoid the key ever touching shell history:
/// flutter run --dart-define-from-file=dart_defines.local.json
/// ```
///
/// `dart_defines.local.json` (repo-root-relative: `ant_app/dart_defines.local.json`)
/// is git-ignored — add `"GROQ_API_KEY": "gsk_..."` to it, replacing (or
/// alongside) the old `GEMINI_API_KEY`/`CLOUD_STT_API_KEY` entries. Get a key
/// at https://console.groq.com/keys.
///
/// Text-to-speech (`TtsService`) is unaffected — that still runs on Google
/// Cloud TTS via `CloudTtsConfig`, kept deliberately separate.
class GroqConfig {
  GroqConfig._();

  static const String apiKey = String.fromEnvironment('GROQ_API_KEY');

  static const bool isConfigured = apiKey != '';

  static const String baseUrl = 'https://api.groq.com/openai/v1';

  /// The conversational model — chosen over `openai/gpt-oss-120b` (Groq's
  /// other free-tier chat option) specifically for its much stronger
  /// multi-turn context retention and Bengali-language handling, the two
  /// complaints the prior `gemini-3.6-flash` deployment could not clear.
  /// Same free-tier rate limits either way (30 RPM / 1,000 RPD / 8K TPM), so
  /// this is a pure quality choice, not a cost one. If per-turn latency
  /// becomes a problem in practice, `openai/gpt-oss-120b` is the documented
  /// fallback — noticeably faster, weaker at reasoning/context.
  static const String chatModel = 'qwen/qwen3.8-27b';

  /// Batch transcription model for `CloudSttService` — see its doc comment
  /// for why this is a single-shot upload-then-transcribe call rather than
  /// the old genuinely-continuous Google Cloud stream.
  static const String whisperModel = 'whisper-large-v3';
}
