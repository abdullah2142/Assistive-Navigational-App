// The three controls on the chat input row: map, mic, send.
//
// Two changes are asserted here.
//
// The **map button used to be a bare `IconButton`** — a flat glyph sitting
// between two filled circles, which read as decoration rather than as the
// third control on the row. For a low-vision user scanning a row of controls,
// "same shape, same size" is most of what says "same kind of thing".
//
// The **voice-message chip** is the first discoverable way to reach the
// caretaker-messaging feature. Until it existed the feature was reachable only
// by already knowing a phrase to say, which for a blind user means not
// reachable. It appears only when a caretaker is paired: a chip that is always
// there and fails for most users costs a permanent row of space and reads to a
// screen reader as available before explaining it cannot work.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/features/dashboard/widgets/chat_stream_panel.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  final strings = Dashboard.of(AppLanguage.english);

  Future<void> pumpPanel(
    WidgetTester tester, {
    String? pairedUserId,
    bool mapVisible = false,
    bool withMapToggle = true,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sttServiceProvider.overrideWithValue(_SilentStt())],
        child: MaterialApp(
          home: Scaffold(
            body: ChatStreamPanel(
              onOverlayChip: (_, _) {},
              mapVisible: mapVisible,
              onToggleMap: withMapToggle ? () {} : null,
              profile: UserProfile(
                uid: 'u1',
                role: UserRole.disabledUser,
                pairedUserId: pairedUserId,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The tappable circle behind an icon, as the user sees it.
  Size buttonSize(WidgetTester tester, IconData icon) => tester.getSize(
    find.ancestor(of: find.byIcon(icon), matching: find.byType(InkWell)).first,
  );

  ShapeBorder? buttonShape(WidgetTester tester, IconData icon) => tester
      .widget<Material>(
        find
            .ancestor(of: find.byIcon(icon), matching: find.byType(Material))
            .first,
      )
      .shape;

  group('the map button belongs to the same family as mic and send', () {
    testWidgets('it is a circle, like the other two', (tester) async {
      await pumpPanel(tester);
      expect(buttonShape(tester, Icons.map_outlined), isA<CircleBorder>());
      expect(buttonShape(tester, Icons.mic_rounded), isA<CircleBorder>());
      expect(buttonShape(tester, Icons.send_rounded), isA<CircleBorder>());
    });

    testWidgets('it is the same size as the send button', (tester) async {
      await pumpPanel(tester);
      expect(
        buttonSize(tester, Icons.map_outlined),
        buttonSize(tester, Icons.send_rounded),
      );
    });

    testWidgets('and keeps a 48dp target', (tester) async {
      await pumpPanel(tester);
      final size = buttonSize(tester, Icons.map_outlined);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('on and off are told apart by more than colour', (
      tester,
    ) async {
      // Colour alone is not a state indicator. The icon changes too, and so
      // does the semantics label.
      await pumpPanel(tester, mapVisible: false);
      expect(find.byIcon(Icons.map_outlined), findsOneWidget);

      await pumpPanel(tester, mapVisible: true);
      expect(find.byIcon(Icons.map_rounded), findsOneWidget);
      expect(strings.mapShowSemantics, isNot(strings.mapHideSemantics));
    });

    testWidgets('no toggle means no button, not an inert one', (tester) async {
      await pumpPanel(tester, withMapToggle: false);
      expect(find.byIcon(Icons.map_outlined), findsNothing);
      expect(find.byIcon(Icons.map_rounded), findsNothing);
    });
  });

  group('the voice-message chip', () {
    testWidgets('is absent with no caretaker paired', (tester) async {
      await pumpPanel(tester);
      expect(find.text(strings.chipVoiceMemo), findsNothing);
    });

    testWidgets('appears once a caretaker is paired', (tester) async {
      await pumpPanel(tester, pairedUserId: 'caretaker-1');
      expect(find.text(strings.chipVoiceMemo), findsOneWidget);
    });

    testWidgets('and the other four are still there either way', (
      tester,
    ) async {
      for (final paired in [null, 'caretaker-1']) {
        await pumpPanel(tester, pairedUserId: paired);
        for (final label in [
          strings.chipPath,
          strings.chipCamera,
          strings.chipShowScreen,
          strings.chipReportHazard,
        ]) {
          expect(find.text(label), findsOneWidget, reason: 'paired=$paired');
        }
      }
    });
  });

  testWidgets('typing hides side controls so the composer grows sideways', (
    tester,
  ) async {
    await pumpPanel(tester, pairedUserId: 'caretaker-1');
    final field = find.byType(TextField);
    final compactWidth = tester.getSize(field).width;

    await tester.enterText(field, 'A message for my caretaker');
    await tester.pump();

    expect(find.byIcon(Icons.map_outlined), findsNothing);
    expect(find.byIcon(Icons.mic_rounded), findsNothing);
    expect(find.text('Send image'), findsNothing);
    expect(find.text(strings.chipVoiceMemo), findsNothing);
    expect(tester.getSize(field).width, greaterThan(compactWidth));
    expect(find.byIcon(Icons.send_rounded), findsOneWidget);
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
