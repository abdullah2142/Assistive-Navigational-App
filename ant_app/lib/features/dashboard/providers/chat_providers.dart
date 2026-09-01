import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../models/chat_message.dart';
import '../models/suggested_chip.dart';

class ChatState {
  const ChatState({this.messages = const [], this.isAssistantTyping = false});

  final List<ChatMessage> messages;
  final bool isAssistantTyping;

  ChatState copyWith({List<ChatMessage>? messages, bool? isAssistantTyping}) => ChatState(
        messages: messages ?? this.messages,
        isAssistantTyping: isAssistantTyping ?? this.isAssistantTyping,
      );
}

/// Drives the Dynamic Chat Stream on the Split-Mode Dashboard.
///
/// Module 2 scope stops at the UI shell: [_stubReply] returns canned text so
/// the chat stream, suggested chips, and overlay triggers are all fully
/// wired and demoable. Module 3 (`03_module_plan_ai_assistant.md`) replaces
/// [_stubReply] with real Gemini Pro function calling — STT input, TTS
/// output, and intercepting intents like "make the text bigger" to mutate
/// the Firestore `UserProfile` — without needing to touch this controller's
/// public API.
///
/// Language-aware via a [Dashboard] instance passed into each method rather
/// than baked into state — this stays a plain [Notifier] (not a `.family`
/// keyed by language) since the same conversation shouldn't reset if
/// someone changes their language mid-session in Settings.
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

  void _appendUserMessage(String text) {
    state = state.copyWith(messages: [
      ...state.messages,
      ChatMessage(sender: ChatSender.user, text: text, timestamp: DateTime.now()),
    ]);
  }

  Future<void> _appendAssistantReply(String text) async {
    state = state.copyWith(isAssistantTyping: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    state = state.copyWith(
      isAssistantTyping: false,
      messages: [
        ...state.messages,
        ChatMessage(sender: ChatSender.assistant, text: text, timestamp: DateTime.now()),
      ],
    );
  }

  Future<void> sendFreeText(String text, Dashboard d) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _appendUserMessage(trimmed);
    await _appendAssistantReply(d.chatStubReply);
  }

  /// Chips that are pure chat replies. [SuggestedChipAction.showScreenToPasserby]
  /// and [SuggestedChipAction.reportHazard] open overlays instead — the
  /// dashboard screen handles those directly rather than routing them
  /// through here.
  Future<void> handleChip(SuggestedChip chip, Dashboard d, String chipLabel) async {
    _appendUserMessage(chipLabel);
    switch (chip.action) {
      case SuggestedChipAction.routeToWork:
        await _appendAssistantReply(d.chatStubRoute);
      case SuggestedChipAction.scanBusSign:
        await _appendAssistantReply(d.chatStubBusScan);
      case SuggestedChipAction.showScreenToPasserby:
      case SuggestedChipAction.reportHazard:
        break; // Handled by the screen — see above.
    }
  }
}

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(ChatController.new);
