import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../utils/wav_encoder.dart';

/// Which cue. Rising means the microphone opened, falling means it closed.
///
/// The direction carries the meaning, not the pitch. Two tones that differ
/// only in timbre are indistinguishable on a phone speaker in a Dhaka street;
/// up-versus-down survives a bad speaker, a pocket and traffic.
enum Earcon { listening, stopped }

/// The sound that says the microphone is open — item 59.
///
/// **Reported:** "sound cue when mic is activated after hey jarvis or any
/// autolistening."
///
/// There was a haptic and nothing audible. A haptic is the right cue for a
/// phone in a hand, and no cue at all for one in a pocket or a bag, which is
/// where a blind user walking with a cane keeps it. So a user says "Hey ANT",
/// hears nothing, and has no way to know whether to start talking — and the
/// wake word only fires about half the time (item 47), so "did it hear me"
/// is a question they are asking constantly.
///
/// ## Why the tone is generated rather than shipped
///
/// No audio asset, no `pubspec` entry, no licence to track, nothing to get
/// out of sync with a build. The app already has `wrapPcm16AsWav` for voice
/// memos, and a two-tone chirp is a few lines of arithmetic — the bytes are
/// built once on first use and reused for the life of the process.
///
/// ## Why nothing waits for it
///
/// Callers start the tone and carry on. Putting audio playback on the
/// critical path of opening the microphone means a device where the audio
/// plugin stalls or is missing gets no microphone — and in an app whose most
/// repeated complaint is some form of "it didn't hear me", a cue that can
/// prevent listening is worse than no cue.
///
/// So the tone overlaps the first moments of the session. That is fine here
/// and would not be for narration (item 23, "the app transcribes its own
/// narration"): a 160ms pure sine is not speech and no recognizer turns it
/// into words, where the app reading a sentence aloud into its own
/// microphone genuinely did.
class EarconService {
  EarconService({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  static const int _sampleRate = 16000;

  final _cache = <Earcon, Uint8List>{};

  /// Plays [cue].
  ///
  /// Never throws, and bounded: a device that will not play a tone must not
  /// stop the microphone from opening, and neither must one that starts
  /// playing and never reports finishing. The cue is an addition to the
  /// haptic and the on-screen state, never the only thing carrying the
  /// message.
  Future<void> play(Earcon cue) async {
    try {
      final bytes = _cache[cue] ??= toneFor(cue);
      await _player.play(BytesSource(bytes, mimeType: 'audio/wav'), volume: 0.6);
      // Bare `.timeout()`, caught by type rather than handled by callback.
      //
      // This was `onTimeout: () {}` and it threw on every single cue:
      //
      //   type '() => Null' is not a subtype of
      //   type '(() => FutureOr<AudioEvent>)?' of 'onTimeout'
      //
      // `onPlayerComplete.first` is a `Future<AudioEvent>`, and `.timeout`
      // type-checks its callback against the *runtime* type of the future it
      // is attached to — so a callback returning null cannot satisfy it.
      // Item 46, verbatim, in a different file: same operator, same trap,
      // and the same fix it landed on. Bare `.timeout()` depends on nothing
      // about what the future carries, which is the property worth having.
      //
      // The try/catch below meant this degraded instead of crashing, so the
      // cue simply never played and item 59 was silently dead in the build
      // that shipped.
      await _player.onPlayerComplete.first.timeout(const Duration(milliseconds: 600));
    } on TimeoutException {
      // A player that never reports completion must not hold the microphone
      // shut. Carrying on is strictly better than waiting.
    } catch (e) {
      debugPrint('[Earcon] could not play $cue: $e');
    }
  }

  Future<void> dispose() => _player.dispose();

  /// The WAV bytes for a cue. Visible for testing, and pure.
  @visibleForTesting
  static Uint8List toneFor(Earcon cue) {
    // A fifth apart, in the range a phone speaker actually reproduces.
    // Below ~500Hz a small speaker gives back almost nothing.
    final steps = switch (cue) {
      Earcon.listening => const [(freq: 880.0, ms: 70), (freq: 1320.0, ms: 90)],
      Earcon.stopped => const [(freq: 1320.0, ms: 70), (freq: 880.0, ms: 90)],
    };
    final samples = BytesBuilder();
    for (final step in steps) {
      final count = _sampleRate * step.ms ~/ 1000;
      for (var i = 0; i < count; i++) {
        // Raised-cosine envelope over the whole step. A tone that starts and
        // stops at full amplitude clicks, and a click is what a cheap speaker
        // reproduces best — it would be the loudest part of the cue.
        final envelope = 0.5 - 0.5 * math.cos(2 * math.pi * i / count);
        final value = math.sin(2 * math.pi * step.freq * i / _sampleRate) * envelope * 0.7;
        final sample = (value * 32767).round().clamp(-32768, 32767);
        samples.add([sample & 0xFF, (sample >> 8) & 0xFF]);
      }
    }
    return wrapPcm16AsWav(samples.toBytes(), sampleRate: _sampleRate, numChannels: 1);
  }
}
