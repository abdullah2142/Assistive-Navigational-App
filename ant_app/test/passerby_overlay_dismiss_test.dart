// The Show Screen overlay has to survive the touch that was already in
// flight when it appeared, and it has to take its own voice with it when it
// goes.
//
// Reported from the device: "after the voice commands in show screen it
// doesn't actually open the screen but it does when its clicked", then "it
// closed in 1 sec without me doing anything while its narration kept on
// playing on the dashboard". The log showed a two-finger, 15 ms touch
// delivered to the activity in the same frame the overlay pushed:
//
//   ACTION_DOWN             pointerCount=1
//   ACTION_POINTER_DOWN(1)  pointerCount=2
//   ...15ms...
//   ACTION_POINTER_UP(0) / ACTION_UP
//
// The whole body is a dismiss target, so that closed it before `initState`'s
// `await speak(...)` had even returned — which is why the overlay's own log
// lines never appeared at all.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_helper_overlay.dart';

void main() {
  final d = Dashboard.of(AppLanguage.english);
  const message = 'I need help crossing the road';

  Future<_SpyTts> pumpOverlay(WidgetTester tester) async {
    final tts = _SpyTts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ttsServiceProvider.overrideWithValue(tts)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PasserbyHelperOverlay.show(context, message, d, AppLanguage.english),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return tts;
  }

  testWidgets('a tap in the first moments does not close it', (tester) async {
    await pumpOverlay(tester);
    expect(find.text(message), findsOneWidget);

    await tester.tap(find.text(message));
    await tester.pumpAndSettle();

    expect(find.text(message), findsOneWidget, reason: 'the touch that opened it must not close it');
  });

  testWidgets('a tap after the grace window does close it', (tester) async {
    await pumpOverlay(tester);

    await tester.pump(PasserbyHelperOverlay.tapGrace + const Duration(milliseconds: 50));
    await tester.tap(find.text(message));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('the explicit back button is never gated', (tester) async {
    // A press on a specific control is an intention; a touch anywhere on a
    // yellow rectangle is not.
    await pumpOverlay(tester);

    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();

    expect(find.text(message), findsNothing);
  });

  testWidgets('closing it stops its narration', (tester) async {
    // It kept talking on the dashboard after the overlay was gone — telling
    // the user how to use something no longer in front of them.
    final tts = await pumpOverlay(tester);

    await tester.pump(PasserbyHelperOverlay.tapGrace + const Duration(milliseconds: 50));
    await tester.tap(find.text(message));
    await tester.pumpAndSettle();

    expect(tts.stopped, isTrue);
  });
}

class _SpyTts implements TtsService {
  bool stopped = false;

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {}

  @override
  Future<void> stop() async => stopped = true;

  @override
  void setVoiceId(String voiceId) {}
}
