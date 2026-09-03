import 'package:cloud_functions/cloud_functions.dart';

/// Result of the `checkRouteSafety` Cloud Function (Module 4, Step 3) for
/// one candidate route.
class SafetyVerdict {
  const SafetyVerdict({
    required this.safe,
    required this.riskScore,
    required this.threshold,
    required this.dangerousThanaNames,
  });

  final bool safe;
  final double riskScore;
  final double threshold;
  final List<String> dangerousThanaNames;

  factory SafetyVerdict.fromCallableResult(Map<Object?, Object?> data) => SafetyVerdict(
        safe: data['safe'] as bool? ?? true,
        riskScore: ((data['riskScore'] as num?) ?? 1).toDouble(),
        threshold: ((data['threshold'] as num?) ?? 7).toDouble(),
        dangerousThanaNames: ((data['dangerousZones'] as List<dynamic>?) ?? const [])
            .map((z) => (z as Map<Object?, Object?>)['thanaName'] as String)
            .toList(),
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
}
