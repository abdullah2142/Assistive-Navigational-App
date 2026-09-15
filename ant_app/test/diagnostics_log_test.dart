// The session log testers send back, and the redaction that makes it safe to
// send.
//
// The app already writes 118 deliberate breadcrumbs through `debugPrint`, and
// one device session with them settled more than a week of guessing at item
// 31. The testers are not at a desk with a cable, so this keeps the last of
// those lines in memory and writes them out on request.
//
// The redaction is the part that has to be right. Those lines carry, verbatim:
// every voice transcript, the user's disability answers as they spoke them,
// their family's phone numbers, their account id and their coordinates. A
// naive export would hand all of it to whoever the tester forwards the file
// to. So it is redacted **on the way in** — a buffer that holds raw text and
// cleans it at export is one bug away from shipping the lot.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/diagnostics/diagnostics_log.dart';
import 'package:ant_app/core/diagnostics/log_redaction.dart';

void main() {
  group('what must never reach the file', () {
    test('a transcript keeps its shape and loses its words', () {
      // What debugging needs from these lines is whether a final result
      // arrived and roughly how long it was — almost never the words.
      final out = redactLogLine('[OnboardingVoice] heard (final): "আমি একাই হাঁটি"');
      expect(out, isNot(contains('একাই')));
      expect(out, contains('3 words'));
      expect(out, contains('[OnboardingVoice] heard (final)'),
          reason: 'the line still has to be readable as itself');
    });

    test('an empty transcript is still distinguishable from a long one', () {
      // "The recognizer returned nothing" and "it returned a sentence the
      // matcher refused" are different bugs, and this is what tells them apart.
      expect(redactLogLine('heard ""'), contains('<empty>'));
      expect(redactLogLine('heard "one two three four five"'), contains('5 words'));
    });

    test('a phone number does not survive', () {
      final out = redactLogLine('[Emergency] messaging +8801711111111');
      expect(out, isNot(contains('01711111111')));
      expect(out, contains('<digits:'));
    });

    test('a pairing code does not survive', () {
      // Live for fifteen minutes and redeemable by anyone who reads it.
      final out = redactLogLine('[Pairing] generated code 481920');
      expect(out, isNot(contains('481920')));
    });

    test('coordinates do not survive', () {
      final out = redactLogLine('[Map] fix at 23.746100, 90.374200');
      expect(out, isNot(contains('23.7461')));
      expect(out, contains('<coord>'));
    });

    test('a uid does not survive, but stays traceable within the file', () {
      // Two lines about the same user must still be tied together, or the log
      // stops being usable for exactly the multi-step bugs it is for.
      const uid = 'aZ3kQ9mR2pL7xY4tB6vC';
      final a = redactLogLine('[Onboarding] resuming $uid at deafHearingQuestion');
      final b = redactLogLine('[CaretakerInbox] listening for $uid');
      expect(a, isNot(contains(uid)));
      expect(b, isNot(contains(uid)));
      final tag = RegExp(r'<id:\w{4}>').firstMatch(a)?.group(0);
      expect(tag, isNotNull);
      expect(b, contains(tag));
    });
  });

  group('what must survive, or the log is useless', () {
    test('the tags that say which subsystem spoke', () {
      for (final line in [
        '[WakeWord] DETECTED (score=0.783)',
        '[Stt] cloud session ending (silence)',
        '[BackgroundListening] FOREGROUND SERVICE DID NOT START: ForegroundServiceStartNotAllowedException',
        '[Haptics] hazard alarm throttled',
      ]) {
        expect(redactLogLine(line), line, reason: 'nothing sensitive in: $line');
      }
    });

    test('a threshold printed as a raw float, which is what the dial emits', () {
      // Found in the first real tester logs: the dial computes the threshold
      // by arithmetic, so it prints as `0.30000000000000004`, and the old
      // coordinate rule ate it — `threshold <coord>`. The one number the dial
      // exists to expose, redacted out of the logs meant to carry it.
      const line = '[WakeWord] peak=0.024 (threshold 0.30000000000000004) over the last 3s';
      expect(redactLogLine(line), line);
      expect(redactLogLine('[WakeWord] detection threshold set to 0.05'),
          '[WakeWord] detection threshold set to 0.05');
    });

    test('a real coordinate is still caught', () {
      // Dhaka sits near 23.8N, 90.4E — a non-zero whole part is what separates
      // a position from a score.
      expect(redactLogLine('[Map] fix at 23.746100, 90.374200'), contains('<coord>'));
      expect(redactLogLine('[Map] fix at -23.746100'), contains('<coord>'));
    });

    test('a wake-word score, which is the whole of item 40', () {
      // 0.783 must not be eaten as a coordinate or a digit run — it is the
      // number the sensitivity dial exists to expose.
      expect(redactLogLine('[WakeWord] peak=0.783 (threshold 0.3)'),
          '[WakeWord] peak=0.783 (threshold 0.3)');
    });

    test('an exception class name, which is what item 31 is waiting on', () {
      const line = '[BackgroundListening] start failed: ForegroundServiceStartNotAllowedException';
      expect(redactLogLine(line), line);
    });
  });

  group('the buffer', () {
    test('records in order, with a timestamp', () {
      final log = DiagnosticsLog()..add('first')..add('second');
      final out = log.render();
      expect(out.indexOf('first'), lessThan(out.indexOf('second')));
      expect(out, matches(RegExp(r'\d{2}:\d{2}:\d{2}\.\d{3}\s+first')));
    });

    test('drops the oldest, because the end is where the bug is', () {
      final log = DiagnosticsLog(capacity: 3);
      for (var i = 0; i < 10; i++) {
        log.add('line$i');
      }
      expect(log.length, 3);
      final out = log.render();
      expect(out, contains('line9'));
      expect(out, isNot(contains('line0')));
      expect(out, contains('oldest dropped'), reason: 'the report has to admit it is truncated');
    });

    test('says plainly what it did to the contents', () {
      // The tester is forwarding this to someone. They should be able to read
      // what they are sending.
      expect(DiagnosticsLog().render(), contains('replaced with their shape'));
    });

    test('carries build facts so nobody has to recite them', () {
      // "They say it's the latest one" already cost a round of confusion.
      expect(DiagnosticsLog().render(header: {'app': '1.0.0+3'}), contains('1.0.0+3'));
    });
  });

  group('installing it', () {
    test('captures debugPrint without swallowing it', () {
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');

      final log = DiagnosticsLog();
      log.install();
      debugPrint('[Test] hello "secret words here"');
      log.uninstall();
      debugPrint = original;

      expect(printed.single, contains('secret words here'),
          reason: 'a developer on a cable still sees everything');
      expect(log.render(), isNot(contains('secret words here')),
          reason: 'the file does not');
      expect(log.render(), contains('3 words'));
    });

    test('installing twice does not double every line', () {
      final original = debugPrint;
      final log = DiagnosticsLog()..install()..install();
      debugPrint('[Test] once');
      log.uninstall();
      debugPrint = original;
      expect(log.length, 1);
    });
  });
}
