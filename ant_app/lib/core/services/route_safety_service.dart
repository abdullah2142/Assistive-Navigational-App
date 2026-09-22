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
    this.warnThreshold = 7,
    this.riskKind,
    this.warnThanaNames = const [],
    this.blockingHazards = const [],
    this.hazardWarnings = const [],
  });

  /// Whether to *route around* this — the comparison against a fixed 7 that
  /// `RoutePlanningService` uses to decide whether to keep looking at
  /// alternatives. Unchanged, and deliberately so: relative scores are the
  /// right tool for ranking candidates and that half was never broken.
  final bool safe;
  final double riskScore;
  final double threshold;
  final List<String> dangerousThanaNames;

  /// The score [riskScore] must beat to earn a *spoken* warning: the higher
  /// of the city's 90th percentile at this hour and the old fixed floor.
  ///
  /// Defaults to 7 — the old threshold — so a response from a backend
  /// deployed before §8.0 reproduces the old behaviour exactly rather than
  /// going quiet. Of the two ways to be wrong about a safety warning, too
  /// loud is the recoverable one.
  final double warnThreshold;

  /// `'chronic'` (a standing property of the neighbourhood), `'acute'`
  /// (a current advisory or a confirmed hazard), or null when nothing is
  /// worth mentioning. Lets the app say different things about a place that
  /// has been rough for years and one where something was reported this
  /// week.
  final String? riskKind;

  /// The thanas that cleared [warnThreshold] — a subset of
  /// [dangerousThanaNames], never larger.
  final List<String> warnThanaNames;

  /// Whether to *say* something — a different question from [safe], which
  /// decides whether to route around something.
  ///
  /// A fixed threshold of 7 sits between the median and the 75th percentile
  /// of Dhaka's night-time risk distribution, so [safe] is false for roughly
  /// a quarter of the city after 8pm before any crime evidence is involved.
  /// Speaking on every one of those trains the user to talk over the
  /// warning, and for someone who cannot see the map the warning *is* the
  /// information. See `functions/lib/risk_threshold.js`.
  ///
  /// Three ways in, each covering a case the others miss:
  ///
  /// - [warnThanaNames] is the function's own answer, and the only one that
  ///   knows about the live-advisory exception — a thana with current
  ///   reporting warns on clearing the floor alone, without having to clear
  ///   the hour's percentile. Re-deriving that here would be a second
  ///   implementation of the same rule, free to drift from the first.
  /// - [riskScore] against [warnThreshold] covers a verdict built directly
  ///   rather than parsed, and an older backend, where [warnThreshold]
  ///   falls back to the old 7 and this reduces to exactly `!safe`.
  /// - A confirmed hazard always speaks: three independent people reported
  ///   one obstruction in 24 hours, and its 1-10 weight would otherwise be
  ///   swallowed whole by a night-time percentile.
  bool get shouldWarn =>
      warnThanaNames.isNotEmpty || riskScore > warnThreshold || blockingHazards.isNotEmpty;

  bool get isAcute => riskKind == 'acute';

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

  static List<String> _thanaNames(Object? raw) => ((raw as List<dynamic>?) ?? const [])
      .map((z) => (z as Map<Object?, Object?>)['thanaName'] as String?)
      .whereType<String>()
      .toList();

  factory SafetyVerdict.fromCallableResult(Map<Object?, Object?> data) => SafetyVerdict(
        safe: data['safe'] as bool? ?? true,
        riskScore: ((data['riskScore'] as num?) ?? 1).toDouble(),
        threshold: ((data['threshold'] as num?) ?? 7).toDouble(),
        dangerousThanaNames: _thanaNames(data['dangerousZones']),
        // Falls back to the route's own `threshold`, so a backend deployed
        // before §8.0 reproduces the old warn-on-everything-unsafe behaviour
        // rather than going silent.
        warnThreshold: ((data['warnThreshold'] as num?) ?? (data['threshold'] as num?) ?? 7).toDouble(),
        riskKind: data['riskKind'] as String?,
        warnThanaNames: _thanaNames(data['warnZones'] ?? data['dangerousZones']),
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
