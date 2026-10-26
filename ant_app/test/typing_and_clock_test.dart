// Two defects found on a phone: the chat box closed its keyboard after the
// first letter (the TextField was rebuilt when the side controls vanished),
// and the assistant invented the time because its prompt had no clock.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/features/dashboard/widgets/chat_stream_panel.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  testWidgets('the first keystroke keeps the same text field and its keyboard', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sttServiceProvider.overrideWithValue(_SilentStt())],
        child: MaterialApp(
          home: Scaffold(
            body: ChatStreamPanel(
              onOverlayChip: (_, _) {},
              mapVisible: false,
              onToggleMap: () {},
              profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final before = tester.state(find.byType(EditableText));

    tester.testTextInput.enterText('h');
    await tester.pump();
    expect(identical(before, tester.state(find.byType(EditableText))), isTrue);
    tester.testTextInput.enterText('hi there');
    await tester.pump();
    expect(identical(before, tester.state(find.byType(EditableText))), isTrue);
    expect(tester.testTextInput.hasAnyClients, isTrue);

    tester.testTextInput.enterText('');
    await tester.pump();
    expect(identical(before, tester.state(find.byType(EditableText))), isTrue,
        reason: 'deleting back to empty brings the controls back; same field');
  });

  test('the prompt clock reads the way a person would say it', () {
    expect(
      currentTimeLine(DateTime(2026, 10, 24, 15, 3)),
      contains('Saturday 24 October 2026, 3:03 PM'),
    );
    expect(currentTimeLine(DateTime(2026, 1, 5, 0, 7)), contains('12:07 AM'));
    expect(currentTimeLine(DateTime(2026, 1, 5, 12, 0)), contains('12:00 PM'));
  });
}

class _SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {
    await Completer<void>().future;
  }

  @override
  Future<void> stop() async {}
}
