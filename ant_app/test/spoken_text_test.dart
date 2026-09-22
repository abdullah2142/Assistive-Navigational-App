import 'package:ant_app/core/utils/spoken_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('forSpeech strips what an engine would otherwise pronounce', () {
    test('markdown emphasis leaves no stranded marker', () {
      expect(forSpeech('**Labaid Hospital** is close'), 'Labaid Hospital is close');
      expect(forSpeech('that is _very_ far'), 'that is very far');
      expect(forSpeech('the `6 No. Dhaka` bus'), 'the 6 No. Dhaka bus');
      expect(forSpeech('~~cancelled~~ moved'), 'cancelled moved');
    });

    test('a single leftover asterisk is the failure mode being prevented', () {
      expect(forSpeech('**bold**'), isNot(contains('*')));
      expect(forSpeech('*one* **two** ***three***'), isNot(contains('*')));
    });

    test('a bulleted list becomes sentences, not a run-on', () {
      expect(
        forSpeech('- turn left\n- cross at the signal'),
        'turn left. cross at the signal',
      );
      expect(forSpeech('1. first\n2. second'), 'first. second');
    });

    test('headings lose their hashes', () {
      expect(forSpeech('## Route\nturn left'), 'Route. turn left');
    });

    test('links are spoken as their text, never their URL', () {
      final spoken = forSpeech('see [Labaid](https://example.com/x?a=1)');
      expect(spoken, 'see Labaid');
      expect(spoken, isNot(contains('http')));
    });

    test('emoji are dropped rather than announced by name', () {
      expect(forSpeech('careful ⚠️ there is a kerb'), 'careful there is a kerb');
      expect(forSpeech('done 👍'), 'done');
    });

    test('table pipes and block quotes go', () {
      expect(forSpeech('> mind the step'), 'mind the step');
      expect(forSpeech('| a | b |'), 'a b');
    });

    test('horizontal rules go', () {
      expect(forSpeech('one\n---\ntwo'), 'one. two');
    });

    test('runs of punctuation are flattened', () {
      expect(forSpeech('really!!!'), 'really!');
      expect(forSpeech('wait...'), 'wait.');
    });
  });

  group('forSpeech keeps what the listener needs', () {
    test('sentence punctuation survives — it is the engine prosody', () {
      expect(forSpeech('Turn left. Then stop, carefully. Ready?'),
          'Turn left. Then stop, carefully. Ready?');
    });

    test('the Bangla danda survives', () {
      expect(forSpeech('বাঁ দিকে ঘুরুন। তারপর থামুন।'), 'বাঁ দিকে ঘুরুন। তারপর থামুন।');
    });

    test('Bangla text is otherwise untouched', () {
      const bn = 'ধানমন্ডি ল্যাব এইড ৪০০ মিটার দূরে';
      expect(forSpeech(bn), bn);
    });

    test('numbers, units and percentages are the answer, not formatting', () {
      expect(forSpeech('400m away, 20% battery, 25°C'), '400m away, 20% battery, 25°C');
    });

    test('plain text is returned unchanged', () {
      const plain = 'I could not see — the lens is covered.';
      expect(forSpeech(plain), plain);
    });

    test('empty stays empty', () {
      expect(forSpeech(''), '');
    });
  });

  test('a realistic formatted reply reads cleanly end to end', () {
    const raw = '**Labaid Hospital** is 400m away:\n'
        '- turn left\n'
        '- cross at the signal 🚦\n';
    expect(
      forSpeech(raw),
      'Labaid Hospital is 400m away: turn left. cross at the signal.',
    );
  });
}
