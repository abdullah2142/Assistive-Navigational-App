// The map's half of a planned route.
//
// Two reported problems live here. A route arriving has to *reveal* the map
// — it is hidden by default, because most of this app's users cannot see it,
// but asking to be taken somewhere is the one moment it has something to say
// (that behaviour shipped without a test; this is it). And what it shows once
// revealed used to be a 56dp north arrow rotated to the route's initial
// bearing and never updated: "that stupid big arrow is confusing, i wanna see
// the route lines as well like in google maps, as well as info about how far
// to go in which direction."

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/services/emergency_service.dart';
import 'package:ant_app/core/services/navigation_narrator.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/providers/chat_providers.dart';
import 'package:ant_app/features/dashboard/screens/split_mode_dashboard_screen.dart';
import 'package:ant_app/features/dashboard/widgets/dashboard_map_panel.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  const safe = SafetyVerdict(safe: true, riskScore: 1, threshold: 7, dangerousThanaNames: []);

  RouteChoice routeTo(String label, {SafetyVerdict verdict = safe, String via = 'Satmasjid Road'}) => RouteChoice(
        destinationLabel: label,
        points: const [LatLng(23.7461, 90.3742), LatLng(23.7550, 90.3800), LatLng(23.7600, 90.3900)],
        distanceMeters: 1240,
        durationSeconds: 900,
        initialBearingDegrees: 40,
        viaSummary: via,
        verdict: verdict,
        wasRerouted: false,
        steps: const [
          RouteStep(
            location: LatLng(23.7550, 90.3800),
            distanceMeters: 250,
            maneuver: ManeuverKind.left,
            streetName: 'Satmasjid Road',
          ),
          RouteStep(
            location: LatLng(23.7600, 90.3900),
            distanceMeters: 990,
            maneuver: ManeuverKind.arrive,
          ),
        ],
      );

  /// Pumps the dashboard with a controller a test can push a route into,
  /// which is the piece that was missing when this behaviour shipped
  /// untested.
  Future<_Harness> pumpDashboard(WidgetTester tester, {EmergencyService? emergency}) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        chatControllerProvider.overrideWith(_TestChatController.new),
        if (emergency != null) emergencyServiceProvider.overrideWithValue(emergency),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: SplitModeDashboardScreen(
            profile: UserProfile(uid: 'user-1', role: UserRole.disabledUser),
          ),
        ),
      ),
    );
    await tester.pump();
    return _Harness(container);
  }

  testWidgets('a planned route reveals the map on its own', (tester) async {
    final harness = await pumpDashboard(tester);
    expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);

    harness.publish(routeTo('Labaid'));
    await tester.pump();

    expect(find.byType(DashboardMapPanel), findsOneWidget);
  });

  testWidgets('hiding the map again is not overruled by the same route', (tester) async {
    // Only ever opens it, never closes it — somebody who deliberately hid
    // the map should not have it forced back on the next rebuild.
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo('Labaid'));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.map_rounded));
    await tester.pump();
    expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);

    // A rebuild with the same route still in state must not reopen it.
    harness.touch();
    await tester.pump();
    expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);
  });

  // "Map should close if user says the trip is cancelled, right now it remains
  // still." The listener above only ever *opened* the map, on the reasoning
  // that somebody who deliberately hid it should not be overruled — right for
  // a rebuild, wrong for a cancellation. A map showing nothing is a map taking
  // half the screen for nothing.
  //
  // The fix shipped without a test, like the reveal above it did.
  group('cancelling the trip', () {
    testWidgets('closes the map', (tester) async {
      final harness = await pumpDashboard(tester);
      harness.publish(routeTo('Dhaka'));
      await tester.pump();
      expect(find.byType(DashboardMapPanel), findsOneWidget);

      harness.cancelTrip();
      await tester.pump();

      expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);
    });

    testWidgets('and does not leave it full-screen for the next route', (tester) async {
      // The listener clears `_mapFullScreen` alongside `_mapVisible`. Without
      // that, the next route to arrive reopens the map straight into
      // full-screen, having swallowed the chat, with nothing explaining why.
      final harness = await pumpDashboard(tester);
      harness.publish(routeTo('Dhaka'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.fullscreen_rounded));
      await tester.pump();

      harness.cancelTrip();
      await tester.pump();
      expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);

      harness.publish(routeTo('Gulshan'));
      await tester.pump();
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget,
          reason: 'back to split, not still expanded');
    });

    testWidgets('is harmless when the map was already hidden', (tester) async {
      final harness = await pumpDashboard(tester);
      harness.publish(routeTo('Dhaka'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.map_rounded));
      await tester.pump();

      harness.cancelTrip();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);
    });

    testWidgets('an SOS does not wait on the location fix first', (tester) async {
      // Reported as "Emergency, SOS, Save me — reply dite koyek second time
      // nicche". The phrase matches locally in milliseconds, but the dispatch
      // sat behind a cached-GPS lookup it never reads: `EmergencyService`
      // fetches its own position later, on its own budget.
      //
      // One pump, no clock advanced. If the location wait is ever put back in
      // front of this, nothing will have happened by now and the test fails.
      final fake = _FakeEmergency();
      final harness = await pumpDashboard(tester, emergency: fake);

      unawaited(harness.say('save me'));
      await tester.pump();

      expect(harness.lastUserMessage, 'save me');
      expect(fake.triggered, isTrue,
          reason: 'dispatched on the first pump, with no clock advanced — if '
              'the location wait is ever put back in front of this, nothing '
              'will have happened yet');
    });

    testWidgets('end to end, from the words the user actually says', (tester) async {
      // The three links, in one test: "cancel the trip" matches `cancel_route`
      // locally (so it never reaches Gemini), `ChatController._cancelRoute`
      // clears the route, and the dashboard's listener closes the map. Each
      // link was covered on its own and the chain was not, which is how a
      // reply saying "cancelled your trip" shipped next to a map still drawing
      // the route.
      final harness = await pumpDashboard(tester);
      harness.publish(routeTo('Dhaka'));
      await tester.pump();
      expect(find.byType(DashboardMapPanel), findsOneWidget);

      unawaited(harness.say('cancel the trip to Dhaka'));
      // Past the cached-fix budget `sendFreeText` waits out, then the 300ms
      // `_appendAssistantReply` delay.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(find.byType(DashboardMapPanel, skipOffstage: false), findsNothing);
      expect(harness.routeInState, isNull, reason: 'the route is gone, not just hidden');
    });

    testWidgets('a later route opens it again', (tester) async {
      // Closing on cancel must not be sticky — the next trip still reveals it.
      final harness = await pumpDashboard(tester);
      harness.publish(routeTo('Dhaka'));
      await tester.pump();
      harness.cancelTrip();
      await tester.pump();

      harness.publish(routeTo('Gulshan'));
      await tester.pump();

      expect(find.byType(DashboardMapPanel), findsOneWidget);
    });
  });

  testWidgets('the map shows how far is left and which way to turn', (tester) async {
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo('Labaid'));
    await tester.pump();

    // Before any GPS fix: the destination and the whole distance, rather
    // than a blank panel or a bare arrow.
    expect(find.textContaining('Heading to Labaid'), findsOneWidget);
    expect(find.textContaining('1.2 km left'), findsOneWidget);
    expect(find.textContaining('Satmasjid Road'), findsOneWidget);
  });

  testWidgets('the banner follows the walk once fixes arrive', (tester) async {
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo('Labaid'));
    await tester.pump();

    harness.walkTo(const NavigationProgress(
      maneuver: ManeuverKind.left,
      streetName: 'Satmasjid Road',
      metersToManeuver: 250,
      metersRemaining: 940,
    ));
    await tester.pump();

    expect(find.text('250 m'), findsOneWidget);
    expect(find.text('Turn left onto Satmasjid Road'), findsOneWidget);
    expect(find.text('940 m left'), findsOneWidget);
    // Not "940 m left · Satmasjid Road" — the via identifies the route, and
    // repeating it on the line under "Turn left onto Satmasjid Road" says
    // the same road name twice.
    expect(find.textContaining('940 m left · '), findsNothing);
    // The turn is an actual turn arrow, not a compass rose the viewer has to
    // subtract their own heading from.
    expect(find.byIcon(Icons.turn_left_rounded), findsOneWidget);
  });

  testWidgets('coming off the route says so rather than pointing somewhere', (tester) async {
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo('Labaid'));
    await tester.pump();

    harness.walkTo(const NavigationProgress(offRoute: true, metersRemaining: 900));
    await tester.pump();

    expect(find.text('Off the route'), findsOneWidget);
  });

  testWidgets('the whole banner is one screen-reader sentence', (tester) async {
    // Four separate labels — "turn left", "250 m", "940 m left", "Labaid" —
    // read as four unrelated stops. One sentence is the same thing the app
    // would say out loud.
    final handle = tester.ensureSemantics();
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo('Labaid'));
    await tester.pump();
    harness.walkTo(const NavigationProgress(
      maneuver: ManeuverKind.left,
      streetName: 'Satmasjid Road',
      metersToManeuver: 250,
      metersRemaining: 940,
    ));
    await tester.pump();

    expect(
      find.bySemanticsLabel(RegExp(
        r'In 250 metres, turn left onto Satmasjid Road\. '
        r'Heading to Labaid via Satmasjid Road — 940 metres to go\.',
      )),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('an unsafe route is still shown, and says it is unsafe', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await pumpDashboard(tester);
    harness.publish(routeTo(
      'Labaid',
      verdict: const SafetyVerdict(safe: false, riskScore: 9, threshold: 7, dangerousThanaNames: ['X']),
    ));
    await tester.pump();

    expect(find.bySemanticsLabel(RegExp('still passes a risky area')), findsOneWidget);
    handle.dispose();
  });
}

class _Harness {
  _Harness(this.container);
  final ProviderContainer container;

  _TestChatController get _controller =>
      container.read(chatControllerProvider.notifier) as _TestChatController;

  void publish(RouteChoice route) => _controller.publish(route);

  /// What `ChatController._cancelRoute` does to the state — the route goes
  /// away, which is the signal the dashboard listens for.
  void cancelTrip() => _controller.cancelTrip();

  /// Sends a message the way the user does, through the real pipeline.
  Future<void> say(String text) => _controller.sendFreeText(
        text,
        UserProfile(uid: 'user-1', role: UserRole.disabledUser),
      );

  RouteChoice? get routeInState => container.read(chatControllerProvider).pendingRoute;

  String? get lastUserMessage => container
      .read(chatControllerProvider)
      .messages
      .where((m) => m.sender == ChatSender.user)
      .lastOrNull
      ?.text;


  /// A rebuild that changes something other than the route.
  void touch() => _controller.touch();

  void walkTo(NavigationProgress progress) =>
      container.read(navigationControllerProvider).progress.value = progress;
}

/// The real controller, with a door to push a planned route through.
///
/// Overriding the notifier rather than faking the whole panel keeps the test
/// on the actual `ref.listen` in `SplitModeDashboardScreen.build` — which is
/// the thing that was never covered.
class _TestChatController extends ChatController {
  void publish(RouteChoice route) => state = state.copyWith(pendingRoute: route);

  void cancelTrip() => state = state.copyWith(clearRoute: true);

  void touch() => state = state.copyWith(isAssistantTyping: !state.isAssistantTyping);
}

/// Stands in for the real escalation, which reaches Firestore through
/// `AlertService` the moment it is constructed.
class _FakeEmergency implements EmergencyService {
  bool triggered = false;

  @override
  Future<EmergencyOutcome> trigger({required UserProfile profile, bool confirm = true}) async {
    triggered = true;
    return const EmergencyOutcome(cancelled: false);
  }

  @override
  bool get isRunning => false;
}
