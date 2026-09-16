// The sound that says the microphone is open — open_bugs item 59.
//
// Reported: "sound cue when mic is activated after hey jarvis or any
// autolistening."
//
// There was a haptic and nothing audible. A haptic is the right cue for a
// phone in a hand and no cue at all for one in a pocket or a bag, which is
// where a blind user walking with a cane keeps it. So "Hey ANT" was answered
// with silence, and since the wake word only fires about half the time (item
// 47), "did it hear me" is a question the user is asking constantly.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/earcon_service.dart';

void main() {
  /// Reads the little-endian PCM16 samples back out of a WAV.
  List<int> samplesOf(List<int> wav) {
    const headerBytes = 44;
    final out = <int>[];
    for (var i = headerBytes; i + 1 < wav.length; i += 2) {
      final raw = wav[i] | (wav[i + 1] << 8);
      out.add(raw >= 0x8000 ? raw - 0x10000 : raw);
    }
    return out;
  }

  test('a cue is a real, playable WAV', () {
    // Generated rather than shipped as an asset: no pubspec entry, no licence
    // to track, nothing to fall out of sync with a build.
    final wav = EarconService.toneFor(Earcon.listening);
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    expect(wav.length, greaterThan(44), reason: 'a header with no audio behind it');
  });

  test('it is short enough not to delay the microphone', () {
    // It is awaited before the recognizer starts, so its length is latency
    // the user feels on every single utterance.
    final samples = samplesOf(EarconService.toneFor(Earcon.listening));
    final ms = samples.length * 1000 / 16000;
    expect(ms, lessThan(250), reason: 'this is paid on every mic open');
    expect(ms, greaterThan(80), reason: 'shorter than this is not heard at all');
  });

  test('opening and closing are opposite directions, not just different', () {
    // Two tones that differ only in timbre are indistinguishable on a phone
    // speaker in a Dhaka street. Up-versus-down survives a bad speaker, a
    // pocket and traffic.
    final opening = samplesOf(EarconService.toneFor(Earcon.listening));
    final closing = samplesOf(EarconService.toneFor(Earcon.stopped));

    // Zero crossings per half stand in for pitch without needing an FFT.
    int crossings(List<int> s) {
      var n = 0;
      for (var i = 1; i < s.length; i++) {
        if ((s[i - 1] < 0) != (s[i] < 0)) n++;
      }
      return n;
    }

    final openFirst = crossings(opening.sublist(0, opening.length ~/ 2));
    final openSecond = crossings(opening.sublist(opening.length ~/ 2));
    expect(openSecond, greaterThan(openFirst), reason: 'opening rises');

    final closeFirst = crossings(closing.sublist(0, closing.length ~/ 2));
    final closeSecond = crossings(closing.sublist(closing.length ~/ 2));
    expect(closeSecond, lessThan(closeFirst), reason: 'closing falls');
  });

  test('it starts and ends at silence, so it does not click', () {
    // A tone that starts at full amplitude clicks, and a click is what a
    // cheap speaker reproduces best — it would be the loudest part of the cue.
    for (final cue in Earcon.values) {
      final samples = samplesOf(EarconService.toneFor(cue));
      expect(samples.first.abs(), lessThan(200), reason: '$cue starts abruptly');
      expect(samples.last.abs(), lessThan(200), reason: '$cue ends abruptly');
    }
  });

  test('it is loud enough to be heard over a street', () {
    final samples = samplesOf(EarconService.toneFor(Earcon.listening));
    final peak = samples.map((s) => s.abs()).reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(16000), reason: 'a cue nobody hears is not a cue');
    expect(peak, lessThanOrEqualTo(32767));
  });

  test('both cues exist and differ', () {
    expect(EarconService.toneFor(Earcon.listening),
        isNot(EarconService.toneFor(Earcon.stopped)));
  });
}
