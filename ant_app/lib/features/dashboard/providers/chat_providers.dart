import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/local_intent_matcher.dart';
import '../../../core/services/offline_intent_matcher.dart';
import '../../../core/services/route_planning_service.dart';
import '../../onboarding/models/user_profile.dart';
import '../../onboarding/providers/onboarding_providers.dart';
import '../models/chat_message.dart';
import '../models/suggested_chip.dart';

class ChatState {
  const ChatState({
    this.messages = const [],
    this.isAssistantTyping = false,
    this.pendingOverlayAction,
    this.pendingRoute,
  });

  final List<ChatMessage> messages;
  final bool isAssistantTyping;

  /// Set when the AI Assistant's function calling decided the Passerby
  /// Helper or Hazard Report overlay should open — `ChatStreamPanel` (which
  /// owns a `BuildContext`, this plain `Notifier` doesn't) watches for this
  /// and opens it via the same path a suggested chip tap uses, then calls
  /// [ChatController.clearPendingOverlay].
  final SuggestedChipAction? pendingOverlayAction;

  /// Set when `request_route` (Module 4) successfully planned a route — the
  /// map widget watches this to draw the polyline and rotate the giant
  /// directional arrow. Stays set (unlike `pendingOverlayAction`, which is a
  /// one-shot trigger) for as long as a route is active; cleared via
  /// [ChatController.clearRoute].
  final RouteChoice? pendingRoute;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isAssistantTyping,
    SuggestedChipAction? pendingOverlayAction,
    bool clearOverlay = false,
    RouteChoice? pendingRoute,
    bool clearRoute = false,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        isAssistantTyping: isAssistantTyping ?? this.isAssistantTyping,
        pendingOverlayAction: clearOverlay ? null : (pendingOverlayAction ?? this.pendingOverlayAction),
        pendingRoute: clearRoute ? null : (pendingRoute ?? this.pendingRoute),
      );
}

/// Drives the Dynamic Chat Stream on the Split-Mode Dashboard.
///
/// Free-text and voice input now go through [GeminiAssistantService] (the
/// AI Assistant module's "central brain"), which returns conversational
/// text plus any function calls — settings changes get written back via
/// [ProfileService], `open_*` calls surface as [ChatState.pendingOverlayAction].
/// When no Gemini key is configured yet (`GeminiConfig.isConfigured`), or
/// the call fails (no signal, quota, etc.), this falls back to
/// [OfflineIntentMatcher] and then to Module 2's original canned replies —
/// so the chat stream, suggested chips, and overlay triggers all keep
/// working exactly as before a key exists.
class ChatController extends Notifier<ChatState> {
  @override
  ChatState build() => const ChatState();

  /// Called once by the widget as soon as it knows the current language —
  /// idempotent, so calling it again after the first message is a no-op.
  void ensureWelcomeMessage(Dashboard d) {
    if (state.messages.isNotEmpty) return;
    state = state.copyWith(messages: [
      ChatMessage(sender: ChatSender.assistant, text: d.chatWelcome, timestamp: DateTime.now()),
    ]);
  }

  void clearPendingOverlay() => state = state.copyWith(clearOverlay: true);

  void clearRoute() => state = state.copyWith(clearRoute: true);

  /// Replaces the last message's text in place, keeping its sender/timestamp
  /// — used while a streaming reply is filling in, when what's needed is
  /// "update the bubble that's already there," not "add another one".
  List<ChatMessage> _withLastReplaced({required String text}) {
    final messages = List<ChatMessage>.from(state.messages);
    if (messages.isEmpty) return messages;
    final last = messages.removeLast();
    messages.add(ChatMessage(sender: last.sender, text: text, timestamp: last.timestamp));
    return messages;
  }

  /// `LocalIntentMatcher` can't know the user's *current* font scale (it
  /// has no profile to look at, by design — it's a stateless text
  /// matcher), so a "bigger text"/"smaller text" match comes back with a
  /// sentinel value instead of a number; resolved into an actual clamped
  /// scale here, where the live profile is available.
  Map<String, Object?> _resolveLocalIntentArgs(LocalIntent intent, UserProfile profile) {
    if (intent.name != 'update_setting' || intent.args['setting'] != 'text_size') return intent.args;
    final delta = switch (intent.args['value']) {
      '_bigger' => 0.15,
      '_smaller' => -0.15,
      _ => null,
    };
    if (delta == null) return intent.args;
    final newScale = (profile.fontScale + delta).clamp(0.8, 2.0);
    return {'setting': 'text_size', 'value': newScale.toStringAsFixed(2)};
  }

  void _appendUserMessage(String text) {
    state = state.copyWith(messages: [
      ...state.messages,
      ChatMessage(sender: ChatSender.user, text: text, timestamp: DateTime.now()),
    ]);
  }

  /// Speaks every assistant reply unless the user is Deaf/hard of hearing —
  /// the same rule `OnboardingController.setDeafHearing` already applies to
  /// spoken onboarding guidance (that profile flag means "show text and
  /// visuals instead of relying on audio").
  Future<void> _appendAssistantReply(String text, UserProfile profile) async {
    state = state.copyWith(isAssistantTyping: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    state = state.copyWith(
      isAssistantTyping: false,
      messages: [
        ...state.messages,
        ChatMessage(sender: ChatSender.assistant, text: text, timestamp: DateTime.now()),
      ],
    );
    if (!profile.isDeafOrHardOfHearing) {
      unawaited(ref.read(ttsServiceProvider).speak(text, language: profile.language));
    }
  }

  Future<void> sendFreeText(String text, UserProfile profile) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _appendUserMessage(trimmed);

    final d = Dashboard.of(profile.language);

    // Best-effort cached fix rather than `getCurrentPosition()` — a chat
    // reply doesn't need a fresh GPS lock badly enough to justify the
    // battery/latency cost of forcing one (see hardware-constraint
    // guardrails in `project_master_plan.md`). Isolated in its own
    // try/catch: `geolocator_web` throws `UnimplementedError` for this
    // call outright (no native "last known fix" concept in browsers), and
    // that must not be mistaken for a Gemini/local-match failure below —
    // it would silently mask every real success/failure on web.
    Position? location;
    try {
      location = await Geolocator.getLastKnownPosition();
    } catch (_) {
      // No last-known fix available (denied permission, web, first launch
      // before any GPS read) — proceed without it.
    }

    // Checked before ever touching Gemini — `LocalIntentMatcher` recognizes
    // the common, unambiguous settings-change/trigger commands (explicit
    // user request: save the latency and token cost of a full LLM round
    // trip for these, while still falling through to Gemini for anything
    // it isn't confident about). `FunctionCallExecutor` is what actually
    // applies the change — the exact same code Gemini's own function
    // calling uses, so the effect and wording are identical either way.
    final localIntent = LocalIntentMatcher.match(trimmed, profile.language);
    if (localIntent != null) {
      debugPrint('[Chat] local match: ${localIntent.name} ${localIntent.args} (skipping Gemini)');
      final args = _resolveLocalIntentArgs(localIntent, profile);
      final turn = await ref
          .read(functionCallExecutorProvider)
          .execute(name: localIntent.name, args: args, profile: profile, location: location);
      if (turn.updatedProfile != null) {
        await ref.read(profileServiceProvider).saveProfile(turn.updatedProfile!);
      }
      await _appendAssistantReply(turn.responseText, profile);
      if (turn.overlayAction != null) {
        state = state.copyWith(pendingOverlayAction: turn.overlayAction);
      }
      if (turn.route != null) {
        state = state.copyWith(pendingRoute: turn.route);
      }
      return;
    }

    final gemini = ref.read(geminiAssistantServiceProvider);
    if (gemini == null) {
      await _appendAssistantReply(d.chatStubReply, profile);
      return;
    }

    // Snapshot history *before* the message just appended above, so it
    // isn't duplicated when handed to Gemini as prior turns.
    final history =
        state.messages.length > 1 ? state.messages.sublist(0, state.messages.length - 1) : const <ChatMessage>[];

    final stopwatch = Stopwatch()..start();
    // Set the instant the first streamed chunk of a plain-text reply
    // arrives — lets the rest of this method tell "already showing a
    // streaming bubble, just reconcile/finish it" apart from "never
    // streamed anything, append normally" (the function-call and
    // stub/fallback paths, where no partial text ever arrives — see
    // `GeminiAssistantService.converse`'s doc comment).
    var streaming = false;
    try {
      debugPrint('[Chat] -> Gemini: "$trimmed"');
      state = state.copyWith(isAssistantTyping: true);
      final turn = await gemini.converse(
        userText: trimmed,
        profile: profile,
        recentHistory: history,
        location: location,
        onPartialText: (partial) {
          if (!streaming) {
            streaming = true;
            state = state.copyWith(
              isAssistantTyping: false,
              messages: [
                ...state.messages,
                ChatMessage(sender: ChatSender.assistant, text: partial, timestamp: DateTime.now()),
              ],
            );
          } else {
            state = state.copyWith(messages: _withLastReplaced(text: partial));
          }
        },
      );
      debugPrint(
          '[Chat] <- Gemini in ${stopwatch.elapsedMilliseconds}ms: "${turn.responseText}" '
          '(overlay=${turn.overlayAction}, route=${turn.route != null}, profileChanged=${turn.updatedProfile != null})');
      if (turn.updatedProfile != null) {
        await ref.read(profileServiceProvider).saveProfile(turn.updatedProfile!);
      }
      if (streaming) {
        // Reconcile with the final text (normally identical to the last
        // streamed chunk already shown) and speak it now — streaming only
        // ever updated the bubble, nothing was spoken chunk-by-chunk.
        state = state.copyWith(isAssistantTyping: false, messages: _withLastReplaced(text: turn.responseText));
        if (!profile.isDeafOrHardOfHearing) {
          unawaited(ref.read(ttsServiceProvider).speak(turn.responseText, language: profile.language));
        }
      } else {
        await _appendAssistantReply(turn.responseText, profile);
      }
      if (turn.overlayAction != null) {
        state = state.copyWith(pendingOverlayAction: turn.overlayAction);
      }
      if (turn.route != null) {
        state = state.copyWith(pendingRoute: turn.route);
      }
    } catch (e, st) {
      state = state.copyWith(isAssistantTyping: false);
      // Previously a bare `catch (_)` — silently swallowed *every* Gemini
      // failure (network, quota, malformed response, anything) with zero
      // visibility into why, then fell back to `OfflineIntentMatcher`,
      // which only recognizes a handful of safety keywords (help/stop/
      // where-am-i/emergency). Confirmed live: this is why "screen দেখাও"
      // (or any other intent the offline matcher doesn't know) silently
      // did nothing instead of opening Show Screen — Gemini's real call
      // was failing for an unknown reason, and there was no way to tell.
      debugPrint('[Chat] Gemini call FAILED after ${stopwatch.elapsedMilliseconds}ms: $e');
      debugPrintStack(stackTrace: st, label: '[Chat] Gemini failure stack');
      final fallback = OfflineIntentMatcher.match(trimmed, profile.language) ?? d.chatStubReply;
      await _appendAssistantReply(fallback, profile);
    }
  }

  /// Chips that are pure chat replies. [SuggestedChipAction.showScreenToPasserby]
  /// and [SuggestedChipAction.reportHazard] open overlays instead — the
  /// dashboard screen handles those directly rather than routing them
  /// through here.
  Future<void> handleChip(SuggestedChip chip, UserProfile profile, String chipLabel) async {
    final d = Dashboard.of(profile.language);
    _appendUserMessage(chipLabel);
    switch (chip.action) {
      case SuggestedChipAction.routeToWork:
        // No fixed "work" address exists in the profile (only Home/Safe
        // Place) — matches this app's "ask the AI" philosophy instead of
        // adding a new onboarding field: the assistant asks, and that
        // question sitting in the recent-message history Gemini sees is
        // enough context for `request_route` to pick up a bare place name
        // on the very next turn (see `GeminiAssistantService._buildPrompt`).
        await _appendAssistantReply(d.chatAskDestination, profile);
      case SuggestedChipAction.scanBusSign:
        await _appendAssistantReply(d.chatStubBusScan, profile);
      case SuggestedChipAction.showScreenToPasserby:
      case SuggestedChipAction.reportHazard:
        break; // Handled by the screen — see above.
    }
  }
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);
