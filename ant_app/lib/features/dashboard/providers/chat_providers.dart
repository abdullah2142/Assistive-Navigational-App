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
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/services/destination_clarifier.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';

class ChatState {
  const ChatState({
    this.messages = const [],
    this.isAssistantTyping = false,
    this.pendingOverlayAction,
    this.pendingHazardPrefill,
    this.pendingRoute,
    this.pendingClarification,
    this.lastSettingChanged,
  });

  final List<ChatMessage> messages;
  final bool isAssistantTyping;

  /// Set when the AI Assistant's function calling decided the Passerby
  /// Helper or Hazard Report overlay should open — `ChatStreamPanel` (which
  /// owns a `BuildContext`, this plain `Notifier` doesn't) watches for this
  /// and opens it via the same path a suggested chip tap uses, then calls
  /// [ChatController.clearPendingOverlay].
  final SuggestedChipAction? pendingOverlayAction;

  /// Accompanies a [pendingOverlayAction] of
  /// [SuggestedChipAction.reportHazard] when the command that triggered it
  /// already named the hazard — cleared by the same
  /// [ChatController.clearPendingOverlay] call.
  final HazardReportPrefill? pendingHazardPrefill;

  /// Set when `request_route` (Module 4) successfully planned a route — the
  /// map widget watches this to draw the polyline and rotate the giant
  /// directional arrow. Stays set (unlike `pendingOverlayAction`, which is a
  /// one-shot trigger) for as long as a route is active; cleared via
  /// [ChatController.clearRoute].
  final RouteChoice? pendingRoute;

  /// Set while the assistant is working out where a destination actually
  /// is. Its presence changes how the *next* message is read: an answer to
  /// the question just asked, rather than a fresh command. See
  /// [DestinationClarification].
  final DestinationClarification? pendingClarification;

  /// The setting the user most recently changed by voice, so a bare
  /// follow-up ("even bigger") knows what it is adjusting. See
  /// `LocalIntentMatcher.match`'s `recentSetting`.
  final String? lastSettingChanged;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isAssistantTyping,
    SuggestedChipAction? pendingOverlayAction,
    HazardReportPrefill? pendingHazardPrefill,
    bool clearOverlay = false,
    RouteChoice? pendingRoute,
    bool clearRoute = false,
    DestinationClarification? pendingClarification,
    bool clearClarification = false,
    String? lastSettingChanged,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        isAssistantTyping: isAssistantTyping ?? this.isAssistantTyping,
        pendingOverlayAction: clearOverlay ? null : (pendingOverlayAction ?? this.pendingOverlayAction),
        pendingHazardPrefill: clearOverlay ? null : (pendingHazardPrefill ?? this.pendingHazardPrefill),
        pendingRoute: clearRoute ? null : (pendingRoute ?? this.pendingRoute),
        pendingClarification:
            clearClarification ? null : (pendingClarification ?? this.pendingClarification),
        lastSettingChanged: lastSettingChanged ?? this.lastSettingChanged,
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

  /// Handles one turn of the "where is that, exactly?" conversation.
  ///
  /// Returns true when the reply was consumed as an answer. Returns false
  /// when it was plainly a new instruction instead — a user is allowed to
  /// abandon a half-finished clarification by simply asking for something
  /// else, and forcing them to formally cancel first would be its own trap.
  Future<bool> _continueClarification(
    DestinationClarification pending,
    String reply,
    UserProfile profile,
    Position? location,
    Dashboard d,
  ) async {
    // An unmistakable command wins over the pending question. Only route
    // requests and the safety-critical triggers qualify — a stray settings
    // phrase should not silently discard the destination being worked out.
    final escape = LocalIntentMatcher.match(reply, profile.language);
    if (escape != null &&
        const {'request_route', 'open_passerby_helper', 'open_hazard_report'}.contains(escape.name)) {
      state = state.copyWith(clearClarification: true);
      return false;
    }

    final outcome = DestinationClarifier.interpret(
      reply: reply,
      pending: pending,
      language: profile.language,
    );

    switch (outcome) {
      case ClarificationCancelled():
        state = state.copyWith(clearClarification: true);
        await _appendAssistantReply(d.clarifyCancelled, profile);
        return true;

      case ClarificationUnclear():
        // Exhausted, or nothing usable in the reply. Either way, stop
        // asking the same thing — see `clarifyGaveUp`, which ends with
        // something the user can actually do.
        if (pending.isExhausted) {
          state = state.copyWith(clearClarification: true);
          await _appendAssistantReply(d.clarifyGaveUp(pending.originalQuery), profile);
        } else {
          await _appendAssistantReply(d.clarifyUnclear, profile);
        }
        return true;

      case ClarificationResolved(:final candidate):
        state = state.copyWith(clearClarification: true);
        await _planClarifiedRoute(
          query: candidate.label,
          label: candidate.spokenLabel,
          known: candidate.location,
          profile: profile,
          location: location,
          d: d,
        );
        return true;

      case ClarificationRefined(:final updated):
        state = state.copyWith(pendingClarification: updated);
        await _planClarifiedRoute(
          query: updated.combinedQuery,
          label: null,
          known: null,
          profile: profile,
          location: location,
          d: d,
          pending: updated,
        );
        return true;
    }
  }

  /// Retries routing with whatever the clarification has learned so far,
  /// and asks the next question if it still is not enough.
  Future<void> _planClarifiedRoute({
    required String query,
    required String? label,
    required LatLng? known,
    required UserProfile profile,
    required Position? location,
    required Dashboard d,
    DestinationClarification? pending,
  }) async {
    if (location == null) {
      await _appendAssistantReply(d.mapUnavailableSubtitle, profile);
      return;
    }
    state = state.copyWith(isAssistantTyping: true);
    final result = await ref.read(routePlanningServiceProvider).plan(
          destinationQuery: query,
          destinationLabel: label,
          knownDestination: known,
          origin: LatLng(location.latitude, location.longitude),
        );
    state = state.copyWith(isAssistantTyping: false);

    switch (result) {
      case RoutePlanned(:final choice):
        state = state.copyWith(pendingRoute: choice, clearClarification: true);
        // A place that took several questions to find is exactly the one
        // worth never having to find again.
        await _appendAssistantReply(
          '${d.savedPlaceRouting(choice.destinationLabel)} '
          '${d.clarifyResolvedOfferSave(choice.destinationLabel)}',
          profile,
        );
        _startNavigation(choice, profile);

      case RoutePlanAmbiguous(:final options):
        state = state.copyWith(
          pendingClarification: (pending ?? DestinationClarification(originalQuery: query))
              .offering(options),
        );
        await _appendAssistantReply(
          d.clarifyChooseOption(options.map((o) => o.spokenLabel).toList()),
          profile,
        );

      case RoutePlanFailed(:final reason):
        if (reason != 'destination_not_found' || pending == null) {
          state = state.copyWith(clearClarification: true);
          await _appendAssistantReply(d.hazardResolveNothingToClear, profile);
          return;
        }
        if (pending.isExhausted) {
          state = state.copyWith(clearClarification: true);
          await _appendAssistantReply(d.clarifyGaveUp(pending.originalQuery), profile);
          return;
        }
        // Each round asks for a *different* kind of clue. A user who could
        // answer "where is it?" would have answered it the first time.
        await _appendAssistantReply(
          pending.attempts <= 1
              ? d.clarifyAskArea(pending.originalQuery)
              : d.clarifyAskLandmark(pending.originalQuery),
          profile,
        );
    }
  }

  /// Begins spoken turn-by-turn guidance the moment a route is accepted.
  ///
  /// Not gated behind a "start navigation" tap: for a user who cannot see
  /// the map, a planned-but-silent route is not usable at all — the arrow
  /// and the polyline are the sighted half of this feature, and the spoken
  /// directions are the whole of the other half.
  void _startNavigation(RouteChoice route, UserProfile profile) {
    ref.read(navigationControllerProvider).start(route, language: profile.language);
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

    // A question we just asked takes priority over reading the next
    // message as a fresh command. Without this, "it's in Mirpur" — a
    // perfectly good answer to "which area is it in?" — falls through to
    // the intent matcher, matches nothing, and goes to Gemini as though
    // the assistant had never asked anything, losing the thread entirely.
    final pending = state.pendingClarification;
    if (pending != null) {
      final handled = await _continueClarification(pending, trimmed, profile, location, d);
      if (handled) return;
    }

    // Checked before ever touching Gemini — `LocalIntentMatcher` recognizes
    // the common, unambiguous settings-change/trigger commands (explicit
    // user request: save the latency and token cost of a full LLM round
    // trip for these, while still falling through to Gemini for anything
    // it isn't confident about). `FunctionCallExecutor` is what actually
    // applies the change — the exact same code Gemini's own function
    // calling uses, so the effect and wording are identical either way.
    final localIntent = LocalIntentMatcher.match(
      trimmed,
      profile.language,
      recentSetting: state.lastSettingChanged,
    );
    if (localIntent != null) {
      debugPrint('[Chat] local match: ${localIntent.name} ${localIntent.args} (skipping Gemini)');
      final args = _resolveLocalIntentArgs(localIntent, profile);
      final turn = await ref
          .read(functionCallExecutorProvider)
          .execute(
            name: localIntent.name,
            args: args,
            profile: profile,
            location: location,
            // `resolve_hazard` is scoped to whatever the user is currently
            // walking — see `_applyResolveHazard`.
            activeRoute: state.pendingRoute,
          );
      if (turn.updatedProfile != null) {
        await ref.read(profileServiceProvider).saveProfile(turn.updatedProfile!);
      }
      await _appendAssistantReply(turn.responseText, profile);
      if (turn.overlayAction != null) {
        state = state.copyWith(
          pendingOverlayAction: turn.overlayAction,
          pendingHazardPrefill: turn.hazardPrefill,
        );
      }
      if (turn.route != null) {
        state = state.copyWith(pendingRoute: turn.route);
        _startNavigation(turn.route!, profile);
      }
      if (turn.clarification != null) {
        state = state.copyWith(pendingClarification: turn.clarification);
      }
      if (turn.clarification != null) {
        state = state.copyWith(pendingClarification: turn.clarification);
      }
      if (localIntent.name == 'update_setting') {
        state = state.copyWith(lastSettingChanged: args['setting'] as String?);
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
        // Scopes `resolve_hazard` to what the user is actually walking.
        activeRoute: state.pendingRoute,
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
        state = state.copyWith(
          pendingOverlayAction: turn.overlayAction,
          pendingHazardPrefill: turn.hazardPrefill,
        );
      }
      if (turn.route != null) {
        state = state.copyWith(pendingRoute: turn.route);
        _startNavigation(turn.route!, profile);
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
