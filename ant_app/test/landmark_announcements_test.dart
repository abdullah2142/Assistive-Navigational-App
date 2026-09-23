import 'package:ant_app/core/services/navigation_narrator.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

/// Backlog item 3 — "should warn when bus stop or crossing or intersection
/// is near". A crossing is a manoeuvre and arrives in the route geometry; a
/// bus stop is neither and has to be searched for, so both are carried as
/// landmarks and announced by proximity.
void main() {
  // ~111m per 0.001 degrees of latitude near the equator.
  LatLng at(double metresNorth) => LatLng(23.8 + metresNorth / 111000, 90.4);

  RouteStep step(double metresNorth) => RouteStep(
        location: at(metresNorth),
        distanceMeters: metresNorth,
        maneuver: ManeuverKind.left,
      );

  NavigationNarrator narrator({List<Landmark> landmarks = const []}) =>
      NavigationNarrator(steps: [step(1000)], landmarks: landmarks);

  test('a landmark is announced when it comes within range', () {
    final n = narrator(landmarks: [
      Landmark(location: at(100), kind: LandmarkKind.busStop, name: 'Kalabagan'),
    ]);
    expect(n.update(at(0))?.kind, isNot(NavigationCueKind.landmarkAhead),
        reason: '100m away is too far to mention');
    final cue = n.update(at(80));
    expect(cue?.kind, NavigationCueKind.landmarkAhead);
    expect(cue!.landmark!.name, 'Kalabagan');
    expect(cue.landmark!.kind, LandmarkKind.busStop);
  });

  test('and only once, however long the user stands beside it', () {
    // The failure this latch exists for: somebody waiting at a stop for a
    // bus, being told about the stop on every GPS tick.
    final n = narrator(landmarks: [
      Landmark(location: at(100), kind: LandmarkKind.busStop),
    ]);
    expect(n.update(at(80))?.kind, NavigationCueKind.landmarkAhead);
    for (var i = 0; i < 10; i++) {
      expect(n.update(at(95))?.kind, isNot(NavigationCueKind.landmarkAhead));
    }
  });

  test('the nearest of two together is the one named', () {
    final n = narrator(landmarks: [
      Landmark(location: at(120), kind: LandmarkKind.busStop, name: 'far'),
      Landmark(location: at(100), kind: LandmarkKind.busStop, name: 'near'),
    ]);
    expect(n.update(at(100))!.landmark!.name, 'near');
  });

  test('both are announced as the user walks past them in turn', () {
    final n = narrator(landmarks: [
      Landmark(location: at(100), kind: LandmarkKind.busStop, name: 'first'),
      Landmark(location: at(300), kind: LandmarkKind.crossing, name: 'second'),
    ]);
    expect(n.update(at(100))!.landmark!.name, 'first');
    expect(n.update(at(300))!.landmark!.name, 'second');
  });

  test('a crossing outranks the turn band it shares a position with', () {
    // Stepping into a Dhaka road is not the same class of event as turning
    // a corner, so the crossing is checked before the manoeuvre bands.
    final n = NavigationNarrator(
      steps: [step(200)],
      landmarks: [Landmark(location: at(200), kind: LandmarkKind.crossing)],
    );
    expect(n.update(at(180))?.kind, NavigationCueKind.landmarkAhead);
  });

  test('landmarks found after setting off are still announced', () {
    // Bus stops arrive from an Overpass round trip that must not hold up the
    // start of the journey.
    final n = narrator();
    expect(n.update(at(80))?.kind, isNot(NavigationCueKind.landmarkAhead));
    n.addLandmarks([Landmark(location: at(100), kind: LandmarkKind.busStop)]);
    expect(n.update(at(90))?.kind, NavigationCueKind.landmarkAhead);
  });

  test('adding none changes nothing', () {
    final n = narrator(landmarks: [
      Landmark(location: at(100), kind: LandmarkKind.busStop),
    ]);
    n.addLandmarks(const []);
    expect(n.update(at(90))?.kind, NavigationCueKind.landmarkAhead);
  });

  test('a route with no landmarks narrates exactly as before', () {
    final n = narrator();
    for (final m in [0.0, 400.0, 800.0]) {
      expect(n.update(at(m))?.kind, isNot(NavigationCueKind.landmarkAhead));
    }
  });
}
