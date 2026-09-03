import 'package:google_maps_flutter/google_maps_flutter.dart';

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
  });

  final String destinationLabel;
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final double initialBearingDegrees;
  final SafetyVerdict verdict;

  /// True when the fastest (first) route Google offered was unsafe and this
  /// is a safer alternative instead — what triggers the "I've adjusted your
  /// route..." announcement from `04_module_plan_crime.md` Step 4.
  final bool wasRerouted;
}

sealed class RoutePlanResult {
  const RoutePlanResult();
}

class RoutePlanned extends RoutePlanResult {
  const RoutePlanned(this.choice);
  final RouteChoice choice;
}

/// `reason`: 'destination_not_found' | 'no_routes_found' | 'no_location' |
/// 'network_error'.
class RoutePlanFailed extends RoutePlanResult {
  const RoutePlanFailed(this.reason);
  final String reason;
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
  }) async {
    final destination = await _routing.geocode(destinationQuery);
    if (destination == null) {
      return const RoutePlanFailed('destination_not_found');
    }

    final candidates = await _routing.walkingRoutes(origin: origin, destination: destination);
    if (candidates.isEmpty) {
      return const RoutePlanFailed('no_routes_found');
    }

    // Safety-check every alternative Google offered (walking routes rarely
    // have more than 2-3), then take the safest one — preferring the
    // original fastest route if it's already safe, per Step 4 of the
    // module plan ("If the route is Safe, ANT begins navigation").
    RouteCandidate? best;
    SafetyVerdict? bestVerdict;
    for (final candidate in candidates) {
      final verdict = await _safety.check(encodedPolyline: candidate.encodedPolyline, at: at);
      if (verdict.safe) {
        best = candidate;
        bestVerdict = verdict;
        break;
      }
      // No safe alternative found yet — keep the lowest-risk candidate seen
      // so far as a fallback.
      if (bestVerdict == null || verdict.riskScore < bestVerdict.riskScore) {
        best = candidate;
        bestVerdict = verdict;
      }
    }

    final chosen = best!;
    final verdict = bestVerdict!;
    return RoutePlanned(RouteChoice(
      destinationLabel: destinationQuery,
      points: chosen.points,
      distanceMeters: chosen.distanceMeters,
      durationSeconds: chosen.durationSeconds,
      initialBearingDegrees: chosen.initialBearingDegrees,
      verdict: verdict,
      wasRerouted: !identical(chosen, candidates.first),
    ));
  }
}
