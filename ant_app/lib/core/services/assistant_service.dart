import 'package:geolocator/geolocator.dart';

import '../../features/dashboard/models/chat_message.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

/// One conversational turn, whoever answers it.
///
/// `GroqAssistantService` and `GeminiAssistantService` already had
/// byte-identical `converse` signatures before this interface existed — they
/// were written as two implementations of one contract, sharing
/// `FunctionCallExecutor` and returning the same [AssistantTurn]. This just
/// names the contract so a caller can hold either, and so
/// [FallbackAssistantService] can hold both.
///
/// ## Why a swap loses no context
///
/// Nothing the assistant "remembers" lives inside the provider. Every call is
/// stateless and rebuilt from app-side state on every turn: [recentHistory]
/// comes from `ChatHistoryStore`, the user's remembered notes and settings
/// ride in [profile], the journey rides in [activeRoute]/[routeAlternatives],
/// and anything pending comes back inside the returned [AssistantTurn] for
/// `ChatController` to hold.
///
/// There is no server-side thread and no conversation id anywhere in this
/// app. So falling back is not "resuming elsewhere" — it is handing the same
/// complete picture to a different model, which is exactly what the first
/// model was given.
abstract class AssistantService {
  /// A short name for logs, so a diagnostics file says which backend
  /// answered. Without it a fallback is invisible in exactly the session
  /// somebody is trying to explain.
  String get backendName;

  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  });
}
