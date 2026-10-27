import 'dart:async';
import 'dart:io';

/// Why an assistant request failed, in the three ways that need different
/// words to the user.
enum AiFailureKind {
  /// It took too long. The connection may be fine.
  timeout,

  /// No usable connection.
  offline,

  /// The service refused: busy, rate limited or out of quota.
  busy,

  /// Anything else.
  other,
}

AiFailureKind classifyAiFailure(Object error) {
  if (error is TimeoutException) return AiFailureKind.timeout;
  if (error is SocketException) return AiFailureKind.offline;
  final m = error.toString().toLowerCase();
  if (m.contains('timeout') || m.contains('timed out')) return AiFailureKind.timeout;
  if (m.contains('failed host lookup') ||
      m.contains('network is unreachable') ||
      m.contains('socketexception') ||
      m.contains('connection refused') ||
      m.contains('connection closed') ||
      m.contains('no internet')) {
    return AiFailureKind.offline;
  }
  if (m.contains('429') ||
      m.contains('503') ||
      m.contains('quota') ||
      m.contains('rate limit') ||
      m.contains('rate_limit') ||
      m.contains('resource_exhausted') ||
      m.contains('high demand') ||
      m.contains('overloaded') ||
      m.contains('budgetexhausted')) {
    return AiFailureKind.busy;
  }
  return AiFailureKind.other;
}
