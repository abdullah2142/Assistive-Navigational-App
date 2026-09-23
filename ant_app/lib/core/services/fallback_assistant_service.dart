import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../features/dashboard/models/chat_message.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'assistant_service.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

/// Tries one backend, then the other.
///
/// ## What this is worth
///
/// The 17 September tester session logged **twelve** `429`s from Groq, every
/// one of them the same thing: `ITPM: Limit 7000`, with a single turn asking
/// for 5,184-5,320 input tokens. Each of those was a turn where somebody
/// spoke to the app and got nothing back — `ChatController`'s catch falls
/// through to `OfflineIntentMatcher`, which knows help, stop, where-am-I and
/// emergency, and nothing else. So twelve real questions became a stub reply.
///
/// That is what this exists to convert into a slower answer instead of no
/// answer.
///
/// ## Why it costs no context
///
/// See [AssistantService] — every call is stateless and rebuilt from
/// app-side state, so the secondary is handed exactly the picture the primary
/// had. There is no thread to resume and nothing to migrate.
///
/// ## Why failure-only, never load-balancing
///
/// Two reasons, and both matter more than the even spread would be worth.
///
/// Groq bills a cached request *prefix* at nothing against the per-minute
/// limit, which is why `c895da7` moved the volatile parts of the system
/// prompt to the bottom and why `_coreTools` exists at all. Alternating
/// backends would halve the hit rate on the very cache built to survive this
/// rate limit — making the 429s it is meant to rescue *more* frequent.
///
/// And the two backends are only as interchangeable as their hand-maintained
/// tool lists happen to be on any given day. `tool_parity_test.dart` enforces
/// that, but a test enforces a property; it does not make the property free.
/// Keeping the secondary rare keeps any residual difference rare too.
class FallbackAssistantService implements AssistantService {
  FallbackAssistantService({
    required AssistantService primary,
    required AssistantService? secondary,
    Duration? primaryTimeout,
    Duration? secondaryTimeout,
    // ignore_for_file: prefer_initializing_formals
  })  : _primary = primary,
        _secondary = secondary,
        _primaryTimeout = primaryTimeout ?? defaultPrimaryTimeout,
        _secondaryTimeout = secondaryTimeout ?? defaultSecondaryTimeout;

  final AssistantService _primary;

  /// Null when no second backend is configured — then this is a transparent
  /// pass-through and behaves exactly as the primary alone did.
  final AssistantService? _secondary;

  final Duration _primaryTimeout;
  final Duration _secondaryTimeout;

  /// The two budgets sum to less than `ChatController._geminiBudget` (30s),
  /// which still wraps this whole call from outside.
  ///
  /// That outer bound is the one the user actually feels, and it was set
  /// after a session logged replies arriving at 59,144 ms and 42,898 ms — "a
  /// full minute of nothing, and then a fallback reply anyway". If the two
  /// attempts here could sum past it, the outer timeout would fire *during*
  /// the second attempt and throw away an answer that was on its way, which
  /// is the one outcome worse than not having tried.
  ///
  /// 18 + 10 = 28, leaving two seconds of headroom for the executor work a
  /// turn does after the model returns.
  static const Duration defaultPrimaryTimeout = Duration(seconds: 18);
  static const Duration defaultSecondaryTimeout = Duration(seconds: 10);

  /// The whole turn's budget, which the two attempts share.
  static const Duration turnBudget = Duration(seconds: 28);

  /// What the secondary gets, given the primary burned [spent].
  ///
  /// A fixed 10s threw away most of the turn in the case that matters most.
  /// A rate-limited primary does not time out — it returns a 429 in about
  /// 200ms — so on 23 September the fallback was handed 10 seconds out of a
  /// 28-second budget with 27 of them still unspent, and **7 turns died on a
  /// TimeoutException at exactly 10s** while Groq was locked out for 25
  /// minutes at a time. Those are the turns the user saw answered with "the
  /// ability to answer this sort of message will be added later".
  ///
  /// Never less than the old fixed value, so a primary that genuinely runs
  /// its full 18s still leaves a usable window rather than a negative one.
  Duration _secondaryBudget(Duration spent) {
    final left = turnBudget - spent;
    return left > _secondaryTimeout ? left : _secondaryTimeout;
  }

  @override
  String get backendName =>
      _secondary == null ? _primary.backendName : '${_primary.backendName}->${_secondary.backendName}';

  /// Set when the last completed turn was answered by the secondary.
  ///
  /// Exposed because a fallback is otherwise invisible: the reply arrives
  /// looking normal, and the only trace is a debug line. Anything that wants
  /// to surface "answered by the backup" — a diagnostics summary, a settings
  /// screen, a future tester build — reads this rather than parsing logs.
  bool get lastTurnUsedFallback => _lastTurnUsedFallback;
  bool _lastTurnUsedFallback = false;

  @override
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) async {
    _lastTurnUsedFallback = false;
    final secondary = _secondary;

    // How long the primary actually took, so the secondary can be given the
    // rest of the turn's budget instead of a fixed slice of it.
    final attemptClock = Stopwatch()..start();
    try {
      return await _primary
          .converse(
            userText: userText,
            profile: profile,
            recentHistory: recentHistory,
            location: location,
            onPartialText: onPartialText,
            activeRoute: activeRoute,
            routeAlternatives: routeAlternatives,
          )
          .timeout(_primaryTimeout);
    } catch (primaryError) {
      if (secondary == null) {
        // Nothing to fall back to. Rethrow unchanged so `ChatController`'s
        // catch behaves exactly as it did before this class existed — the
        // offline matcher, and a logged reason.
        debugPrint('[Assistant] ${_primary.backendName} failed and no fallback '
            'is configured: $primaryError');
        rethrow;
      }

      debugPrint('[Assistant] ${_primary.backendName} failed '
          '($primaryError) — retrying on ${secondary.backendName}');

      try {
        final turn = await secondary
            .converse(
              userText: userText,
              profile: profile,
              recentHistory: recentHistory,
              location: location,
              // Forwarded deliberately. If the primary streamed a partial
              // before dying, the bubble already on screen holds a fragment
              // of an answer that is never finishing — and the caller's
              // `_withLastReplaced` overwrites it with the secondary's first
              // chunk. Suppressing these would leave that fragment visible
              // until the whole turn completed.
              onPartialText: onPartialText,
              activeRoute: activeRoute,
              routeAlternatives: routeAlternatives,
            )
            .timeout(_secondaryBudget(attemptClock.elapsed));
        _lastTurnUsedFallback = true;
        debugPrint('[Assistant] ${secondary.backendName} answered the fallback turn');
        return turn;
      } catch (secondaryError) {
        // Both are down. Report the *primary's* failure, because that is the
        // one worth acting on — the secondary exists precisely to be tried
        // and is allowed to be unreliable (its free tier answers with 503s
        // under load, as `gemini_config.dart` records at length). Burying the
        // primary's reason behind the backup's would point every future
        // investigation at the wrong backend.
        debugPrint('[Assistant] fallback ${secondary.backendName} also failed: '
            '$secondaryError');
        throw AssistantBothBackendsFailed(
          primary: _primary.backendName,
          primaryError: primaryError,
          secondary: secondary.backendName,
          secondaryError: secondaryError,
        );
      }
    }
  }
}

/// Raised when neither backend could answer.
///
/// Carries both reasons rather than just the last one, so a diagnostics log
/// shows whether this was one outage or two unrelated failures.
class AssistantBothBackendsFailed implements Exception {
  const AssistantBothBackendsFailed({
    required this.primary,
    required this.primaryError,
    required this.secondary,
    required this.secondaryError,
  });

  final String primary;
  final Object primaryError;
  final String secondary;
  final Object secondaryError;

  @override
  String toString() =>
      'AssistantBothBackendsFailed: $primary -> $primaryError; $secondary -> $secondaryError';
}
