import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

/// Narration being talked over, modelled at the level the bug lives.
///
/// `TtsService.speak` used to start immediately and stop whatever was already
/// playing. That stop completed the *earlier* call's future, so a screen that
/// had correctly written `await tts.speak(...)` before opening the microphone
/// proceeded while the next utterance was still being spoken. Testers
/// reported narration cut off and option lists talked over — leaving a live
/// mic and no idea what they were allowed to say.
///
/// These tests exercise the queueing contract itself. The real service's
/// audio path needs a device; what has to hold regardless is that an awaited
/// speak means "this finished", and that stopping abandons the queue rather
/// than letting it play over the next screen.
class _FakeTts {
  final List<String> spoken = [];
  final List<String> started = [];
  Future<void> _chain = Future<void>.value();
  int _generation = 0;

  /// Utterances that should throw from the playback layer.
  final Set<String> failOn = {};

  /// Stands in for the real playback, long enough to overlap.
  Future<void> _speakNow(String text) async {
    started.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (failOn.contains(text)) throw StateError('playback failed');
    spoken.add(text);
  }

  Future<void> speak(String text) {
    final myGeneration = _generation;
    final next = _chain.then((_) async {
      if (myGeneration != _generation) return;
      await _speakNow(text);
    });
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> stop() async {
    _generation++;
  }
}

void main() {
  group("an utterance cancelled mid-fetch", _inFlightTests);
  test('an awaited speak really has finished when it returns', () async {
    final tts = _FakeTts();

    await tts.speak('question and options');

    expect(tts.spoken, ['question and options']);
  });

  test('overlapping calls queue instead of cutting each other off', () async {
    // The exact shape of the bug: two utterances issued back to back. The
    // second used to stop the first mid-sentence.
    final tts = _FakeTts();

    final first = tts.speak('a couple more questions');
    final second = tts.speak('say yes or no');
    await Future.wait([first, second]);

    expect(tts.spoken, ['a couple more questions', 'say yes or no']);
  });

  test('the second utterance does not begin before the first ends', () async {
    // "Started" order alone would pass even while overlapping; what matters
    // is that nothing starts while something else is still playing.
    final tts = _FakeTts();

    final first = tts.speak('one');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final second = tts.speak('two');

    // Mid-flight: the first is playing, the second has not begun.
    expect(tts.started, ['one']);

    await Future.wait([first, second]);
    expect(tts.started, ['one', 'two']);
  });

  test('stop abandons what is queued rather than playing it later', () async {
    // Leaving a screen mid-narration must not let the rest of its queue play
    // over the screen that follows.
    final tts = _FakeTts();

    final first = tts.speak('first');
    final queued = tts.speak('should never be spoken');
    await tts.stop();
    await Future.wait([first, queued]);

    expect(tts.spoken, isNot(contains('should never be spoken')));
  });

  test('speaking again after a stop works', () async {
    // The generation guard must not wedge the service permanently.
    final tts = _FakeTts();

    await tts.speak('before');
    await tts.stop();
    await tts.speak('after');

    expect(tts.spoken, contains('after'));
  });

  test('one failed utterance does not block the next', () async {
    // Without keeping the failure off the chain, a single rejected future
    // would silence every utterance queued behind it for the rest of the
    // session — a mute app, from one bad audio call.
    final tts = _FakeTts()..failOn.add('this one throws');

    final failing = tts.speak('this one throws');
    final after = tts.speak('still spoken');

    await expectLater(failing, throwsStateError);
    await after;

    expect(tts.spoken, ['still spoken']);
  });
}

/// The second half of the same bug, one layer down.
///
/// `TtsService`'s generation guard checks *before* handing an utterance to
/// the cloud engine, and its `stop()` stops a *player*. Between the synthesis
/// request going out over HTTP and the audio coming back there is no player
/// to stop — so a `stop()` landing inside that window did nothing at all, the
/// response arrived afterwards, and it played over whatever screen had
/// replaced the one that asked for it.
///
/// Reported from the device as onboarding narration "overlapping into the
/// caretaker code section": role selection's speech was still in flight when
/// the user answered and the flow moved on.
class _FakeCloudTts {
  final List<String> played = [];
  int _generation = 0;

  /// Completes when the test lets the synthesis request return.
  Completer<void>? fetch;

  Future<bool> speak(String text) async {
    final myGeneration = _generation;
    fetch = Completer<void>();
    await fetch!.future;
    // The check that was missing: this is the only moment that can tell a
    // cancelled utterance from a live one.
    if (myGeneration != _generation) return true;
    played.add(text);
    return true;
  }

  void stop() => _generation++;
}

void _inFlightTests() {
  test('an utterance cancelled while it is being fetched is never played', () async {
    final cloud = _FakeCloudTts();

    final speaking = cloud.speak('Are you the person who needs help, or a caretaker?');
    await Future<void>.delayed(Duration.zero);

    // The user answers and the flow moves on while the request is in flight.
    cloud.stop();
    cloud.fetch!.complete();
    await speaking;

    expect(cloud.played, isEmpty, reason: 'it must not play over the next screen');
  });

  test('an utterance that was not cancelled still plays', () async {
    final cloud = _FakeCloudTts();

    final speaking = cloud.speak('Your pairing code is 4 1 7 2 9 3');
    await Future<void>.delayed(Duration.zero);
    cloud.fetch!.complete();
    await speaking;

    expect(cloud.played, ['Your pairing code is 4 1 7 2 9 3']);
  });
}
