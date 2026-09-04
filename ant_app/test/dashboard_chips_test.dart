// The suggested chips are the only discoverable shortcuts on the dashboard.
// They stopped being discoverable when they scrolled sideways.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/dashboard/widgets/suggested_chip_row.dart';

void main() {
  final strings = Dashboard.of(AppLanguage.english);

  Widget host(double width, {double textScale = 1.0}) => MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
            child: Center(
              child: SizedBox(
                width: width,
                child: SuggestedChipRow(
                  chips: kDefaultSuggestedChips,
                  strings: strings,
                  onTap: (_) {},
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('every chip is on screen at once on a 720px phone', (tester) async {
    tester.view.physicalSize = const Size(720, 1650);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(720));
    await tester.pumpAndSettle();

    expect(find.byType(SuggestedChipRow), findsOneWidget);

    final panel = tester.getRect(find.byType(SuggestedChipRow));
    for (final chip in kDefaultSuggestedChips) {
      final label = chip.labelFor(strings);
      final finder = find.text(label);
      expect(finder, findsOneWidget, reason: '"$label" should be rendered');

      final box = tester.getRect(finder);
      expect(
        box.left >= panel.left - 0.5 && box.right <= panel.right + 0.5,
        isTrue,
        reason: '"$label" runs outside the panel — it would need a sideways '
            'drag to reach, which a blind user has no way to discover',
      );
    }
  });

  testWidgets('nothing scrolls horizontally', (tester) async {
    await tester.pumpWidget(host(720));
    await tester.pumpAndSettle();

    final scrollables = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
    );
    expect(
      scrollables,
      findsNothing,
      reason: 'a horizontal scroller here hides chips past the viewport edge',
    );
  });

  testWidgets('chips keep a 48dp touch target at the largest text size', (tester) async {
    await tester.pumpWidget(host(720, textScale: 2.0));
    await tester.pumpAndSettle();

    for (final chip in kDefaultSuggestedChips) {
      final ink = find.ancestor(
        of: find.text(chip.labelFor(strings)),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(ink.first).height, greaterThanOrEqualTo(48.0));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow panel wraps instead of overflowing', (tester) async {
    await tester.pumpWidget(host(220, textScale: 1.6));
    await tester.pumpAndSettle();
    // An unbounded-width Flexible or an overflowing Row would both surface
    // here as a thrown layout exception.
    expect(tester.takeException(), isNull);
  });
}
