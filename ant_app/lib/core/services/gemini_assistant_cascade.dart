import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../features/dashboard/models/chat_message.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'assistant_service.dart';
import 'gemini_assistant_service.dart';
import 'gemini_model_cooldowns.dart';
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

/// Tries assistant models in order, skipping models whose reset timer is active.
/// Each attempt receives the same prompt, history, function executor and live
/// app context. The ordered list returns the preferred model to first place
/// automatically when its quota timer expires.
// ignore_for_file: prefer_initializing_formals
class GeminiAssistantCascade implements AssistantService {
  GeminiAssistantCascade({
    required List<AssistantService> models,
    GeminiModelCooldowns? cooldowns,
    this.attemptTimeout = const Duration(seconds: 4),
  }) : _models = models,
       _cooldowns = cooldowns ?? GeminiModelCooldowns.shared;

  final List<AssistantService> _models;
  final GeminiModelCooldowns _cooldowns;
  final Duration attemptTimeout;

  @override
  String get backendName => _models.map((m) => m.backendName).join('->');

  String? _lastModel;
  String? get lastModel => _lastModel;

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
    Object? lastError;
    var attempted = 0;
    final stopwatch = Stopwatch()..start();
    for (final model in _models) {
      final key = model.backendName;
      if (_cooldowns.isCooling(key)) {
        debugPrint(
          '[Assistant] $key cooling until '
          '${_cooldowns.resetAt(key)?.toIso8601String()}',
        );
        continue;
      }
      final remaining = const Duration(seconds: 9) - stopwatch.elapsed;
      if (remaining <= Duration.zero) break;
      attempted++;
      try {
        final turn = await model
            .converse(
              userText: userText,
              profile: profile,
              recentHistory: recentHistory,
              location: location,
              onPartialText: onPartialText,
              activeRoute: activeRoute,
              routeAlternatives: routeAlternatives,
            )
            .timeout(remaining < attemptTimeout ? remaining : attemptTimeout);
        _lastModel = key;
        return turn;
      } catch (error) {
        lastError = error;
        final resetAt = _cooldowns.recordFailure(key, error);
        debugPrint(
          '[Assistant] $key failed'
          '${resetAt == null ? '' : '; retry after $resetAt'}: $error',
        );
      }
    }
    if (attempted == 0) {
      throw StateError('All Gemini models are cooling down.');
    }
    throw StateError('Gemini cascade exhausted: $lastError');
  }
}
