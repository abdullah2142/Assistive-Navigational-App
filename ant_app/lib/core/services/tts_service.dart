import 'package:flutter_tts/flutter_tts.dart';

import '../localization/app_language.dart';

/// Thin wrapper around the device's built-in text-to-speech engine.
///
/// This is deliberately not the Module 3 stack (Google Cloud TTS, Bangla
/// voices, Gemini-driven dialogue) — `flutter_tts` speaks with whatever
/// voice/locale the device already has installed, entirely on-device and
/// available immediately. Its only job is to make onboarding itself
/// navigable by ear from the very first screen, for a Visually Impaired
/// user setting the app up alone with no caretaker to read the screen for
/// them and no guarantee their OS screen reader is already configured.
/// Module 3 can layer richer Bangla narration on top of this later; nothing
/// here needs to change for that.
class TtsService {
  TtsService() {
    _tts
      ..setSpeechRate(0.45)
      ..setPitch(1.0);
  }

  final FlutterTts _tts = FlutterTts();

  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await _tts.stop();
    // Best-effort — a device missing the Bangla voice pack still runs this
    // without throwing, it just falls back to whatever default is installed.
    await _tts.setLanguage(language.ttsLocale);
    await _tts.speak(trimmed);
  }

  Future<void> stop() => _tts.stop();
}
