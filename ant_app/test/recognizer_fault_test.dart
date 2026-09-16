// The recognizer's stream dying out of band — open_bugs item 49.
//
// Not reported by a tester. Found in their logs: 37 occurrences of
// `Bad state: Cannot add new events after calling close` across three
// half-hour sessions, swallowed by `main.dart`'s `PlatformDispatcher.onError`.
//
// Swallowing it was right — `google_speech` throws it from inside its own
// zone after its controller is closed, so it propagates through nothing this
// app can catch. Ignoring it was not. Reading the logs line by line says the
// message covers two different events:
//
//   28 of 37  fired after the session had already ended and the transcript
//             had already gone to Gemini. Harmless: the tail of a stream
//             nobody is waiting on.
//    9 of 37  fired mid-utterance, with partials still arriving and no final
//             ever delivered. Those leave the service listening to a dead
//             stream and the caller awaiting a future that never completes —
//             a microphone shown as open and permanently deaf, with no error
//             and no result. Very likely behind some of the standing "it
//             didn't hear me" reports.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/recognizer_faults.dart';

void main() {
  group('telling this error from every other one', () {
    test('the recognizer stream death is recognised', () {
      expect(
        RecognizerFaults.isDeadStream(
            StateError('Cannot add new events after calling close')),
        isTrue,
      );
    });

    test('another StateError is not', () {
      // Matched on the message because the type is `StateError`, which is far
      // too broad to act on — tearing down a working microphone on the wrong
      // error would be a worse bug than the one being fixed.
      expect(RecognizerFaults.isDeadStream(StateError('Bad state: no element')), isFalse);
    });

    test('an unrelated exception is not', () {
      expect(RecognizerFaults.isDeadStream(Exception('network unreachable')), isFalse);
      expect(RecognizerFaults.isDeadStream('a string'), isFalse);
    });
  });

  group('the bus', () {
    test('a matching fault reaches the listener', () {
      final faults = RecognizerFaults.forTesting();
      var notified = 0;
      faults.listen(() => notified++);
      faults.report(StateError('Cannot add new events after calling close'));
      expect(notified, 1);
      expect(faults.faultCount, 1);
    });

    test('an unrelated error reaches nobody', () {
      final faults = RecognizerFaults.forTesting();
      var notified = 0;
      faults.listen(() => notified++);
      faults.report(Exception('something else entirely'));
      expect(notified, 0);
      expect(faults.faultCount, 0, reason: 'and is not counted as one');
    });

    test('unregistering stops delivery', () {
      final faults = RecognizerFaults.forTesting();
      var notified = 0;
      final stop = faults.listen(() => notified++);
      stop();
      faults.report(StateError('Cannot add new events after calling close'));
      expect(notified, 0);
    });

    test('faults and lost sessions are counted apart', () {
      // The whole point of the finding: most of these cost nothing, and a
      // count that conflates them says the app is far sicker than it is. The
      // next tester round gets both numbers in the log rather than needing
      // somebody to correlate timestamps by hand, which is how this was found.
      final faults = RecognizerFaults.forTesting();
      for (var i = 0; i < 5; i++) {
        faults.report(StateError('Cannot add new events after calling close'));
      }
      faults.noteSessionLost();
      expect(faults.faultCount, 5);
      expect(faults.sessionsLost, 1);
    });

    test('several listeners all hear it', () {
      final faults = RecognizerFaults.forTesting();
      var a = 0, b = 0;
      faults.listen(() => a++);
      faults.listen(() => b++);
      faults.report(StateError('Cannot add new events after calling close'));
      expect([a, b], [1, 1]);
    });

    test('a listener that unregisters during delivery does not break it', () {
      // `SttService.stop()` runs synchronously far enough to deregister in
      // some teardown orders; iterating the live list would throw.
      final faults = RecognizerFaults.forTesting();
      late VoidCallback stop;
      var second = 0;
      stop = faults.listen(() => stop());
      faults.listen(() => second++);
      faults.report(StateError('Cannot add new events after calling close'));
      expect(second, 1);
    });
  });
}
