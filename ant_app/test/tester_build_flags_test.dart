import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/config/tester_build_config.dart';

/// Guards the flags the build handed to testers has to carry — item 61.
///
/// Asserted from a test for the same reason the manifest entries are: the way
/// these fail is invisible. A flag that is not passed produces an app that
/// installs, launches and behaves *almost* correctly, and the missing part is
/// only noticed by whoever was relying on it — a tester, some days later,
/// reporting that a button is "gone".
///
/// That is exactly what item 61 was. The ⏩ skip-onboarding shortcut is
/// wrapped in `kDebugMode`, testers are given release builds, so for them the
/// control every testing pack except A begins with did not exist. The code
/// was right; the artifact was not. Only a check against the build script
/// catches that, because every test in this suite runs in debug mode, where
/// the button is present no matter what the flag says.
void main() {
  late String releaseScript;

  setUpAll(() {
    releaseScript = File('../scripts/release_google_build.sh').readAsStringSync();
  });

  test('a build made without the flag is a public build', () {
    // The default has to stay false, or the shortcut past onboarding ships
    // to whoever installs the app.
    expect(TesterBuildConfig.isTesterBuild, isFalse,
        reason: 'no --dart-define was passed to this test run');
  });

  test('the tester build passes TESTER_BUILD', () {
    expect(
      releaseScript,
      contains('--dart-define=TESTER_BUILD=true'),
      reason: 'without it the ⏩ skip-onboarding button is compiled out of the '
          'build testers are given, which is item 61 — and every testing pack '
          'except A starts by using it.',
    );
  });

  test('the tester build still routes through Google', () {
    expect(releaseScript, contains('--dart-define=ROUTING_PREFER_GOOGLE=true'));
  });

  test('emergency dispatch is not switched on by the tester flag', () {
    // Deliberately not carried along with "this is a tester build". A tester
    // enters their real family's numbers, and the voice pack's whole job is
    // saying unexpected things.
    expect(releaseScript, isNot(contains('EMERGENCY_LIVE_DISPATCH=true')));
  });

  test('the release script checks for the Cloud TTS key — item 63', () {
    // It shipped unnoticed through every build because nothing looked for it:
    // with no CLOUD_TTS_API_KEY, CloudTtsConfig silently reuses the STT key,
    // which is restricted to Speech-to-Text, so every synthesis request fails
    // closed and drops to the handset's own engine.
    expect(releaseScript, contains('CLOUD_TTS_API_KEY'));
  });
}
