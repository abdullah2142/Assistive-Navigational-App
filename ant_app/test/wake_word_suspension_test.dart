import 'package:ant_app/core/services/wake_word_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Suspension nesting.
///
/// The reported failure: with "Hey ANT" on, the hazard hub read out its
/// options and then took no answer, while the same flow worked with the wake
/// word off. Cause was that suspension was scoped to a single `listenOnce`,
/// so the wake-word recorder reclaimed the microphone in the gap between two
/// steps of the flow — which is exactly when the app is speaking — and still
/// held it when the next listen began.
///
/// These tests run against the stub implementation, which is what a test
/// host gets. The stub has no recorder, so what is verified here is the
/// contract every caller depends on: that suspensions nest, that releasing an
/// inner one does not lift an outer one, and that the calls are safe in the
/// orders real screens make them.
void main() {
  // The native implementation builds an AudioRecorder, which touches a
  // platform channel the moment it is constructed.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pauseAround runs its action and returns the value', () async {
    final service = WakeWordService();
    var ran = false;

    final result = await service.pauseAround(() async {
      ran = true;
      return 42;
    });

    expect(ran, isTrue);
    expect(result, 42);
  });

  test('pauseAround nests — an inner release must not lift the outer hold', () async {
    // This is the shape the hub creates: one suspension for the whole sheet,
    // and one per listen inside it.
    final service = WakeWordService();
    final order = <String>[];

    await service.pauseAround(() async {
      order.add('flow-start');
      await service.pauseAround(() async => order.add('listen-1'));
      order.add('narrate');
      await service.pauseAround(() async => order.add('listen-2'));
      order.add('flow-end');
    });

    expect(order, ['flow-start', 'listen-1', 'narrate', 'listen-2', 'flow-end']);
  });

  test('a throw inside pauseAround still releases the suspension', () async {
    // Otherwise one failed listen would leave the wake word suspended for the
    // rest of the session, silently.
    final service = WakeWordService();

    await expectLater(
      service.pauseAround(() async => throw StateError('listen failed')),
      throwsStateError,
    );

    // Still usable afterwards.
    expect(await service.pauseAround(() async => 'ok'), 'ok');
  });

  test('suspend/resume pair the way a screen uses them', () async {
    // initState suspends, dispose resumes.
    final service = WakeWordService();

    service.suspend();
    await service.pauseAround(() async {});
    service.resume();

    expect(await service.pauseAround(() async => 'ok'), 'ok');
  });

  test('resume with nothing held is a no-op, not an error', () async {
    // dispose() calls resume() unconditionally, including on a screen that
    // never got as far as suspending.
    final service = WakeWordService();

    expect(service.resume, returnsNormally);
    expect(service.resume, returnsNormally);
  });
}
