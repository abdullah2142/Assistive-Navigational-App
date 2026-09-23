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
  NavigationNarrator({
    required this.steps,
    this.routePoints = const [],
    List<Landmark> landmarks = const [],
  }) : _landmarks = List.unmodifiable(landmarks);


  final List<RouteStep> steps;

  /// Things beside the route worth naming as they come up — a bus stop, a
  /// pedestrian crossing.
  ///
  /// Asked for as "should warn when bus stop or crossing or intersection is
  /// near". Crossings already arrive as `ManeuverKind.crossing` steps and are
  /// announced by the turn bands; a bus stop is not a manoeuvre and appears
  /// in no route geometry at all, so it has to be carried separately.
  ///
  /// Held here rather than in `NavigationController` because "how close is
  /// close enough, and has this one been said already" is exactly the
  /// bookkeeping this class exists to keep testable without a phone.
  List<Landmark> _landmarks;

  /// Adds landmarks found after the journey started — bus stops arrive from
  /// an Overpass round trip that must not hold up setting off.
  ///
  /// Appends rather than replaces, so the crossings handed in at
  /// construction survive, and the announced-set is keyed by index into the
  /// same growing list.
  void addLandmarks(List<Landmark> more) {
    if (more.isEmpty) return;
    _landmarks = List.unmodifiable([..._landmarks, ...more]);
  }

  /// Which landmarks have been announced. One each, for the whole journey —
  /// a bus stop re-announced every GPS tick as the user waits beside it is
  /// the noise failure this class is built around.
  final Set<int> _announcedLandmarks = {};

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

  /// How close a landmark has to be before it is worth naming.
  ///
  /// Wider than [reachedRadiusMeters] and narrower than the first turn band:
  /// a bus stop is useful to know about while it is still ahead of you and
  /// useless once it is behind, and GPS in a Dhaka street will not reliably
  /// resolve better than this anyway.
  static const double landmarkRadiusMeters = 40;

  /// The next thing to say, or null when nothing has changed enough to be
  /// worth saying. Call on every position update.
  NavigationCue? update(LatLng position) {
    if (_arrived || steps.isEmpty) return null;

    _advancePast(position);

    if (_current >= steps.length) {
      _arrived = true;
      return const NavigationCue(kind: NavigationCueKind.arrived);
    }

    // Checked before the manoeuvre bands. A crossing the user is walking
    // into outranks the turn that comes after it, and a bus stop is only
    // information while they are still short of it.
    final landmark = _landmarkNear(position);
    if (landmark != null) return landmark;

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

  /// Where the walk currently stands, for anything that has to *show* the
  /// route rather than speak it.
  ///
  /// Read-only and safe to call as often as the caller likes — it never
  /// advances the state machine or latches an announcement band, so the map
  /// can render every frame without changing what gets said. That
  /// separation is the whole reason [update] can stay as terse as it is:
  /// speech has to earn each utterance, a display does not.
  ///
  /// Call it after [update] so it reflects the same fix.
  NavigationProgress progressAt(LatLng position) {
    if (_arrived || steps.isEmpty || _current >= steps.length) {
      return const NavigationProgress(arrived: true);
    }
    final step = steps[_current];
    return NavigationProgress(
      maneuver: step.maneuver,
      streetName: step.streetName,
      metersToManeuver: _distanceMeters(position, step.location),
      metersRemaining: _remainingAlongRoute(position),
      isFinalStep: _current == steps.length - 1,
      offRoute: _isOffRoute(position),
    );
  }

  List<double>? _cumulativeFromEnd;

  /// Distance still to walk, measured along the route rather than as the
  /// crow flies.
  ///
  /// Straight-line distance to the destination is the wrong number to show
  /// somebody on foot: it shrinks while they walk a dogleg and then stops
  /// shrinking, and in Dhaka the difference between the two is routinely a
  /// factor of two. Falls back to straight-line only when there is no
  /// geometry to measure along.
  double _remainingAlongRoute(LatLng position) {
    if (routePoints.length < 2) {
      return steps.isEmpty ? 0 : _distanceMeters(position, steps.last.location);
    }
    _cumulativeFromEnd ??= _buildCumulativeFromEnd();
    final index = _nearestPathIndex(position) ?? 0;
    // Plus the hop back onto the path, so standing 30 m off the route does
    // not read as being 30 m further along it.
    return _cumulativeFromEnd![index] + _distanceMeters(position, routePoints[index]);
  }

  List<double> _buildCumulativeFromEnd() {
    final out = List<double>.filled(routePoints.length, 0);
    for (var i = routePoints.length - 2; i >= 0; i--) {
      out[i] = out[i + 1] + _distanceMeters(routePoints[i], routePoints[i + 1]);
    }
    return out;
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

  /// The nearest un-announced landmark within [landmarkRadiusMeters], or
  /// null.
  ///
  /// Nearest first, so walking past two together names the one actually
  /// underfoot. Each is latched by index the moment it is returned — a
  /// second announcement of the same bus stop on the next GPS tick is the
  /// noise failure this whole class is shaped around, and a user standing
  /// *at* a stop waiting for a bus would otherwise hear about it forever.
  NavigationCue? _landmarkNear(LatLng position) {
    var bestIndex = -1;
    var bestDistance = landmarkRadiusMeters;
    for (var i = 0; i < _landmarks.length; i++) {
      if (_announcedLandmarks.contains(i)) continue;
      final distance = _distanceMeters(position, _landmarks[i].location);
      if (distance <= bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) return null;
    _announcedLandmarks.add(bestIndex);
    return NavigationCue(
      kind: NavigationCueKind.landmarkAhead,
      landmark: _landmarks[bestIndex],
      distanceMeters: bestDistance,
    );
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

/// A continuously-updating view of the walk, for the map panel.
///
/// Deliberately separate from [NavigationCue]: a cue is "this is worth
/// interrupting the user for", and there are long stretches of a route where
/// the right number of cues is zero and the right amount of information on
/// screen is still "250 m, then turn left onto Satmasjid Road". Conflating
/// the two is what left the dashboard showing a single rotating arrow and no
/// distance at all.
class NavigationProgress {
  const NavigationProgress({
    this.maneuver = ManeuverKind.straight,
    this.streetName = '',
    this.metersToManeuver = 0,
    this.metersRemaining = 0,
    this.isFinalStep = false,
    this.offRoute = false,
    this.arrived = false,
  });

  final ManeuverKind maneuver;
  final String streetName;

  /// How far to the manoeuvre being walked toward.
  final double metersToManeuver;

  /// How far to the destination, measured along the route.
  final double metersRemaining;

  final bool isFinalStep;
  final bool offRoute;
  final bool arrived;
}

enum NavigationCueKind { turnAhead, turnNow, offRoute, arrived, landmarkAhead }

/// A thing beside the route worth naming as it comes up.
enum LandmarkKind {
  /// A place a bus can be boarded. Not a manoeuvre, and in no route
  /// geometry — looked up separately, near the path.
  busStop,

  /// A pedestrian crossing. Also arrives as a `ManeuverKind.crossing` step
  /// when the router knows about it; this covers the ones it does not.
  crossing,
}

/// One [LandmarkKind] at one point.
class Landmark {
  const Landmark({required this.location, required this.kind, this.name = ''});

  final LatLng location;
  final LandmarkKind kind;

  /// The OSM name when there is one. Most Dhaka bus stops have none, and a
  /// bare "a bus stop" is still worth saying.
  final String name;
}

/// One thing worth saying out loud. Deliberately carries no text: phrasing
/// is localized in `dashboard_strings.dart`, and the haptic pattern that
/// goes with it is the caller's decision.
class NavigationCue {
  const NavigationCue({
    required this.kind,
    this.step,
    this.landmark,
    this.distanceMeters = 0,
    this.isFinalStep = false,
  });

  final NavigationCueKind kind;
  final RouteStep? step;

  /// Set only for [NavigationCueKind.landmarkAhead].
  final Landmark? landmark;
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
