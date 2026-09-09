import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/cloud_tts_config.dart';
import '../localization/app_language.dart';

/// Real neural voices via Google Cloud's `text:synthesize` REST endpoint —
/// the backlog item this replaces `flutter_tts`'s on-device engine for
/// (that engine's quality is entirely at the mercy of whatever the phone
/// manufacturer shipped, audibly worse on some devices than others — see
/// `TtsService`'s engine-preference workaround, which this makes
/// unnecessary whenever Cloud TTS is configured and reachable).
///
/// Stateless per call — synthesizes the whole utterance in one request
/// (no streaming synthesis API exists for this endpoint) and plays the
/// returned MP3 via `audioplayers`, the same package already used
/// elsewhere in this app. Returns `false` on any failure (no key
/// configured, network error, non-200 response) so `TtsService` can fall
/// back to on-device speech transparently — never leaves the user in
/// silence because of a network hiccup.
class CloudTtsService {
  final AudioPlayer _player = AudioPlayer();

  /// Short spoken replies must not permanently seize audio focus.
  ///
  /// audioplayers defaults to `AndroidAudioFocus.gain` — a *permanent* grab.
  /// Every sentence this assistant says therefore told Android to
  /// permanently stop whatever else was playing, which for a user listening
  /// to music means it never comes back. It was also the mechanism behind
  /// the wake word dying (see `WakeWordService`'s recorder config): a
  /// permanent gain sends every other client AUDIOFOCUS_LOSS rather than a
  /// transient one.
  ///
  /// Transient-may-duck is what a navigation prompt is supposed to request:
  /// lower the music for a moment, say the thing, give it back.
  static final _speechContext = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.speech,
      usageType: AndroidUsageType.assistanceNavigationGuidance,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
  );

  bool _contextApplied = false;

  Future<void> _ensureContext() async {
    if (_contextApplied) return;
    _contextApplied = true;
    try {
      await _player.setAudioContext(_speechContext);
    } catch (e) {
      // Never let an audio-session detail cost the user the sentence itself.
      debugPrint('[CloudTts] could not set the audio context: $e');
    }
  }

  /// `bn-IN`, not `bn-BD` — Google Cloud TTS has no Bangladesh-dialect
  /// Bangla voice, only India's. Same language, a different regional
  /// accent; still far more natural than the on-device fallback in
  /// practice, and the only Bangla option Google actually offers here.
  static const String _bnLanguageCode = 'bn-IN';
  static const String _enLanguageCode = 'en-US';

  /// Picks a specific Wavenet/Neural2 voice name for [language], honoring
  /// [voiceId]'s gender (`UserProfile.voiceId`, e.g. `'bn-BD-female-1'`) —
  /// the one piece of that field this app actually acts on; before this,
  /// it was collected during onboarding and then never read anywhere.
  static String _voiceNameFor(AppLanguage language, String voiceId) {
    final female = voiceId.contains('female');
    if (language == AppLanguage.bangla) {
      return female ? 'bn-IN-Wavenet-A' : 'bn-IN-Wavenet-B';
    }
    return female ? 'en-US-Neural2-F' : 'en-US-Neural2-D';
  }

  static String _languageCodeFor(AppLanguage language) =>
      language == AppLanguage.bangla ? _bnLanguageCode : _enLanguageCode;

  /// Synthesizes and plays [text], awaiting actual playback completion
  /// (not just request completion) — callers that speak-then-listen right
  /// after (nearly every voice flow in this app) need that ordering
  /// guarantee, same reason `TtsService`'s on-device path sets
  /// `awaitSpeakCompletion(true)`. Returns `false` (having played nothing)
  /// on any failure.
  /// Bumped by [stop], so an utterance still being *fetched* when the screen
  /// that asked for it goes away is abandoned rather than played over
  /// whatever replaced it.
  ///
  /// `TtsService` has its own generation guard and it is not enough on its
  /// own: it checks before handing an utterance here, and `stop()` there
  /// calls `stop()` here — which stops a *player*. Between the request going
  /// out and the audio coming back there is no player to stop, so a `stop()`
  /// landing inside that window did nothing at all, and the response arrived
  /// afterwards and played. Reported from the device as onboarding narration
  /// "overlapping into the caretaker code section": the role-selection
  /// screen's speech was still in flight over HTTP when the user answered
  /// and the flow moved on.
  int _generation = 0;

  Future<bool> speak(String text, {required AppLanguage language, required String voiceId}) async {
    if (!CloudTtsConfig.isConfigured) return false;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    final myGeneration = _generation;
    try {
      final uri = Uri.parse('https://texttospeech.googleapis.com/v1/text:synthesize?key=${CloudTtsConfig.apiKey}');
      final response = await http.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'input': {'text': trimmed},
          'voice': {'languageCode': _languageCodeFor(language), 'name': _voiceNameFor(language, voiceId)},
          'audioConfig': {'audioEncoding': 'MP3'},
        }),
      );
      if (response.statusCode != 200) {
        debugPrint('[CloudTts] synth failed: ${response.statusCode} ${response.body}');
        return false;
      }
      final audioContent = (jsonDecode(response.body) as Map<String, dynamic>)['audioContent'] as String?;
      if (audioContent == null) {
        debugPrint('[CloudTts] response had no audioContent');
        return false;
      }
      final bytes = base64Decode(audioContent);
      // Checked here, after the round trip, because this is the only moment
      // that can tell a cancelled utterance from a live one — see
      // [_generation]. Reported as true rather than false: nothing failed,
      // and a false would send `TtsService` to the on-device engine to say
      // the very thing that was just cancelled.
      if (myGeneration != _generation) {
        debugPrint('[CloudTts] dropping an utterance cancelled while it was being fetched');
        return true;
      }
      await _ensureContext();
      await _player.stop();
      final done = Completer<void>();
      late final StreamSubscription<void> sub;
      sub = _player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
        sub.cancel();
      });
      await _player.play(BytesSource(bytes));
      await done.future.timeout(_playbackTimeoutFor(trimmed), onTimeout: () {});
      return true;
    } catch (e) {
      debugPrint('[CloudTts] error: $e');
      return false;
    }
  }

  /// How long to wait for playback before giving up on the completion event.
  ///
  /// Was a flat 30 seconds, which is shorter than this app's longest
  /// narration. The command tour reads every command group, its examples and
  /// a closing line telling the user what to say to continue — well past 30s.
  /// The timeout fired, `speak()` returned while audio was still playing, and
  /// the caller opened the microphone over the tail. The closing instruction,
  /// the one part a blind user cannot do without, was what got talked over.
  ///
  /// Scaled to the text instead of guessed. Speech runs around 150 words a
  /// minute; 0.6s per word is that with a wide margin, and the 15s floor
  /// covers short utterances plus synthesis latency. The timeout is a
  /// backstop against a lost completion event, not a schedule — overshooting
  /// costs nothing, undershooting cuts a user off mid-sentence.
  static Duration _playbackTimeoutFor(String text) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    final estimated = Duration(milliseconds: 600 * words + 15000);
    return estimated;
  }

  Future<void> stop() {
    _generation++;
    return _player.stop();
  }

  Future<void> dispose() => _player.dispose();
}
