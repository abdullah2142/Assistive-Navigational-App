// Arrival was announced ~200 m early on routes whose straight legs have no
// intermediate points, and at the start when GPS drifted toward the end.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/services/navigation_narrator.dart';
import 'package:ant_app/core/services/routing_service.dart';

LatLng at(double eastMeters, [double northMeters = 0]) => LatLng(
  23.75 + northMeters / 111320,
  90.39 + eastMeters / (111320 * math.cos(23.75 * math.pi / 180)),
);

void main() {
  RouteStep step(double e, double n, ManeuverKind kind) =>
      RouteStep(distanceMeters: 0, location: at(e, n), maneuver: kind);

  test('a sparse 1 km straight leg: no arrival until you are at the end', () {
    final n = NavigationNarrator(
      steps: [step(1000, 0, ManeuverKind.arrive)],
      routePoints: [at(0), at(1000)],
    );
    for (var m = 0.0; m < 970; m += 10) {
      expect(n.update(at(m))?.kind, isNot(NavigationCueKind.arrived), reason: '$m m');
    }
    expect(n.update(at(1000))?.kind, NavigationCueKind.arrived);
  });

  test('GPS drifting to the far end at the start does not arrive', () {
    final n = NavigationNarrator(
      steps: [step(0, 800, ManeuverKind.right), step(300, 800, ManeuverKind.arrive)],
      routePoints: [at(0), at(0, 800), at(300, 800)],
    );
    // Straight-line the destination is ~300 m away across the road, but the
    // walk to it is 1100 m: standing 20 m from the end of the polyline's
    // last point while still at the start must not count.
    expect(n.update(at(0, 5))?.kind, isNot(NavigationCueKind.arrived));
    expect(n.hasArrived, isFalse);
  });
}
