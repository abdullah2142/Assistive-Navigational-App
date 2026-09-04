import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'routing_service.dart';

/// Decides what to say, and when, as the user walks a route.
///
/// Deliberately a pure state machine over `(route steps, current position)`
/// with no GPS subscription, no text-to-speech and no timers of its own —
/// all of which live in `NavigationController`. Turn-by-turn guidance for
/// someone who cannot see the road is the highest-consequence thing this
/// app says out loud, and it needs to be testable by walking a synthetic
/// track past a synthetic route rather than only by taking a phone outside.
///
/// ## The two failure modes it is built around
///
/// **Saying too little** is dangerous: a missed turn leaves a blind user
/// walking confidently in the wrong direction, which is worse than not
/// having started.
///
/// **Saying too much** is also dangerous, and much easier to do by
/// accident: an assistant that re-announces the same turn every GPS tick
/// becomes noise the user learns to tune out, and it is talking over the
/// ambient sound — traffic, horns, other people — that a blind pedestrian
/// is actually navigating by. Every announcement here therefore has to earn
/// itself: each turn is announced at most once per distance band, and
/// nothing is repeated while the situation has not changed.
class NavigationNarrator {
  NavigationNarrator({required this.steps, this.routePoints = const []});

  final List<RouteStep> steps;

  /// The route's full geometry, used for the off-route corridor check.
  ///
  /// Manoeuvre points alone are the wrong data for "am I still on the
  /// road": they are only the corners. A straight 300 m leg has its
  /// manoeuvre at the far end, and the origin is not a corner at all, so a
  /// user standing exactly at the start of a correct route measured 300 m
  /// from the nearest manoeuvre and was told they had gone the wrong way
  /// before taking a single step. The polyline is every point of the actual
  /// path, which is what the question was always about.
  ///
  /// Optional — with none supplied the check falls back to manoeuvre
  /// points, which is imprecise but better than not noticing a missed turn
  /// at all.
  final List<LatLng> routePoints;

  /// Index of the manoeuvre currently being walked toward.
  int _current = 0;
  int get currentStepIndex => _current;

  /// Which distance band was last announced for [_current]. Announcing the
  /// same turn twice in one band is the "talking too much" failure; skipping
  /// a band because GPS jumped is fine, the next band still fires.
  _Band? _announcedBand;

  bool _arrived = false;
  bool get hasArrived => _arrived;

  /// Distance at which a manoeuvre counts as reached and guidance advances
  /// to the next one.
  ///
  /// **Must stay strictly below the nearest band in [announceBands]**, and
  /// that is not a style preference — it is the difference between the app
  /// giving the turn instruction and never giving it. With a 20 m reached
  /// radius against a 15 m imminent band, the narrator advanced past every
  /// manoeuvre before the band could fire, so "Now, turn left" was
  /// unreachable code: the user got the two warnings and then silence at
  /// the actual corner. Caught by a test that walked the route in 10 m
  /// increments and found the third cue was another warning.
  static const double reachedRadiusMeters = 15;

  /// How far off the route the user has to be before it counts as going
  /// wrong. Wide enough not to fire on GPS noise or on walking the far side
  /// of a road, tight enough to catch a genuinely missed turn.
  static const double offRouteMeters = 45;

  /// Distance bands each manoeuvre is announced in, far to near.
  ///
  /// Three, not a continuous countdown: "in 200 metres, turn left" gives
  /// time to prepare, "in 50 metres" gives time to slow down, and "turn left
  /// now" is the instruction itself. A continuous stream of decreasing
  /// numbers is the noise failure above, and metres-remaining is not
  /// something a walking person can act on anyway.
  /// The nearest band is 25 m rather than something tighter for two
  /// reasons: it has to clear [reachedRadiusMeters] (see above), and a
  /// pedestrian using a cane needs a few seconds to find the corner —
  /// "now" arriving slightly early is far kinder than arriving level with
  /// a turn they cannot see.
  static const List<double> announceBands = [200, 50, 25];

  /// The next thing to say, or null when nothing has changed enough to be
  /// worth saying. Call on every position update.
  NavigationCue? update(LatLng position) {
    if (_arrived || steps.isEmpty) return null;

    _advancePast(position);

    if (_current >= steps.length) {
      _arrived = true;
      return const NavigationCue(kind: NavigationCueKind.arrived);
    }

    final step = steps[_current];
    final remaining = _distanceMeters(position, step.location);

    if (_isOffRoute(position)) {
      // Reported once per departure, not per tick — `_announcedBand` is
      // reused as the "already said something about this step" latch.
      if (_announcedBand == _Band.offRoute) return null;
      _announcedBand = _Band.offRoute;
      return NavigationCue(
        kind: NavigationCueKind.offRoute,
        step: step,
        distanceMeters: remaining,
      );
    }

    final band = _bandFor(remaining);
    if (band == null || band == _announcedBand) return null;
    // Only ever announce a *nearer* band than the last one for this step,
    // so a GPS fix that jitters backward across a boundary doesn't re-issue
    // an instruction the user already acted on.
    if (_announcedBand != null && band.index <= _announcedBand!.index) return null;
    _announcedBand = band;

    return NavigationCue(
      kind: band == _Band.imminent ? NavigationCueKind.turnNow : NavigationCueKind.turnAhead,
      step: step,
      distanceMeters: remaining,
      isFinalStep: _current == steps.length - 1,
    );
  }

  /// Advances past every manoeuvre the user has already gone by.
  ///
  /// Proximity alone is not enough, and assuming it was left a real hole:
  /// a step only counted as reached while the user was *within*
  /// [reachedRadiusMeters] of it, so a dropped fix (an underpass, a tunnel,
  /// a phone in a pocket losing signal) that returned with the user well
  /// past a corner left guidance stuck on a turn they had already made,
  /// forever. Progress is therefore measured along the route itself: find
  /// the point on the path the user is nearest to, and retire every
  /// manoeuvre that sits behind it. Proximity is kept as a second condition
  /// so this still works when no geometry was supplied.
  void _advancePast(LatLng position) {
    final userIndex = _nearestPathIndex(position);
    while (_current < steps.length) {
      final reached = _distanceMeters(position, steps[_current].location) <= reachedRadiusMeters;
      final passed = userIndex != null && (_stepPathIndex(_current) ?? -1) <= userIndex;
      if (!reached && !passed) break;
      _current++;
      _announcedBand = null;
    }
  }

  List<int>? _stepPathIndexCache;

  /// Index into [routePoints] of the vertex nearest each manoeuvre.
  /// Computed once — the route does not move.
  int? _stepPathIndex(int stepIndex) {
    if (routePoints.length < 2) return null;
    _stepPathIndexCache ??= [
      for (final step in steps) _nearestPathIndex(step.location) ?? 0,
    ];
    return _stepPathIndexCache![stepIndex];
  }

  int? _nearestPathIndex(LatLng position) {
    if (routePoints.length < 2) return null;
    var bestIndex = 0;
    var best = double.infinity;
    for (var i = 0; i < routePoints.length; i++) {
      final d = _distanceMeters(position, routePoints[i]);
      if (d < best) {
        best = d;
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  /// Whether the user has strayed outside the route corridor — the shortest
  /// distance from them to any segment of the path, not to any corner of it.
  /// See [routePoints].
  bool _isOffRoute(LatLng position) => _distanceToPathMeters(position) > offRouteMeters;

  double _distanceToPathMeters(LatLng position) {
    final path = routePoints.length >= 2
        ? routePoints
        : [for (final step in steps) step.location];
    if (path.isEmpty) return 0;
    if (path.length == 1) return _distanceMeters(position, path.first);
    var nearest = double.infinity;
    for (var i = 0; i + 1 < path.length; i++) {
      nearest = math.min(nearest, _distanceToSegmentMeters(position, path[i], path[i + 1]));
      if (nearest <= offRouteMeters) return nearest; // early out, this runs per GPS tick
    }
    return nearest;
  }

  _Band? _bandFor(double remaining) {
    if (remaining <= announceBands[2]) return _Band.imminent;
    if (remaining <= announceBands[1]) return _Band.near;
    if (remaining <= announceBands[0]) return _Band.approaching;
    return null;
  }
}

/// Ordered far-to-near so a band can only ever be superseded by a nearer
/// one — see the jitter guard in [NavigationNarrator.update].
enum _Band { approaching, near, imminent, offRoute }

enum NavigationCueKind { turnAhead, turnNow, offRoute, arrived }

/// One thing worth saying out loud. Deliberately carries no text: phrasing
/// is localized in `dashboard_strings.dart`, and the haptic pattern that
/// goes with it is the caller's decision.
class NavigationCue {
  const NavigationCue({
    required this.kind,
    this.step,
    this.distanceMeters = 0,
    this.isFinalStep = false,
  });

  final NavigationCueKind kind;
  final RouteStep? step;
  final double distanceMeters;

  /// True when [step] is the last manoeuvre — lets the caller say "your
  /// destination is on the left" instead of a bare "turn left".
  final bool isFinalStep;
}

const double _earthRadiusM = 6371008.8;

double _toRadians(double deg) => deg * math.pi / 180;

/// Great-circle distance in metres.
double _distanceMeters(LatLng a, LatLng b) {
  final dLat = _toRadians(b.latitude - a.latitude);
  final dLng = _toRadians(b.longitude - a.longitude);
  final lat1 = _toRadians(a.latitude);
  final lat2 = _toRadians(b.latitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.sin(dLng / 2) * math.sin(dLng / 2) * math.cos(lat1) * math.cos(lat2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Perpendicular distance from [p] to the segment [a]-[b], in metres.
///
/// Projected onto a local flat plane (metres east/north of `a`) before the
/// point-to-segment maths. Over the tens-of-metres distances this is used
/// for, the error from ignoring curvature is far below GPS accuracy, and it
/// avoids doing spherical geometry for a corridor check.
double _distanceToSegmentMeters(LatLng p, LatLng a, LatLng b) {
  final latScale = 111320.0;
  final lngScale = 111320.0 * math.cos(_toRadians(a.latitude));
  final px = (p.longitude - a.longitude) * lngScale;
  final py = (p.latitude - a.latitude) * latScale;
  final bx = (b.longitude - a.longitude) * lngScale;
  final by = (b.latitude - a.latitude) * latScale;

  final lengthSquared = bx * bx + by * by;
  if (lengthSquared == 0) return math.sqrt(px * px + py * py);
  // Clamped so the projection can't run off either end of the segment.
  final t = ((px * bx + py * by) / lengthSquared).clamp(0.0, 1.0);
  final dx = px - t * bx;
  final dy = py - t * by;
  return math.sqrt(dx * dx + dy * dy);
}
