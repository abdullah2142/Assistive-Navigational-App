// The voice screens' waits have to be takeable-back.
//
// Every narrate-then-listen loop in this app waits: `narrationSettle` before
// the microphone opens, 400 ms between listen attempts. Written as a bare
// `Future.delayed` those timers outlive the widget — the loop's own `mounted`
// check retires it on the far side of the await, but the timer is still armed
// and still pointing at that closure when the tree is torn down.
//
// On a device that is a leak nobody sees. In a widget test it is a hard
// failure, which is how it was found: all four tests in
// passerby_picker_voice_test.dart died with "A Timer is still pending even
// after the widget tree was disposed", pointing at the Show Screen overlay's
// dismiss loop.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/utils/cancellable_delay.dart';

void main() {
  group('CancellableDelay', () {
    testWidgets('a wait that is left alone completes true', (tester) async {
      final delay = CancellableDelay();
      bool? outcome;
      delay.wait(const Duration(milliseconds: 400)).then((v) => outcome = v);

      await tester.pump(const Duration(milliseconds: 200));
      expect(outcome, isNull, reason: 'it must actually wait');

      await tester.pump(const Duration(milliseconds: 250));
      expect(outcome, isTrue);
    });

    testWidgets('cancelling completes an in-flight wait false, and disarms it',
        (tester) async {
      final delay = CancellableDelay();
      bool? outcome;
      delay.wait(const Duration(milliseconds: 400)).then((v) => outcome = v);

      await tester.pump(const Duration(milliseconds: 100));
      delay.cancel();
      // Resolves without anything else having to happen — the loop awaiting
      // it is released immediately rather than at the end of the delay.
      await tester.pump();
      expect(outcome, isFalse);

      // And no timer survives to fire. If one did, this pump would throw.
      await tester.pump(const Duration(milliseconds: 500));
      expect(outcome, isFalse);
    });

    testWidgets('a wait started after cancelling never arms a timer', (tester) async {
      // The case that matters for disposal: a loop can be awaiting something
      // else entirely (a listen session) when the widget dies, and reach its
      // next `wait` afterwards. It must not get a fresh timer on the way out.
      final delay = CancellableDelay();
      delay.cancel();

      bool? outcome;
      delay.wait(const Duration(milliseconds: 400)).then((v) => outcome = v);
      await tester.pump();
      expect(outcome, isFalse);
      expect(delay.isCancelled, isTrue);
    });

    testWidgets('concurrent waits are all released', (tester) async {
      // The picker can have two loops running at once — a re-prompt started
      // from inside a listen callback while the outer loop is still awaiting
      // that same session. A single-timer field would strand one of them.
      final delay = CancellableDelay();
      final outcomes = <bool>[];
      delay.wait(const Duration(milliseconds: 400)).then(outcomes.add);
      delay.wait(const Duration(milliseconds: 600)).then(outcomes.add);
      delay.wait(const Duration(seconds: 2)).then(outcomes.add);

      await tester.pump(const Duration(milliseconds: 100));
      delay.cancel();
      await tester.pump();

      expect(outcomes, [false, false, false]);
    });

    testWidgets('cancelling twice is harmless', (tester) async {
      final delay = CancellableDelay();
      bool? outcome;
      delay.wait(const Duration(milliseconds: 400)).then((v) => outcome = v);
      await tester.pump(const Duration(milliseconds: 50));
      delay.cancel();
      delay.cancel();
      await tester.pump();
      expect(outcome, isFalse);
    });

    testWidgets('a wait already elapsed is unaffected by a later cancel', (tester) async {
      final delay = CancellableDelay();
      bool? outcome;
      delay.wait(const Duration(milliseconds: 100)).then((v) => outcome = v);
      await tester.pump(const Duration(milliseconds: 150));
      expect(outcome, isTrue);
      delay.cancel();
      await tester.pump();
      expect(outcome, isTrue, reason: 'a completed wait cannot be retracted');
    });
  });

  // The shape the three voice screens actually use it in, as a widget, so the
  // framework's own "timer still pending after dispose" assertion is the one
  // doing the judging.
  testWidgets('a looping widget leaves no pending timer behind', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: _LoopingWidget()));
    // Two full turns, leaving a third wait armed and only part-way through.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));

    // Tear the tree down with that third wait still in flight, and never pump
    // far enough for it to fire on its own — so the only thing that can
    // retire it is `dispose`. Without the cancel there, this fails the test
    // outright with "A Timer is still pending", which is the whole point of
    // the fixture: pumping past the delay instead would drain the timer and
    // the test would pass either way.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(milliseconds: 50));
  });
}

class _LoopingWidget extends StatefulWidget {
  const _LoopingWidget();

  @override
  State<_LoopingWidget> createState() => _LoopingWidgetState();
}

class _LoopingWidgetState extends State<_LoopingWidget> {
  final _delay = CancellableDelay();

  @override
  void initState() {
    super.initState();
    _loop();
  }

  Future<void> _loop() async {
    while (mounted) {
      if (!await _delay.wait(const Duration(milliseconds: 400))) return;
    }
  }

  @override
  void dispose() {
    _delay.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
