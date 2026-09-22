import 'package:cloud_functions/cloud_functions.dart';

/// One crowdsourced hazard pin a route passes close to — Module 5's $w_2$
/// contribution to the safety verdict.
///
/// [subCategory] is the stable English key (`'openManhole'`, `'stairsOnly'`)
/// that `HazardReport` stores, never a display label — the caller resolves
/// it through `Dashboard.hazardSubCategoryLabel` in the user's own language.
class RouteHazard {
  const RouteHazard({
    required this.zoneId,
    required this.category,
    required this.subCategory,
    required this.flag,
    required this.reportCount,
    this.lat,
    this.lng,
  });

  final String zoneId;
  final String category;
  final String subCategory;

  /// `'yellow'` (one unconfirmed report — warn, do not reroute) or `'red'`
  /// (three independent reporters within 24h — actively avoided). See
  /// `functions/lib/hazard_clustering.js`.
  final String flag;
  final int reportCount;

  /// Where the hazard actually is.
  ///
  /// The Cloud Function has always returned these — `hazardsOnRoute` filters
  /// whole hazard-zone documents by `hazard.lat`/`hazard.lng` and hands them
  /// back intact — and this parser simply dropped them. Recovered because
  /// "there is a hazard somewhere on your route" and "there is an open
  /// manhole twenty metres ahead" are different sentences, and only the
  /// second is worth interrupting a walk for.
  ///
  /// Nullable: an older cached verdict, or a malformed document, must not
  /// take the whole safety check down.
  final double? lat;
  final double? lng;

  bool get hasPosition => lat != null && lng != null;

  bool get isConfirmed => flag == 'red';

  factory RouteHazard.fromJson(Map<Object?, Object?> json) => RouteHazard(
        zoneId: json['id'] as String? ?? '',
        category: json['category'] as String? ?? '',
        subCategory: json['subCategory'] as String? ?? '',
        flag: json['flag'] as String? ?? 'yellow',
        reportCount: ((json['reportCount'] as num?) ?? 1).toInt(),
        lat: (json['lat'] as num?)?.toDouble(),
        lng: (json['lng'] as num?)?.toDouble(),
      );
}

/// Result of the `checkRouteSafety` Cloud Function for one candidate route
/// — Module 4, Step 3 ($w_1$, time-weighted crime) plus Module 5's $w_2$
/// (crowdsourced hazard pins).
class SafetyVerdict {
  const SafetyVerdict({
    required this.safe,
    required this.riskScore,
    required this.threshold,
    required this.dangerousThanaNames,
    this.blockingHazards = const [],
    this.hazardWarnings = const [],
  });

  final bool safe;
  final double riskScore;
  final double threshold;
  final List<String> dangerousThanaNames;

  /// Confirmed (Red Flag) hazards on this route — enough on their own to
  /// make [safe] false and send `RoutePlanningService` looking for an
  /// alternative.
  final List<RouteHazard> blockingHazards;

  /// Unconfirmed (Yellow Flag) hazards. Deliberately do *not* affect
  /// [safe]: a single unreviewed report warrants telling the user, not
  /// rerouting them — see `hazard_clustering.js`'s `hazardWeight`.
  final List<RouteHazard> hazardWarnings;

  /// Everything worth mentioning to the user, confirmed first.
  List<RouteHazard> get allHazards => [...blockingHazards, ...hazardWarnings];

  static List<RouteHazard> _hazards(Object? raw) => ((raw as List<dynamic>?) ?? const [])
      .map((h) => RouteHazard.fromJson(h as Map<Object?, Object?>))
      .toList();

  factory SafetyVerdict.fromCallableResult(Map<Object?, Object?> data) => SafetyVerdict(
        safe: data['safe'] as bool? ?? true,
        riskScore: ((data['riskScore'] as num?) ?? 1).toDouble(),
        threshold: ((data['threshold'] as num?) ?? 7).toDouble(),
        dangerousThanaNames: ((data['dangerousZones'] as List<dynamic>?) ?? const [])
            .map((z) => (z as Map<Object?, Object?>)['thanaName'] as String)
            .toList(),
        // Absent from an older deployed function's response — defaults to
        // empty rather than throwing, so a client newer than the backend
        // degrades to Module 4 behaviour instead of failing every route.
        blockingHazards: _hazards(data['blockingHazards']),
        hazardWarnings: _hazards(data['hazardWarnings']),
      );
}

/// Thin wrapper around the deployed `checkRouteSafety` callable — decoding
/// happens server-side against the real `crimeZones` Firestore collection
/// (see `functions/index.js`), this just shapes the request/response.
class RouteSafetyService {
  RouteSafetyService({FirebaseFunctions? functions}) : _functions = functions ?? FirebaseFunctions.instance;

  final FirebaseFunctions _functions;

  Future<SafetyVerdict> check({required String encodedPolyline, DateTime? at}) async {
    final callable = _functions.httpsCallable('checkRouteSafety');
    final result = await callable.call<Map<Object?, Object?>>({
      'polyline': encodedPolyline,
      'timestampMs': (at ?? DateTime.now()).millisecondsSinceEpoch,
    });
    return SafetyVerdict.fromCallableResult(result.data);
  }

  /// Marks a crowdsourced hazard as no longer there — Step 3's escape hatch
  /// for structural blocks, which never decay on a timer (a staircase does
  /// not become a ramp by waiting). See `resolveHazardZone` in
  /// `functions/index.js`.
  Future<void> resolveHazard(String zoneId) async {
    final callable = _functions.httpsCallable('resolveHazardZone');
    await callable.call<Map<Object?, Object?>>({'zoneId': zoneId});
  }
}
