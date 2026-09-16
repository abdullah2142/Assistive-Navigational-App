// The suggested chips are the only discoverable shortcuts on the dashboard.
// They stopped being discoverable when they scrolled sideways.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/dashboard/widgets/suggested_chip_row.dart';

void main() {
  _fifthChip();

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

  testWidgets('chips are laid out two per row', (tester) async {
    await tester.pumpWidget(host(720));
    await tester.pumpAndSettle();

    final tops = <double, List<String>>{};
    for (final chip in kDefaultSuggestedChips) {
      final rect = tester.getRect(find.text(chip.labelFor(strings)));
      tops.putIfAbsent(rect.top.roundToDouble(), () => []).add(chip.labelFor(strings));
    }
    expect(tops.length, (kDefaultSuggestedChips.length / 2).ceil(),
        reason: 'expected two rows for four chips, got rows: $tops');
    for (final row in tops.values) {
      expect(row.length, lessThanOrEqualTo(2));
    }
  });

  testWidgets('the two columns are equal width', (tester) async {
    await tester.pumpWidget(host(720));
    await tester.pumpAndSettle();

    final widths = kDefaultSuggestedChips
        .map((c) => tester
            .getSize(find
                .ancestor(of: find.text(c.labelFor(strings)), matching: find.byType(InkWell))
                .first)
            .width)
        .toSet();
    expect(widths.length, 1,
        reason: 'unequal cells make the grid unlearnable by position: $widths');
  });

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

  testWidgets('chip labels contrast against the panel they sit on', (tester) async {
    // Regression: switching the label to a smaller type style silently
    // picked up the theme's dimmed variant colour, rendering these
    // near-invisible on the dark dashboard.
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6D4AC4),
              brightness: brightness,
            ),
          ),
          home: Scaffold(
            body: SuggestedChipRow(
              chips: kDefaultSuggestedChips,
              strings: strings,
              onTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(SuggestedChipRow));
      final scheme = Theme.of(context).colorScheme;

      for (final chip in kDefaultSuggestedChips) {
        final text = tester.widget<Text>(find.text(chip.labelFor(strings)));
        final colour = text.style?.color;
        expect(colour, isNotNull, reason: 'no explicit label colour for $brightness');
        expect(
          _contrast(colour!, scheme.surface),
          greaterThanOrEqualTo(4.5),
          reason: '"${chip.labelFor(strings)}" fails WCAG AA on $brightness',
        );
      }
    }
  });
}

/// WCAG relative-luminance contrast ratio.
double _contrast(Color a, Color b) {
  double channel(double c) => c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = luminance(a), lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

// ---------------------------------------------------------------------------
// The fifth chip — the caretaker voice message.
//
// Added because the feature was reachable only by already knowing a phrase to
// say, which for a blind user means not reachable at all. A chip is the only
// discoverable surface this dashboard has.
//
// Five chips in pairs would be three rows, and a third row of chips eats the
// chat above it — the part users actually read. So the fifth joins the second
// row. It is the *second* row that widens rather than the first, because
// position is the thing this layout exists to make learnable: somebody who
// has learned where "report a hazard" is should still find it there.
void _fifthChip() {
  final strings = Dashboard.of(AppLanguage.english);

  Widget host(List<SuggestedChip> chips, {double width = 720}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SuggestedChipRow(chips: chips, strings: strings, onTap: (_) {}),
            ),
          ),
        ),
      );

  /// Chip labels grouped by the row they render on, top row first.
  ///
  /// Grouped by the *cell*, not by the label inside it. Labels wrap to
  /// different numbers of lines and sit centred in a stretched cell, so two
  /// chips side by side in the same row have different text tops — grouping
  /// on those reports three rows where there are two.
  List<List<String>> rowsOf(WidgetTester tester, List<SuggestedChip> chips) {
    final byTop = <double, List<String>>{};
    for (final chip in chips) {
      final label = chip.labelFor(strings);
      final cell = find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;
      byTop.putIfAbsent(tester.getRect(cell).top.roundToDouble(), () => []).add(label);
    }
    final tops = byTop.keys.toList()..sort();
    return [for (final t in tops) byTop[t]!];
  }

  group('who gets the chip', () {
    test('nobody, until a caretaker is paired', () {
      // A chip that is always there and fails for most users is worse than no
      // chip: it costs a row of space permanently, and for a screen-reader
      // user it reads as available and then explains it cannot work.
      final chips = suggestedChipsFor(caretakerPaired: false);
      expect(chips, kDefaultSuggestedChips);
      expect(chips.map((c) => c.action),
          isNot(contains(SuggestedChipAction.sendCaretakerVoiceMemo)));
    });

    test('once paired, it appears', () {
      final chips = suggestedChipsFor(caretakerPaired: true);
      expect(chips, hasLength(5));
      expect(chips.last.action, SuggestedChipAction.sendCaretakerVoiceMemo);
    });

    test('and it is labelled in both languages', () {
      expect(kVoiceMemoChip.labelFor(Dashboard.of(AppLanguage.english)), 'Voice message');
      expect(kVoiceMemoChip.labelFor(Dashboard.of(AppLanguage.bangla)), isNotEmpty);
    });
  });

  group('where it goes', () {
    test('five chips are two rows, not three', () {
      expect(SuggestedChipRow.rowSizesFor(5), [2, 3]);
    });

    test('four chips are unchanged', () {
      // The layout this replaced. Nothing about the existing dashboard moves.
      expect(SuggestedChipRow.rowSizesFor(4), [2, 2]);
    });

    testWidgets('the fifth joins the second row', (tester) async {
      final chips = suggestedChipsFor(caretakerPaired: true);
      await tester.pumpWidget(host(chips));
      await tester.pumpAndSettle();

      final rows = rowsOf(tester, chips);
      expect(rows, hasLength(2), reason: 'a third row would eat the chat above it');
      expect(rows.first, hasLength(2));
      expect(rows.last, hasLength(3));
    });

    testWidgets('the four existing chips do not move rows', (tester) async {
      // The whole reason the second row is the one that widens.
      final chips = suggestedChipsFor(caretakerPaired: true);
      await tester.pumpWidget(host(chips));
      await tester.pumpAndSettle();

      final rows = rowsOf(tester, chips);
      expect(rows.first, [strings.chipRouteToWork, strings.chipScanBus]);
      expect(rows.last.take(2), [strings.chipShowScreen, strings.chipReportHazard]);
    });

    testWidgets('each row still fills the width, in equal cells', (tester) async {
      final chips = suggestedChipsFor(caretakerPaired: true);
      await tester.pumpWidget(host(chips));
      await tester.pumpAndSettle();

      double cellWidth(String label) => tester
          .getSize(find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first)
          .width;

      final top = [strings.chipRouteToWork, strings.chipScanBus].map(cellWidth).toList();
      final bottom = [strings.chipShowScreen, strings.chipReportHazard, strings.chipVoiceMemo]
          .map(cellWidth)
          .toList();

      expect(top.first, closeTo(top.last, 0.5), reason: 'equal cells within a row');
      expect(bottom[0], closeTo(bottom[1], 0.5));
      expect(bottom[1], closeTo(bottom[2], 0.5));
      // A row of three has narrower cells than a row of two — that is the
      // trade being made, and it should be visible rather than accidental.
      expect(bottom.first, lessThan(top.first));
      // Both rows span the same total width.
      expect(top.reduce((a, b) => a + b) + 10, closeTo(bottom.reduce((a, b) => a + b) + 20, 1));
    });

    testWidgets('every chip keeps a 48dp touch target on a narrow phone', (tester) async {
      // The cells get narrower; the targets must not get shorter.
      final chips = suggestedChipsFor(caretakerPaired: true);
      await tester.pumpWidget(host(chips, width: 320));
      await tester.pumpAndSettle();

      for (final chip in chips) {
        final size = tester.getSize(find
            .ancestor(of: find.text(chip.labelFor(strings)), matching: find.byType(InkWell))
            .first);
        expect(size.height, greaterThanOrEqualTo(48),
            reason: '${chip.labelFor(strings)} is aimed at by feel');
      }
    });
  });
}
