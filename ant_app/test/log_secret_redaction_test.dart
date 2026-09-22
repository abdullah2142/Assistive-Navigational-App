import 'package:ant_app/core/diagnostics/log_redaction.dart';
import 'package:flutter_test/flutter_test.dart';

/// The 22 September diagnostics file — written to be shared, and headed with
/// a promise that identifying material had already been replaced — carried a
/// working Google API key in full inside a Cloud TTS failure URL.
void main() {
  // A syntactically real Google-shaped key, invented for this test.
  const key = 'AIzaSyB1cD3fG7hJ9kL2mN4pQ6rS8tU0vW2xY4z';

  test('a key in a query string does not reach the file', () {
    const line = '[CloudTts] error: uri=https://texttospeech.googleapis.com/v1/text:synthesize?key=$key';
    final out = redactLogLine(line);
    expect(out, isNot(contains(key)));
    expect(out, contains('<redacted>'));
  });

  test('no recognisable fragment survives either', () {
    // Partial redaction is the failure that actually happened: the uid rule
    // split the key on its hyphens and left most of it in place.
    final out = redactLogLine('?key=$key');
    for (final piece in key.split(RegExp('[-_]'))) {
      if (piece.length < 8) continue;
      expect(out, isNot(contains(piece)), reason: 'leaked the fragment "$piece"');
    }
  });

  test('the other spellings are covered', () {
    for (final line in [
      'token=$key',
      'access_token=$key',
      'api_key=$key',
      'Authorization: Bearer $key',
      'password=hunter2placeholder',
    ]) {
      expect(redactLogLine(line), isNot(contains(key)), reason: line);
      expect(redactLogLine(line), contains('<redacted>'), reason: line);
    }
  });

  test('the URL around it is kept, because that is the diagnostic', () {
    final out = redactLogLine('uri=https://texttospeech.googleapis.com/v1/text:synthesize?key=$key');
    expect(out, contains('texttospeech.googleapis.com'));
    expect(out, contains('text:synthesize'));
  });

  test('ordinary lines are untouched', () {
    const line = '[Depth] 814ms change=level score=2.3 paces=0';
    expect(redactLogLine(line), line);
  });
}
