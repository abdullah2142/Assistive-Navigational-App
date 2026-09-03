/// Whether a real Google Cloud Text-to-Speech API key has been configured.
///
/// Mirrors `CloudSttConfig`'s pattern exactly: every entry point that wants
/// a genuine neural voice (rather than the on-device `flutter_tts` engine,
/// whose quality varies wildly by manufacturer — the whole reason this
/// exists) checks this flag first and falls back to on-device speech
/// otherwise — same "graceful degradation" philosophy as the rest of this
/// app.
///
/// Defaults to reusing `CLOUD_STT_API_KEY` if no dedicated
/// `CLOUD_TTS_API_KEY` is given, since both are the same Google Cloud
/// project's API key in the common case — **but that existing key was
/// deliberately restricted to only the Speech-to-Text API when it was set
/// up** (see `CloudSttConfig`'s doc comment), so reusing it here needs one
/// more manual step before this actually works:
/// 1. Console → APIs & Services → Library → enable "Cloud Text-to-Speech
///    API" for the `ant-assistive-nav` project (same project, separate API
///    from Speech-to-Text — needs its own enablement).
/// 2. Console → APIs & Services → Credentials → open the existing key →
///    API restrictions → add "Cloud Text-to-Speech API" to the allowed list
///    (or create a second key restricted to just this API, and set that as
///    `CLOUD_TTS_API_KEY` in `dart_defines.local.json` instead).
///
/// Until that's done, `isConfigured` is true but every call fails closed —
/// `CloudTtsService.speak` returns `false` on any non-200 response, and
/// `TtsService` falls back to on-device speech exactly as if this were
/// never configured at all, so there's no broken-silence failure mode.
class CloudTtsConfig {
  CloudTtsConfig._();

  static const String _dedicatedKey = String.fromEnvironment('CLOUD_TTS_API_KEY');
  static const String _sttKey = String.fromEnvironment('CLOUD_STT_API_KEY');
  static const String apiKey = _dedicatedKey != '' ? _dedicatedKey : _sttKey;

  static const bool isConfigured = apiKey != '';
}
