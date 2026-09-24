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

  /// Reversible GPT-OSS 120B trial for conversational Bangla and tool use.
  /// Set `--dart-define=GROQ_CHAT_MODEL=qwen/qwen3.8-27b` to restore the
  /// previous model for a build. Qwen remains the independently configured
  /// vision model.
  static const String chatModel = String.fromEnvironment(
    'GROQ_CHAT_MODEL',
    defaultValue: 'openai/gpt-oss-120b',
  );

  /// Batch transcription model for `CloudSttService` — see its doc comment
  /// for why this is a single-shot upload-then-transcribe call rather than
  /// the old genuinely-continuous Google Cloud stream.
  static const String whisperModel = 'whisper-large-v3';
}
