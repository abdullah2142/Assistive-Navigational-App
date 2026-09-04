import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../config/cloud_tts_config.dart';
import '../localization/app_language.dart';
import 'cloud_tts_service.dart';
import 'locale_preference.dart';

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
      ..setPitch(1.0)
      // Without this, `speak()`'s Future resolves the instant the request
      // is *dispatched*, not once the audio actually finishes playing —
      // confirmed live as a real bug: code that spoke an announcement and
      // then immediately started listening (the Passerby overlay's
      // TTS-then-listen-for-"go back" flow) started the microphone while
      // the announcement was still audibly playing, so the fixed
      // silence-timeout had often already expired by the time the user
      // could actually respond to what they just heard.
      ..awaitSpeakCompletion(true);
    _preferBestEngine();
  }

  final FlutterTts _tts = FlutterTts();
  final CloudTtsService _cloudTts = CloudTtsService();

  // The gender half of `UserProfile.voiceId` — the rest of that field
  // (`bn-BD-female-1` etc.) is onboarding-era detail this only cares about
  // the "female"/"male" substring of, same as `CloudTtsService`. Threading
  // it through every one of this app's ~15 `speak()` call sites would be a
  // lot of surface area for one setting; instead callers with a live
  // profile in scope (`ChatStreamPanel`, `OnboardingController`) call
  // `setVoiceId` whenever it's known/changes, and every `speak()` after
  // that just uses whatever was last set. Defaults to the same default
  // `UserProfile.voiceId` itself defaults to, so pre-onboarding narration
  // (before a profile even exists) still gets a sensible voice.
  String _voiceId = 'bn-BD-female-1';

  void setVoiceId(String voiceId) => _voiceId = voiceId;

  // Cached per locale so the same voice is used every time, once chosen —
  // confirmed live as a real bug without this: calling `setLanguage(...)`
  // alone (no explicit `setVoice`) left voice selection up to whatever the
  // engine's own, not-fully-deterministic default-voice logic decided each
  // time, which was audibly inconsistent — the assistant's voice switching
  // between male and female between replies with no setting change at all.
  final Map<String, Map<String, String>> _voiceByLocale = {};

  // Best-effort: some Android manufacturers (e.g. MIUI) ship a lower-quality
  // TTS engine as the device default even when Google's engine — noticeably
  // more natural-sounding — is installed alongside it. Silently does nothing
  // where this doesn't apply (iOS, web, or a device without Google's engine).
  Future<void> _preferBestEngine() async {
    try {
      final engines = await _tts.getEngines;
      final defaultEngine = await _tts.getDefaultEngine;
      debugPrint('[Tts] available engines=$engines default=$defaultEngine');
      if (engines is List && engines.contains('com.google.android.tts')) {
        await _tts.setEngine('com.google.android.tts');
        debugPrint('[Tts] switched to com.google.android.tts');
      } else {
        debugPrint('[Tts] Google engine not available on this device — keeping default');
      }
    } catch (e) {
      debugPrint('[Tts] engine preference check failed: $e');
    }
  }

  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (CloudTtsConfig.isConfigured) {
      await _tts.stop();
      final played = await _cloudTts.speak(trimmed, language: language, voiceId: _voiceId);
      if (played) return;
      debugPrint('[Tts] Cloud TTS unavailable — falling back to on-device engine');
    }
    await _tts.stop();
    // Best-effort — a device missing the Bangla voice pack still runs this
    // without throwing, it just falls back to whatever default is installed.
    await _tts.setLanguage(language.ttsLocale);
    await _pinVoiceFor(language.ttsLocale);
    await _tts.speak(trimmed);
  }

  /// Which of the device's installed voices to speak with.
  ///
  /// Was "the alphabetically first voice whose locale starts with the right
  /// language", which on a real device meant `en-AU-language` — so the app
  /// spoke to users in Dhaka in an Australian accent. Exactly the same
  /// first-match-wins bug the speech *recognizer* had; the shared ordering
  /// in `locale_preference.dart` is there so the two cannot drift apart
  /// again.
  ///
  /// Within the winning locale the name sort is kept: `getVoices` is not
  /// documented as returning a stable order, and an app that picks a
  /// different voice each launch sounds broken to someone who only ever
  /// hears it.
  @visibleForTesting
  static Map<String, String>? pickVoice(List<Map<String, String>> voices, String locale) {
    final ids = voices.map((v) => v['locale'] ?? '').where((l) => l.isNotEmpty).toList();
    final wanted = pickPreferredLocale(ids, locale);
    if (wanted == null) return null;

    final matches = voices
        .where((v) => normaliseLocaleId(v['locale'] ?? '') == normaliseLocaleId(wanted))
        .toList()
      ..sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
    return matches.isEmpty ? null : matches.first;
  }

  /// Picks one specific voice for [locale] the first time it's needed and
  /// reuses that exact choice every time after — see the field doc comment
  /// on `_voiceByLocale` for the inconsistent-voice bug this fixes.
  Future<void> _pinVoiceFor(String locale) async {
    final cached = _voiceByLocale[locale];
    if (cached != null) {
      await _tts.setVoice(cached);
      return;
    }
    try {
      final voices = await _tts.getVoices;
      if (voices is! List) return;
      final available = voices
          .whereType<Object?>()
          .map((v) => v is Map ? v.map((k, val) => MapEntry(k.toString(), val.toString())) : null)
          .whereType<Map<String, String>>()
          .toList();
      final chosen = pickVoice(available, locale);
      if (chosen == null) {
        debugPrint('[Tts] no voice found for locale=$locale — leaving engine default');
        return;
      }
      _voiceByLocale[locale] = chosen;
      debugPrint('[Tts] pinned voice for locale=$locale: ${chosen['name']}');
      await _tts.setVoice(chosen);
    } catch (e) {
      debugPrint('[Tts] voice pinning failed for locale=$locale: $e');
    }
  }

  Future<void> stop() async {
    await _tts.stop();
    await _cloudTts.stop();
  }
}
