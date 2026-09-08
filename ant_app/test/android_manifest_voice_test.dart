import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the Android manifest entries that voice input depends on.
///
/// These are asserted from a test rather than left to review because the way
/// they fail is invisible. Android 11+ hides packages an app has not declared
/// an interest in, so without the `<queries>` entries below
/// `speech_to_text`'s `initialize()` returns false, `SttService` logs "mic
/// unavailable" and onboarding gives up without speaking. Nothing crashes and
/// no error reaches the user — for a blind user the app has simply stopped
/// responding.
///
/// It stayed hidden for months because it only affects the *on-device*
/// recognizer. Any build compiled with `CLOUD_STT_API_KEY` streams raw audio
/// to Google through `record` and never asks the platform for a recognizer,
/// so a developer's own build masks the bug completely — which is exactly
/// what happened: a release built without the key reached testers, fell back
/// to on-device recognition, and voice was dead for everyone but the person
/// who tested it.
void main() {
  late String manifest;

  setUpAll(() {
    manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  });

  test('declares the speech recognition service in <queries>', () {
    expect(
      manifest,
      contains('android.speech.RecognitionService'),
      reason: 'Android 11+ will hide every speech recognizer from this app, '
          'and on-device STT will fail silently.',
    );
  });

  test('declares the text-to-speech service in <queries>', () {
    expect(
      manifest,
      contains('android.intent.action.TTS_SERVICE'),
      reason: 'Spoken output is the primary output channel of this app.',
    );
  });

  test('still requests microphone permission', () {
    expect(manifest, contains('android.permission.RECORD_AUDIO'));
  });

  test('the queries entries sit inside a <queries> block', () {
    // A `<queries>` declaration outside the block, or a second block, is
    // silently ignored by the manifest merger rather than rejected.
    final queries = RegExp(r'<queries>(.*?)</queries>', dotAll: true)
        .allMatches(manifest)
        .toList();
    expect(queries, hasLength(1), reason: 'exactly one <queries> block expected');
    expect(queries.single.group(1), contains('android.speech.RecognitionService'));
    expect(queries.single.group(1), contains('android.intent.action.TTS_SERVICE'));
  });
}
