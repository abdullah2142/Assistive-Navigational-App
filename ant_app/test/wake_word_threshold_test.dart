// Where the detection line sits, and why it moved.
//
// Reported as "there are times it simply doesn't respond". The device log on
// 12 September says why: across 56 scored windows of one session, the phrase
// was *heard and scored* three times without firing — 0.300, 0.302 and 0.342
// against a threshold of 0.5.
//
// Those three are known to be real attempts rather than noise because each is
// followed by a successful detection within 3-16 seconds, which is what
// somebody saying it, getting nothing, and saying it again looks like in a
// log.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/wake_word_service.dart';

void main() {
  // Every peak the 12 September session scored, by what it actually was.
  const background = [0.000, 0.000, 0.001, 0.002, 0.003];
  const otherSpeech = [0.016, 0.059, 0.103, 0.144];
  const missedAttempts = [0.300, 0.302, 0.342];
  const detected = [0.667, 0.749, 0.836, 0.850, 0.853, 0.854, 0.882, 0.972];

  test('background can never fire it', () {
    // 47 of the 56 windows were here. This is the margin that matters most:
    // a wake word that fires on silence is uninstalled the same day.
    for (final score in background) {
      expect(score, lessThan(WakeWordService.detectionThreshold),
          reason: 'silence scored $score');
    }
    expect(WakeWordService.detectionThreshold / 0.003, greaterThan(50),
        reason: 'at least a 50x margin over the loudest background window');
  });

  test('ordinary speech does not fire it', () {
    for (final score in otherSpeech) {
      expect(score, lessThan(WakeWordService.detectionThreshold),
          reason: 'non-wake-word speech scored $score');
    }
  });

  test('the attempts that used to be missed now fire', () {
    // The whole point of the change.
    for (final score in missedAttempts) {
      expect(score, greaterThanOrEqualTo(WakeWordService.detectionThreshold),
          reason: 'a real "Hey Jarvis" scored $score and must now be heard');
    }
  });

  test('everything that already worked still does', () {
    for (final score in detected) {
      expect(score, greaterThanOrEqualTo(WakeWordService.detectionThreshold));
    }
  });

  test('the threshold sits between the two clusters, not inside one', () {
    // A threshold inside a cluster is a coin flip for whoever is in it.
    expect(WakeWordService.detectionThreshold, greaterThan(otherSpeech.reduce((a, b) => a > b ? a : b)));
    expect(WakeWordService.detectionThreshold,
        lessThanOrEqualTo(missedAttempts.reduce((a, b) => a < b ? a : b)));
  });
}
