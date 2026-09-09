// Regression tests for the Split-Mode Dashboard's body layout.
//
// The live bug these lock down: `Visibility(maintainState: true, child:
// Expanded(...))` inside the body `Column`. `Expanded` is a
// ParentDataWidget that must be a *direct* child of a Flex; wrapping it
// throws "Incorrect use of ParentDataWidget" and the whole body subtree
// fails to render, leaving a black dashboard under a working AppBar.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/dashboard/screens/split_mode_dashboard_screen.dart';
import 'package:ant_app/features/dashboard/widgets/chat_stream_panel.dart';
import 'package:ant_app/features/dashboard/widgets/dashboard_map_panel.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  Future<void> pumpDashboard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: SplitModeDashboardScreen(
            profile: UserProfile(uid: 'user-1', role: UserRole.disabledUser),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Turns the map on. It is hidden by default, so every layout test needs
  /// this first.
  Future<void> showMap(WidgetTester tester) async {
    // The toggle lives beside the mic on the input bar now, not in the app
    // bar's far corner — that was the furthest point on screen from a thumb
    // already resting on that row.
    await tester.tap(find.byIcon(Icons.map_outlined));
    await tester.pump();
  }

  testWidgets('body renders without a ParentDataWidget error', (tester) async {
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(ChatStreamPanel), findsOneWidget);

    await showMap(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(DashboardMapPanel), findsOneWidget);
  });

  // A route arriving reveals the map on its own — covered in
  // `dashboard_route_panel_test.dart`, which owns the RouteChoice fixture and
  // the controller override that needs.
  testWidgets('the map is hidden by default and the chat owns the body', (tester) async {
    // The dashboard is for users who cannot see the map. Handing it half the
    // screen before anyone asks takes room from the part they actually use.
    await pumpDashboard(tester);

    final bodyHeight = tester.getSize(find.byType(SafeArea).first).height;

    expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);
    expect(tester.getSize(find.byType(ChatStreamPanel)).height, closeTo(bodyHeight, 1.0));
  });

  testWidgets('showing the map splits the body ~60/40', (tester) async {
    await pumpDashboard(tester);
    await showMap(tester);

    final bodyHeight = tester.getSize(find.byType(SafeArea).first).height;
    final chatHeight = tester.getSize(find.byType(ChatStreamPanel)).height;
    final mapHeight = tester.getSize(find.byType(DashboardMapPanel)).height;

    // The map gets what is left after the chat and the drag handle between
    // them — see `_SplitHandle`, which is what makes the split adjustable.
    expect(chatHeight, closeTo(bodyHeight * 0.6, 1.0));
    expect(mapHeight, closeTo(bodyHeight * 0.4 - 24, 1.0));
  });

  testWidgets('hiding the map keeps the same chat panel State', (tester) async {
    // Toggling moves the panel between an Expanded and a SizedBox — a
    // different widget type in the same slot. Without the GlobalKey the
    // element is discarded and rebuilt, dropping the wake-word/STT session
    // and the chat scroll position every single time.
    await pumpDashboard(tester);
    final before = tester.state(find.byType(ChatStreamPanel));

    await showMap(tester);
    expect(tester.state(find.byType(ChatStreamPanel)), same(before));

    await tester.tap(find.byIcon(Icons.map_rounded));
    await tester.pump();
    expect(tester.state(find.byType(ChatStreamPanel)), same(before));
  });

  testWidgets('hiding a full-screen map does not leave it full-screen next time', (tester) async {
    await pumpDashboard(tester);
    await showMap(tester);
    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pump();

    // Collapse first: with the map full-screen the chat is offstage, and the
    // map toggle now lives on the chat's input bar rather than in the app
    // bar. The full-screen map keeps its own collapse control for exactly
    // this reason.
    await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
    await tester.pump();

    // Hide while collapsed, then show again — it must come back as a split,
    // not full-screen with no chat and no obvious way out.
    await tester.tap(find.byIcon(Icons.map_rounded));
    await tester.pump();
    await showMap(tester);

    final bodyHeight = tester.getSize(find.byType(SafeArea).first).height;
    expect(
      tester.getSize(find.byType(DashboardMapPanel)).height,
      closeTo(bodyHeight * 0.4 - 24, 1.0),
    );
  });

  testWidgets('expanding the map gives it the full body while the chat stays mounted', (tester) async {
    await pumpDashboard(tester);
    await showMap(tester);

    final bodyHeight = tester.getSize(find.byType(SafeArea).first).height;

    await tester.tap(find.byIcon(Icons.fullscreen_rounded));
    await tester.pump();
    expect(tester.takeException(), isNull);

    // The map now owns the whole body...
    expect(tester.getSize(find.byType(DashboardMapPanel)).height, closeTo(bodyHeight, 1.0));
    // ...while the chat panel is still in the tree (its STT/wake-word
    // session and scroll position survive), just not taking any room.
    expect(find.byType(ChatStreamPanel, skipOffstage: false), findsOneWidget);
    expect(find.byType(ChatStreamPanel), findsNothing); // offstage => not visible

    // And collapsing restores the split.
    await tester.tap(find.byIcon(Icons.fullscreen_exit_rounded));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(DashboardMapPanel)).height,
      closeTo(bodyHeight * 0.4 - 24, 1.0),
    );
  });

  testWidgets('the split can be dragged', (tester) async {
    // Reported: the map should not be stuck at a fixed share of the screen.
    final handle = tester.ensureSemantics();
    await pumpDashboard(tester);
    await showMap(tester);

    final bodyHeight = tester.getSize(find.byType(SafeArea).first).height;
    final before = tester.getSize(find.byType(DashboardMapPanel)).height;

    await tester.drag(
      find.bySemanticsLabel(RegExp('Resize the map')),
      const Offset(0, -120),
    );
    await tester.pump();

    final after = tester.getSize(find.byType(DashboardMapPanel)).height;
    expect(after, greaterThan(before), reason: 'dragging up gives the map more room');
    expect(after, lessThan(bodyHeight), reason: 'and never all of it');
    handle.dispose();
  });
}
