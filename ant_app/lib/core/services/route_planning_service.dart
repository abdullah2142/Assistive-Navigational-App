import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'destination_clarifier.dart';
import 'route_safety_service.dart';
import 'routing_service.dart';

/// A fully planned, safety-checked route — what `ChatState.pendingRoute`
/// carries to the dashboard's map/arrow, and what the AI Assistant's
/// `request_route` confirmation text is built from.
class RouteChoice {
  const RouteChoice({
    required this.destinationLabel,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.initialBearingDegrees,
    required this.verdict,
    required this.wasRerouted,
    this.steps = const [],
    this.viaSummary = '',
  });

  final String destinationLabel;

  /// The road this route mostly follows, or empty when no step is named.
  ///
  /// Exists so the assistant can say *which way* it is taking the user
  /// rather than only that it found a way. See [routeViaSummary].
  final String viaSummary;
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final double initialBearingDegrees;
  final SafetyVerdict verdict;

  /// Turn-by-turn manoeuvres for spoken navigation, in order. Empty when
  /// the backend returned no step detail — `NavigationController` then
  /// falls back to distance-and-bearing guidance rather than going silent.
  final List<RouteStep> steps;

  /// True when the fastest (first) route Google offered was unsafe and this
  /// is a safer alternative instead — what triggers the "I've adjusted your
  /// route..." announcement from `04_module_plan_crime.md` Step 4.
  final bool wasRerouted;
}

sealed class RoutePlanResult {
  const RoutePlanResult();
}

class RoutePlanned extends RoutePlanResult {
  const RoutePlanned(this.choice, {this.alternatives = const []});
  final RouteChoice choice;

  /// The other walking routes the backend offered, in its own preference
  /// order, **not** safety-checked.
  ///
  /// Kept rather than discarded so "give me a different route" has something
  /// to switch to — the reported gap was that the assistant announced one
  /// route and the user had no way to ask for another, even though Google
  /// had been asked for alternatives all along and every one but the chosen
  /// one was being thrown away.
  ///
  /// Unchecked on purpose. Safety-checking all of them up front would cost
  /// two or three extra Cloud Function round trips on every single route
  /// request, to answer a question the user usually never asks; the check
  /// happens in [RoutePlanningService.promote], when one is actually taken.
  final List<RouteCandidate> alternatives;
}

/// `reason`: 'destination_not_found' | 'no_routes_found' | 'no_location' |
/// 'network_error'.
class RoutePlanFailed extends RoutePlanResult {
  const RoutePlanFailed(this.reason);
  final String reason;
}

/// The name matched several genuinely different places.
///
/// Not a failure — the geocoder did its job, there is simply more than one
/// answer. Picking the highest-scoring one silently is the worst option
/// available: a user who cannot see the map has no way to notice it chose
/// wrong until they have walked to the wrong place.
class RoutePlanAmbiguous extends RoutePlanResult {
  const RoutePlanAmbiguous(this.options);
  final List<GeocodeCandidate> options;
}

/// Orchestrates Step 4 of the crime module plan: request a route, safety
/// check it, and reroute via Google's own walking-route alternatives if the
/// fastest option crosses a dangerous Thana — entirely client-side
/// (`RoutingService` for Directions/Geocoding, `RouteSafetyService` for the
/// `checkRouteSafety` Cloud Function), so the chat transcript can show each
/// step as it happens rather than waiting on an opaque server-side loop.
class RoutePlanningService {
  RoutePlanningService({RoutingService? routing, RouteSafetyService? safety})
      : _routing = routing ?? RoutingService(),
        _safety = safety ?? RouteSafetyService();

  final RoutingService _routing;
  final RouteSafetyService _safety;

  Future<RoutePlanResult> plan({
    required String destinationQuery,
    required LatLng origin,
    DateTime? at,
    /// Already-known coordinates for the destination, from a saved place.
    ///
    /// When present the geocoding round trip is skipped entirely — the
    /// single biggest latency saving in this path, and the only way
    /// destinations like "work" or "my sister's house" resolve at all,
    /// since no geocoder turns those strings into a location. Also what
    /// keeps a user's everyday destinations reachable with no connectivity.
    LatLng? knownDestination,
    /// Human-readable name to speak back, when it differs from the raw
    /// query — a saved place's label rather than its full street address.
    String? destinationLabel,
  }) async {
    var destination = knownDestination;
    var label = destinationLabel;
    if (destination == null) {
      final candidates =
          DestinationClarifier.distinctOptions(await _routing.geocodeCandidates(destinationQuery));
      if (candidates.isEmpty) return const RoutePlanFailed('destination_not_found');
      if (candidates.length > 1) return RoutePlanAmbiguous(candidates);
      destination = candidates.single.location;
      // The geocoder's own description is more useful to say back than the
      // raw query — "Ibn Sina Hospital, Dhanmondi" confirms *which* place
      // was understood, where echoing "the hospital" confirms nothing.
      label ??= candidates.single.spokenLabel;
    }

    final candidates = await _routing.walkingRoutes(origin: origin, destination: destination);
    if (candidates.isEmpty) {
      return const RoutePlanFailed('no_routes_found');
    }

    // Safety-check every alternative Google offered (walking routes rarely
    // have more than 2-3), then take the safest one — preferring the
    // original fastest route if it's already safe, per Step 4 of the
    // module plan ("If the route is Safe, ANT begins navigation").
    //
    // The loop stops at the first safe route rather than checking them all,
    // so anything after the chosen one has *no* verdict. That distinction
    // matters below: a candidate already known to be unsafe must not be the
    // first thing offered when the user asks for a different route.
    RouteCandidate? best;
    SafetyVerdict? bestVerdict;
    final rejected = <RouteCandidate, SafetyVerdict>{};
    for (final candidate in candidates) {
      final verdict = await _safety.check(encodedPolyline: candidate.encodedPolyline, at: at);
      if (verdict.safe) {
        best = candidate;
        bestVerdict = verdict;
        break;
      }
      rejected[candidate] = verdict;
      // No safe alternative found yet — keep the lowest-risk candidate seen
      // so far as a fallback.
      if (bestVerdict == null || verdict.riskScore < bestVerdict.riskScore) {
        best = candidate;
        bestVerdict = verdict;
      }
    }

    final chosen = best!;
    final verdict = bestVerdict!;
    final others = [
      for (final candidate in candidates)
        if (!identical(candidate, chosen)) candidate,
    ];
    // Unchecked first, then the ones already found unsafe, least risky
    // first. Offering a route this method has *just measured* as dangerous
    // ahead of one it has not looked at is the one ordering that cannot be
    // defended to someone who cannot see where they are being sent.
    others.sort((a, b) {
      final ra = rejected[a]?.riskScore;
      final rb = rejected[b]?.riskScore;
      if (ra == null && rb == null) return 0;
      if (ra == null) return -1;
      if (rb == null) return 1;
      return ra.compareTo(rb);
    });
    return RoutePlanned(
      _toChoice(
        chosen,
        label: label ?? destinationQuery,
        verdict: verdict,
        wasRerouted: !identical(chosen, candidates.first),
      ),
      alternatives: others,
    );
  }

  /// Safety-checks one of the alternatives held from an earlier [plan] and
  /// turns it into a route the app can walk.
  ///
  /// Separate from [plan] because it must not re-geocode or re-request
  /// directions: the user asking for a different route is asking for one of
  /// the routes already found, and going back to the network would risk
  /// answering with a different set entirely.
  ///
  /// [wasRerouted] is deliberately false on everything this returns — the
  /// user chose this route, so announcing that it was adjusted for their
  /// safety would be untrue.
  Future<RouteChoice> promote(
    RouteCandidate candidate, {
    required String destinationLabel,
    DateTime? at,
  }) async {
    final verdict = await _safety.check(encodedPolyline: candidate.encodedPolyline, at: at);
    return _toChoice(candidate, label: destinationLabel, verdict: verdict, wasRerouted: false);
  }

  RouteChoice _toChoice(
    RouteCandidate candidate, {
    required String label,
    required SafetyVerdict verdict,
    required bool wasRerouted,
  }) =>
      RouteChoice(
        destinationLabel: label,
        points: candidate.points,
        distanceMeters: candidate.distanceMeters,
        durationSeconds: candidate.durationSeconds,
        initialBearingDegrees: candidate.initialBearingDegrees,
        steps: candidate.steps,
        viaSummary: routeViaSummary(candidate.steps),
        verdict: verdict,
        wasRerouted: wasRerouted,
      );
}
