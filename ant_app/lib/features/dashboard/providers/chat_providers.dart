import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/config/emergency_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/services/vision/snapshot_vision_service.dart';
import '../../../core/services/vision/vision_scene.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/local_intent_matcher.dart';
import '../../../core/services/offline_intent_matcher.dart';
import '../../../core/services/pending_place_save.dart';
import '../../../core/services/route_planning_service.dart';
import '../../../core/services/routing_service.dart' show RouteCandidate;
import '../../guardian/models/communication_message.dart';
import '../../guardian/providers/guardian_providers.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../../onboarding/models/user_profile.dart';
import '../../onboarding/providers/onboarding_providers.dart';
import '../models/chat_message.dart';
import '../services/chat_history_store.dart';

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/services/destination_clarifier.dart';
import '../../../core/utils/text_scale_levels.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';

class ChatState {
  const ChatState({
    this.messages = const [],
    this.isAssistantTyping = false,
    this.pendingOverlayAction,
    this.pendingHazardPrefill,
    this.pendingRoute,
    this.routeAlternatives = const [],
    this.pendingClarification,
    this.pendingPlaceSave,
    this.lastSettingChanged,
    this.answerInvitations = 0,
    this.caretakerMessageArmed = false,
  });

  final List<ChatMessage> messages;
  final bool isAssistantTyping;

  /// Bumped each time the assistant finishes *asking* the user something and
  /// the microphone should open for the answer — item 60.
  ///
  /// A counter rather than a flag: two questions in a row are two
  /// invitations, and a bool would only change value on the first. The panel
  /// owns the microphone and watches this; this notifier cannot open one.
  ///
  /// Bumped only *after* the question has finished being spoken, so the
  /// recognizer is never opened underneath the app's own voice — which is
  /// item 23, and the single easiest way to reintroduce it.
  final int answerInvitations;

  /// True only while a voice command is waiting for the user's next written
  /// or spoken input to forward as a caretaker message.
  final bool caretakerMessageArmed;

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

  /// The other walking routes found alongside [pendingRoute], kept so
  /// "give me a different route" has something to switch to.
  ///
  /// They used to be thrown away the instant the safest one was picked,
  /// which is why the assistant could announce that a route passed a risky
  /// area and then offer nothing to do about it. Not safety-checked until
  /// one is actually taken — see [RoutePlanned.alternatives].
  final List<RouteCandidate> routeAlternatives;

  /// Set while the assistant is working out where a destination actually
  /// is. Its presence changes how the *next* message is read: an answer to
  /// the question just asked, rather than a fresh command. See
  /// [DestinationClarification].
  final DestinationClarification? pendingClarification;

  /// Set while the assistant is waiting to hear what to call a place the
  /// user asked it to save. Its presence changes how the *next* message is
  /// read — an answer, not a fresh command. See [PendingPlaceSave].
  final PendingPlaceSave? pendingPlaceSave;

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
    List<RouteCandidate>? routeAlternatives,
    bool clearRoute = false,
    DestinationClarification? pendingClarification,
    bool clearClarification = false,
    PendingPlaceSave? pendingPlaceSave,
    bool clearPlaceSave = false,
    String? lastSettingChanged,
    int? answerInvitations,
    bool? caretakerMessageArmed,
  }) => ChatState(
    messages: messages ?? this.messages,
    isAssistantTyping: isAssistantTyping ?? this.isAssistantTyping,
    pendingOverlayAction: clearOverlay
        ? null
        : (pendingOverlayAction ?? this.pendingOverlayAction),
    pendingHazardPrefill: clearOverlay
        ? null
        : (pendingHazardPrefill ?? this.pendingHazardPrefill),
    pendingRoute: clearRoute ? null : (pendingRoute ?? this.pendingRoute),
    routeAlternatives: clearRoute
        ? const []
        : (routeAlternatives ?? this.routeAlternatives),
    pendingClarification: clearClarification
        ? null
        : (pendingClarification ?? this.pendingClarification),
    pendingPlaceSave: clearPlaceSave
        ? null
        : (pendingPlaceSave ?? this.pendingPlaceSave),
    lastSettingChanged: lastSettingChanged ?? this.lastSettingChanged,
    answerInvitations: answerInvitations ?? this.answerInvitations,
    caretakerMessageArmed: caretakerMessageArmed ?? this.caretakerMessageArmed,
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
  Future<bool> Function()? _cameraAimer;
  Future<void> Function()? _cameraAimFinisher;
  bool _oneShotCaretakerMessage = false;

  /// The dashboard owns the camera UI/context; the controller requests a
  /// short aim session before every explicit scan or user-requested photo.
  void registerCameraAimer(
    Future<bool> Function()? aim, {
    Future<void> Function()? finish,
  }) {
    _cameraAimer = aim;
    _cameraAimFinisher = finish;
  }

  Future<bool> _aimCamera() async => await _cameraAimer?.call() ?? true;
  Future<void> _finishCameraAim() async {
    final finish = _cameraAimFinisher;
    if (finish != null) await finish();
  }

  Future<void> sendCaretakerText(String text, UserProfile profile) async {
    _oneShotCaretakerMessage = false;
    state = state.copyWith(caretakerMessageArmed: false);
    final value = text.trim();
    if (value.isEmpty) return;
    _turnGeneration++;
    _appendUserMessage(value);
    await _deliverCaretakerText(value, profile);
  }

  Future<void> _deliverCaretakerText(String text, UserProfile profile) async {
    final caretakerUid = profile.pairedUserId;
    final d = Dashboard.of(profile.language);
    if (caretakerUid == null) {
      await _appendAssistantReply(d.alertCaretakerNotPaired, profile);
      return;
    }
    try {
      await ref
          .read(communicationServiceProvider)
          .sendMemo(
            disabledUserUid: profile.uid,
            fromUid: profile.uid,
            toUid: caretakerUid,
            text: text,
          );
      await _appendAssistantReply(d.caretakerMemoSent, profile);
    } catch (e) {
      debugPrint('[Chat] caretaker message failed: $e');
      await _appendAssistantReply(d.caretakerMessageFailed, profile);
    }
  }

  Future<void> sendPhotoToCaretaker(UserProfile profile) {
    _oneShotCaretakerMessage = false;
    state = state.copyWith(caretakerMessageArmed: false);
    return _sendPhotoToCaretaker(profile, Dashboard.of(profile.language));
  }

  void clearOneShotCaretakerMessage() {
    _oneShotCaretakerMessage = false;
    state = state.copyWith(caretakerMessageArmed: false);
  }

  Future<void> announceCaretakerVoiceMemoSent(UserProfile profile) =>
      _appendAssistantReply(
        Dashboard.of(profile.language).caretakerMemoSent,
        profile,
      );

  void appendOutgoingCaretakerVoiceMemo(
    String audioBase64,
    int durationSeconds,
  ) {
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.user,
          text: '',
          timestamp: DateTime.now(),
          audioBase64: audioBase64,
          audioDurationSeconds: durationSeconds,
        ),
      ],
    );
  }

  @override
  ChatState build() {
    // Every spoken navigation cue also lands in the chat as text.
    //
    // `NavigationController` has emitted these since Module 4 and nothing
    // read them, which meant turn-by-turn guidance existed *only* as speech.
    // For a Deaf or hard-of-hearing user that is not a degraded experience,
    // it is no experience: the app plans the route, announces it to an empty
    // room, and then says nothing they can perceive for the rest of the
    // walk. The map banner covers it too, but the map is hidden by default
    // on this dashboard — the chat is the surface they are actually looking
    // at.
    final navigation = ref.read(navigationControllerProvider);
    final cues = navigation.spokenCues.listen(_onNavigationCue);
    ref.onDispose(cues.cancel);
    // Arrival ends the walk, and is watched separately from the cue stream
    // so it cannot depend on the order the controller happens to speak and
    // stop in. Without this the route stayed "active" indefinitely: the map
    // kept drawing a line the user had already walked, and `resolve_hazard`
    // stayed scoped to a journey that finished hours ago. `clearRoute`
    // existed for exactly this and nothing ever called it.
    void onProgress() {
      if (navigation.progress.value?.arrived ?? false)
        state = state.copyWith(clearRoute: true);
    }

    navigation.progress.addListener(onProgress);
    ref.onDispose(() => navigation.progress.removeListener(onProgress));
    ref.onDispose(_history.dispose);
    return const ChatState();
  }

  late final ChatHistoryStore _history = ref.read(chatHistoryStoreProvider);

  /// Saves the transcript on every state change — item 52.
  ///
  /// Hooked here rather than at each call site because there are twenty-eight
  /// places that append a message, and the difference between this working
  /// and this working *until somebody adds a twenty-ninth* is exactly whether
  /// it is someone's job to remember. Writing is debounced inside the store,
  /// so a burst of state changes is still one file write.
  @override
  set state(ChatState value) {
    final before = super.state.messages;
    super.state = value;
    if (!identical(before, value.messages)) _rememberTranscript();
  }

  /// Whose transcript is on screen, so a save can be keyed to them and a
  /// restore can refuse somebody else's.
  String? _transcriptUid;

  /// Brings back the conversation from last time — item 52.
  ///
  /// Called by the panel once it knows who is signed in. Idempotent, and it
  /// never overwrites a conversation already in progress: a restore landing
  /// on top of messages the user has already sent would be a worse bug than
  /// the one it fixes.
  Future<void> restoreHistory(String uid, Dashboard d) async {
    if (_transcriptUid == uid) return;
    _transcriptUid = uid;
    final restored = await _history.load(uid);
    if (restored.isEmpty) return;
    if (state.messages.length > 1) return;
    // The welcome line is re-added by `ensureWelcomeMessage` on a fresh
    // start; dropping it here stops a second one accumulating on top of a
    // restored transcript every single launch.
    state = state.copyWith(messages: restored);
  }

  /// Persists the transcript. Debounced inside the store.
  void _rememberTranscript() {
    final uid = _transcriptUid;
    if (uid == null) return;
    _history.save(uid, state.messages);
  }

  /// Appended, never re-spoken — [NavigationController] said it as it
  /// emitted it, and hearing every turn twice is worse than not seeing it.
  void _onNavigationCue(String text) {
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.assistant,
          text: text,
          timestamp: DateTime.now(),
        ),
      ],
    );
  }

  /// Called once by the widget as soon as it knows the current language —
  /// idempotent, so calling it again after the first message is a no-op.
  void ensureWelcomeMessage(Dashboard d) {
    if (state.messages.isNotEmpty) return;
    state = state.copyWith(
      messages: [
        ChatMessage(
          sender: ChatSender.assistant,
          text: d.chatWelcome,
          timestamp: DateTime.now(),
        ),
      ],
    );
  }

  void clearPendingOverlay() => state = state.copyWith(clearOverlay: true);

  void clearRoute() => state = state.copyWith(clearRoute: true);

  /// Replaces the last message's text in place, keeping its sender/timestamp
  /// — used while a streaming reply is filling in, when what's needed is
  /// "update the bubble that's already there," not "add another one".
  /// Drops a half-streamed bubble belonging to a turn the user has moved past.
  List<ChatMessage> _withoutLastAssistantBubble() {
    final messages = state.messages;
    if (messages.isEmpty || messages.last.sender != ChatSender.assistant)
      return messages;
    return messages.sublist(0, messages.length - 1);
  }

  List<ChatMessage> _withLastReplaced({required String text}) {
    final messages = List<ChatMessage>.from(state.messages);
    if (messages.isEmpty) return messages;
    final last = messages.removeLast();
    messages.add(
      ChatMessage(
        sender: last.sender,
        text: text,
        timestamp: last.timestamp,
        messageId: last.id,
        replyToMessageId: last.replyToMessageId,
        replyToText: last.replyToText,
      ),
    );
    return messages;
  }

  /// `LocalIntentMatcher` can't know the user's *current* font scale (it
  /// has no profile to look at, by design — it's a stateless text
  /// matcher), so a "bigger text"/"smaller text" match comes back with a
  /// sentinel value instead of a number; resolved into an actual clamped
  /// scale here, where the live profile is available.
  /// Entry point for the physical trigger (Volume Down held).
  ///
  /// Public because it does not come from a typed or spoken message and so
  /// has no path through `sendFreeText`.
  Future<void> triggerEmergency(UserProfile profile) => _runEmergency(profile);

  /// Delivers a message the caretaker sent, aloud and into the chat.
  ///
  /// Module 8's receiving half. The chat stream is deliberately reused rather
  /// than given its own inbox screen: it is the one surface this user already
  /// knows, it is already read aloud, and a separate screen is a place a blind
  /// user has to be told to go and look at.
  ///
  /// Returns the audio, if any, for the caller to play — this controller owns
  /// text and state, not the speaker.
  Future<void> receiveCaretakerMessage(
    CommunicationMessage message,
    UserProfile profile, {
    Future<bool> Function(String audioBase64)? playAudio,
  }) async {
    final d = Dashboard.of(profile.language);
    switch (message.type) {
      case CommunicationType.memo:
        if (message.text.trim().isEmpty) return;
        _appendCaretakerMessage(message.text.trim(), messageId: message.id);
        await _appendAssistantReply(
          d.caretakerMemoHeard(message.text.trim()),
          profile,
        );
      case CommunicationType.voiceMemo:
        // Kept so it can be played again later — see `replayVoiceMemo`.
        // Appended before playback so a clip that fails to play is still
        // reachable: "play that again" is exactly what a user says when they
        // did not hear it the first time.
        _voiceInbox.add(message);
        _inboxCursor = _voiceInbox.length - 1;
        final audio = message.audioBase64;
        _appendCaretakerMessage(
          d.caretakerVoiceMemoHeard,
          messageId: message.id,
          audioBase64: audio,
          audioDurationSeconds: message.durationSeconds,
        );
        // Announced first, then played. The announcement is what tells a user
        // who cannot see the screen that the sound about to come out of their
        // phone is their caretaker and not the assistant.
        await _appendAssistantReply(d.caretakerVoiceMemoHeard, profile);
        if (audio == null || playAudio == null) return;
        if (!await playAudio(audio)) {
          await _appendAssistantReply(d.caretakerVoiceMemoUnplayable, profile);
        }
      case CommunicationType.snapshotRequest:
        await _appendAssistantReply(d.caretakerSnapshotRequested, profile);
        // Consent is read here for the first time. Onboarding has been
        // collecting it since Module 1 and nothing has ever looked at it.
        if (profile.snapshotConsent == SnapshotConsentPreference.never) {
          await _appendAssistantReply(d.caretakerSnapshotDeclined, profile);
          return;
        }
        if (profile.snapshotConsent == SnapshotConsentPreference.askEachTime) {
          // Asked, not assumed. `mayInviteAnswer` reopens the microphone, so
          // the answer is one spoken word away — see `_pendingSnapshotFor`.
          _pendingSnapshotFor = message.fromUid;
          await _appendAssistantReply(
            d.caretakerSnapshotAsk,
            profile,
            mayInviteAnswer: true,
          );
          return;
        }
        await _captureForCaretaker(profile, d, caretakerUid: message.fromUid);

      // Sent by this device, never received by it — the guardian is the one
      // who reads a reply. Present so the switch stays total.
      case CommunicationType.snapshotReply:
        return;

      case CommunicationType.photo:
        // Announced and then *described*. A picture arriving silently on a
        // screen the user cannot see is a message that was not delivered, so
        // the vision tier reads it out — the caretaker sent it to say
        // something, and this is the only way that something arrives.
        await _appendAssistantReply(d.caretakerPhotoArrived, profile);
        final jpeg = message.imageBase64;
        if (jpeg == null || jpeg.isEmpty) {
          await _appendAssistantReply(d.caretakerPhotoUnreadable, profile);
          return;
        }
        await _describeIncomingPhoto(jpeg, profile, d);
    }
  }

  void _appendCaretakerMessage(
    String text, {
    required String messageId,
    String? audioBase64,
    int? audioDurationSeconds,
  }) {
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.caretaker,
          text: text,
          timestamp: DateTime.now(),
          messageId: 'caretaker-$messageId',
          audioBase64: audioBase64,
          audioDurationSeconds: audioDurationSeconds,
        ),
      ],
    );
    // The audio itself is intentionally not persisted; keep the visible
    // sender and transcript line, which still explains that a memo arrived.
    _rememberTranscript();
  }

  /// Rehydrates tap-to-play memo bubbles and the replay cursor from Firestore
  /// without announcing old messages aloud each time the dashboard opens.
  void restoreCaretakerInbox(
    List<CommunicationMessage> messages,
    UserProfile profile,
  ) {
    final ordered = messages.toList()
      ..sort(
        (a, b) => (a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0)),
      );
    final present = state.messages.map((m) => m.id).toSet();
    final additions = <ChatMessage>[];
    for (final message in ordered) {
      if (message.type == CommunicationType.voiceMemo) {
        if (!_voiceInbox.any((memo) => memo.id == message.id))
          _voiceInbox.add(message);
        final id = 'caretaker-${message.id}';
        if (!present.contains(id)) {
          additions.add(
            ChatMessage(
              sender: ChatSender.caretaker,
              text: Dashboard.of(profile.language).caretakerVoiceMemoHeard,
              timestamp: message.createdAt ?? DateTime.now(),
              messageId: id,
              audioBase64: message.audioBase64,
              audioDurationSeconds: message.durationSeconds,
            ),
          );
        }
      } else if (message.type == CommunicationType.memo &&
          message.text.trim().isNotEmpty) {
        final id = 'caretaker-${message.id}';
        if (!present.contains(id)) {
          additions.add(
            ChatMessage(
              sender: ChatSender.caretaker,
              text: message.text.trim(),
              timestamp: message.createdAt ?? DateTime.now(),
              messageId: id,
            ),
          );
        }
      }
    }
    if (_voiceInbox.isNotEmpty) _inboxCursor = _voiceInbox.length - 1;
    if (additions.isNotEmpty) {
      final merged = [...state.messages, ...additions]
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      state = state.copyWith(messages: merged);
    }
  }

  /// Takes a photo and sends it to the paired caretaker, because the user
  /// asked to.
  ///
  /// Distinct from answering a Snapshot Request: that is the caretaker
  /// asking and is governed by the snapshot-consent setting. This is the
  /// user choosing to show somebody something, which needs no permission
  /// from anyone — it is their camera and their message.
  ///
  /// The description goes with the picture. The user cannot see what they
  /// just sent, and "I sent them a photo of the bus stop" is the only way
  /// they can tell whether the camera was pointed at anything useful.
  Future<void> _sendPhotoToCaretaker(UserProfile profile, Dashboard d) async {
    final caretakerUid = profile.pairedUserId;
    if (caretakerUid == null) return;

    if (!await _aimCamera()) return;

    final vision = ref.read(snapshotVisionServiceProvider);
    try {
      ScanResult result;
      try {
        result = await vision.scan(
          focus: ScanFocus.ahead,
          language: profile.language,
        );
      } catch (e) {
        debugPrint('[Chat] photo for caretaker failed: $e');
        await _appendAssistantReply(d.caretakerSnapshotFailed, profile);
        return;
      }

      final frame = result.frameJpeg;
      if (frame == null) {
        await _appendAssistantReply(d.caretakerSnapshotFailed, profile);
        return;
      }

      try {
        await ref
            .read(communicationServiceProvider)
            .sendPhoto(
              disabledUserUid: profile.uid,
              fromUid: profile.uid,
              toUid: caretakerUid,
              imageBase64: base64Encode(frame),
              text: result.spoken,
            );
      } catch (e) {
        debugPrint('[Chat] could not send the photo: $e');
        await _appendAssistantReply(d.caretakerSnapshotFailed, profile);
        return;
      }
      await _appendAssistantReply(
        '${d.photoSentToCaretaker} ${result.spoken}',
        profile,
        imageJpeg: frame,
      );
    } finally {
      vision.closeCamera();
      await _finishCameraAim();
    }
  }

  /// Reads out a photo the caretaker sent.
  ///
  /// The description *is* the delivery for a blind user. A failure says so
  /// rather than going quiet — "they sent a photo I could not make out" is
  /// still news, and it is something the user can act on by asking their
  /// caretaker to describe it.
  Future<void> _describeIncomingPhoto(
    String jpegBase64,
    UserProfile profile,
    Dashboard d,
  ) async {
    Uint8List bytes;
    try {
      bytes = base64Decode(jpegBase64);
    } catch (e) {
      debugPrint('[Chat] a caretaker photo would not decode: $e');
      await _appendAssistantReply(d.caretakerPhotoUnreadable, profile);
      return;
    }
    final described = await ref
        .read(snapshotVisionServiceProvider)
        .describeIncomingImage(bytes, profile.language);
    await _appendAssistantReply(
      described ?? d.caretakerPhotoUnreadable,
      profile,
      // Shown as well as spoken — a low-vision user or a sighted helper
      // should see the picture the description is about.
      imageJpeg: bytes,
    );
  }

  /// Voice memos the caretaker has sent this session, oldest first, and
  /// where in them the user currently is.
  ///
  /// The whole of voicemail-style replay. A memo used to play exactly once,
  /// on arrival, and then be unreachable — which for somebody who cannot
  /// scroll back through a transcript means a message half-heard over
  /// traffic is a message gone. Held in memory rather than re-read from
  /// Firestore because the audio is already in hand and the session is the
  /// useful span: a memo from yesterday is not what "play it again" means.
  final List<CommunicationMessage> _voiceInbox = [];

  /// Points at the memo [replayVoiceMemo] acts on. Starts past the end so
  /// the first "play it again" means the newest one.
  int _inboxCursor = -1;

  /// Plays audio. Registered by `CaretakerInboxListener`, which owns the
  /// player — this notifier cannot hold one.
  Future<bool> Function(String audioBase64)? _audioPlayer;

  /// Lets the inbox listener lend its player for replays the user asks for
  /// later, not only for the memo arriving now.
  void registerAudioPlayer(Future<bool> Function(String audioBase64) play) {
    _audioPlayer = play;
  }

  /// How many voice memos are replayable. Exposed for the executor's reply.
  int get voiceMemoCount => _voiceInbox.length;

  /// Replays a caretaker voice memo.
  ///
  /// [direction] moves the cursor first: `latest` jumps to the newest,
  /// `repeat` stays put, `previous`/`next` step through. Clamped rather than
  /// wrapping — "next" at the newest should say there is nothing newer, not
  /// silently start again at the oldest, which sounds like the same message
  /// arriving twice.
  Future<void> replayVoiceMemo(
    ReplayDirection direction,
    UserProfile profile,
  ) async {
    final d = Dashboard.of(profile.language);
    if (_voiceInbox.isEmpty) {
      await _appendAssistantReply(d.voiceMemoNoneToReplay, profile);
      return;
    }

    final last = _voiceInbox.length - 1;
    final target = switch (direction) {
      ReplayDirection.latest => last,
      ReplayDirection.repeat => _inboxCursor < 0 ? last : _inboxCursor,
      ReplayDirection.previous => (_inboxCursor < 0 ? last : _inboxCursor) - 1,
      ReplayDirection.next => (_inboxCursor < 0 ? last : _inboxCursor) + 1,
    };

    if (target < 0) {
      await _appendAssistantReply(d.voiceMemoNoOlder, profile);
      return;
    }
    if (target > last) {
      await _appendAssistantReply(d.voiceMemoNoNewer, profile);
      return;
    }

    _inboxCursor = target;
    final memo = _voiceInbox[target];
    // Said before it plays, so a user who cannot see the screen knows which
    // of several they are about to hear — "the second of four" is the whole
    // point of stepping through them.
    await _appendAssistantReply(
      d.voiceMemoReplaying(target + 1, _voiceInbox.length),
      profile,
    );

    final audio = memo.audioBase64;
    final play = _audioPlayer;
    if (audio == null || play == null || !await play(audio)) {
      await _appendAssistantReply(d.caretakerVoiceMemoUnplayable, profile);
    }
  }

  /// Set while a Snapshot Request is waiting on a spoken yes or no, for a
  /// profile whose consent is "ask me each time". Holds the guardian's uid
  /// so the reply goes back to whoever asked.
  String? _pendingSnapshotFor;

  /// Consumes the next message as the answer to "shall I send a photo?".
  ///
  /// Returns true when it was an answer, so the caller stops — the words
  /// "yes" or "না" must not also reach the intent matcher and be read as a
  /// command. Anything that is neither a yes nor a no is *not* consumed: the
  /// user changed the subject, and the request lapses rather than swallowing
  /// an unrelated turn.
  Future<bool> _continueSnapshotConsent(
    String text,
    UserProfile profile,
    Dashboard d,
  ) async {
    final caretakerUid = _pendingSnapshotFor;
    if (caretakerUid == null) return false;
    final answer = _yesOrNo(text);
    if (answer == null) {
      _pendingSnapshotFor = null;
      return false;
    }
    _pendingSnapshotFor = null;
    if (!answer) {
      await _appendAssistantReply(d.caretakerSnapshotDeclined, profile);
      return true;
    }
    await _captureForCaretaker(profile, d, caretakerUid: caretakerUid);
    return true;
  }

  /// A plain yes or no, in either language, or null for anything else.
  ///
  /// Negatives are tested first. Bangla negates *after* the verb — "পাঠাও না"
  /// is "do not send" and contains "পাঠাও" — so a yes-first test reads a
  /// refusal as consent, which for a camera pointed at somebody's home is
  /// the expensive direction to get wrong.
  static bool? _yesOrNo(String text) {
    final lower = text.toLowerCase().trim();
    if (lower.isEmpty) return null;
    const no = [
      'no',
      'nope',
      'not now',
      "don't",
      'do not',
      'cancel',
      'stop',
      'na',
      'naa',
      'না',
      'করো না',
      'পাঠিও না',
      'পাঠাবে না',
      'লাগবে না',
      'থাক',
    ];
    for (final n in no) {
      if (lower.contains(n)) return false;
    }
    const yes = [
      'yes',
      'yeah',
      'yep',
      'ok',
      'okay',
      'sure',
      'go ahead',
      'send it',
      'send',
      'ha',
      'haa',
      'hae',
      'হ্যাঁ',
      'হ্যা',
      'হা',
      'আচ্ছা',
      'ঠিক আছে',
      'পাঠাও',
      'পাঠান',
    ];
    for (final y in yes) {
      if (lower.contains(y)) return true;
    }
    return null;
  }

  /// Takes the frame a guardian asked for and sends it back.
  ///
  /// This used to answer "that ability will be added later", which was true
  /// when written — Module 6 was unbuilt and the app had no camera
  /// dependency at all — and has been stale since it shipped. A tester
  /// reported the request sending nothing back, and from the guardian's side
  /// a request that is recorded and never answered is indistinguishable from
  /// one that never arrived.
  ///
  /// Sends the description even when there is no frame. A scan that could
  /// not see still owes an answer, and "the camera could not see" is a
  /// different thing from silence.
  Future<void> _captureForCaretaker(
    UserProfile profile,
    Dashboard d, {
    required String caretakerUid,
  }) async {
    if (!await _aimCamera()) {
      await _appendAssistantReply(d.caretakerSnapshotDeclined, profile);
      return;
    }
    await _appendAssistantReply(d.caretakerSnapshotTaking, profile);
    final vision = ref.read(snapshotVisionServiceProvider);
    try {
      ScanResult result;
      try {
        // One frame, straight ahead — a guardian checking on somebody wants
        // what is in front of them now, not a three-frame sweep that takes
        // seventeen seconds and asks them to stand still.
        result = await vision.scan(
          focus: ScanFocus.ahead,
          language: profile.language,
        );
      } catch (e) {
        debugPrint('[Chat] caretaker snapshot failed: $e');
        await _appendAssistantReply(d.caretakerSnapshotFailed, profile);
        return;
      }

      try {
        await ref
            .read(communicationServiceProvider)
            .sendSnapshotReply(
              disabledUserUid: profile.uid,
              fromUid: profile.uid,
              toUid: caretakerUid,
              text: result.spoken,
              imageBase64: result.frameJpeg == null
                  ? null
                  : base64Encode(result.frameJpeg!),
            );
      } catch (e) {
        debugPrint('[Chat] could not send the snapshot reply: $e');
        await _appendAssistantReply(d.caretakerSnapshotFailed, profile);
        return;
      }
      await _appendAssistantReply(
        result.frameJpeg == null
            ? d.caretakerSnapshotFailed
            : d.caretakerSnapshotSent,
        profile,
      );
    } finally {
      vision.closeCamera();
      await _finishCameraAim();
    }
  }

  /// Runs the Magic Button and reports the outcome in the chat.
  ///
  /// The service speaks each step itself as it happens — the user cannot
  /// read this — so what is appended here is a written record for a
  /// caretaker looking at the phone afterwards, not the primary channel.
  Future<void> _runEmergency(UserProfile profile) async {
    final d = Dashboard.of(profile.language);
    final outcome = await ref
        .read(emergencyServiceProvider)
        .trigger(profile: profile);
    // An escape route reaches the navigation controller directly (see
    // `emergencyServiceProvider`'s `onRoute`), which is enough to *speak* it
    // and nothing else. Without this the map stayed on whatever it was
    // showing — or on nothing — through the entire emergency, so the one
    // person most likely to be looking at the screen, a bystander or a
    // caretaker holding the phone, could not see where the user was being
    // sent. Surfacing it here also reveals the map, via the same listener a
    // requested route uses.
    final escape = ref.read(navigationControllerProvider).activeRoute;
    if (escape != null && !identical(escape, state.pendingRoute)) {
      // No alternatives: this route was chosen for safety, and "give me a
      // different one" is not a question worth answering mid-emergency.
      state = state.copyWith(pendingRoute: escape, routeAlternatives: const []);
    }
    final text = outcome.cancelled
        ? d.emergencyCancelled
        : EmergencyConfig.isRehearsal
        ? d.emergencyRehearsal(profile.magicButtonContacts.length)
        : outcome.reachedAnyone
        ? d.emergencySent(outcome.messaged.length)
        : d.emergencyNotSent;
    // Appended without going through `_appendAssistantReply`, which speaks
    // what it appends: the service has already said all of this out loud as
    // it happened, and hearing it a second time during an emergency is
    // worse than useless.
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.assistant,
          text: text,
          timestamp: DateTime.now(),
        ),
      ],
    );
  }

  Map<String, Object?> _resolveLocalIntentArgs(
    LocalIntent intent,
    UserProfile profile,
  ) {
    if (intent.name != 'update_setting' ||
        intent.args['setting'] != 'text_size')
      return intent.args;
    // One rung of `textScaleLevels`, not a fixed 0.15. The old delta put the
    // voice command on values the slider could not show and no label named
    // — "bigger" three times from 1.0 reached 1.45, which is nothing the
    // user could have chosen by hand. Stepping by index also guarantees the
    // change is visible, which a 0.15 nudge near the 2.0 ceiling was not.
    final steps = switch (intent.args['value']) {
      '_bigger' => 1,
      '_smaller' => -1,
      _ => null,
    };
    if (steps == null) return intent.args;
    final newScale = stepScale(profile.fontScale, steps);
    return {'setting': 'text_size', 'value': newScale.toString()};
  }

  /// Handles one turn of the "where is that, exactly?" conversation.
  ///
  /// Returns true when the reply was consumed as an answer. Returns false
  /// when it was plainly a new instruction instead — a user is allowed to
  /// abandon a half-finished clarification by simply asking for something
  /// else, and forcing them to formally cancel first would be its own trap.
  /// Words that open a question, in both languages.
  ///
  /// Needed because a question mark alone is not enough. The destination
  /// clarifier asks "Which one — say the number, or the name." — a question
  /// with a full stop, seen on device — and there is no reason Gemini's own
  /// follow-ups ("What should I call it.") will punctuate any better. Keying
  /// only off `?` would leave exactly the multi-turn exchanges this is meant
  /// to protect unprotected.
  static const _questionOpeners = [
    'which',
    'what',
    'who',
    'where',
    'when',
    'how',
    'do you',
    'would you',
    'should i',
    'shall i',
    'is that',
    'are you',
    'can you tell',
    'কোন',
    'কী',
    'কি',
    'কে',
    'কোথায়',
    'কখন',
    'কীভাবে',
    'কিভাবে',
  ];

  /// Whether the assistant's last message was a question still awaiting an
  /// answer.
  ///
  /// Crude on purpose: the alternative is every tool declaring whether its
  /// reply expects an answer, which is more machinery and more places to
  /// forget. A false positive costs one Gemini round trip; a false negative
  /// costs the user the thread — which is the failure that was reported, so
  /// this errs toward treating a reply as conversational.
  bool get _assistantAwaitingAnswer {
    for (var i = state.messages.length - 1; i >= 0; i--) {
      final message = state.messages[i];
      // Skip the user turn just appended by the caller.
      if (message.sender != ChatSender.assistant) continue;
      final text = message.text.trim();
      if (text.isEmpty) return false;
      // Must *end* in a question. `contains('?')` was far too broad: a reply
      // that answers something and then adds "Anything else?" — or simply
      // mentions a question mark anywhere — latched this on, and every
      // command on the following turn was discarded as though it were an
      // answer. That is the 22 September report's "open map did not work",
      // "didnt auto open map" and "asked about my location, answer is
      // inconsistent", all from one heuristic:
      //
      //     [Chat] <- Gemini ... (overlay=SuggestedChipAction.showMap, ...)
      //     [Chat] model overlay SuggestedChipAction.showMap suppressed — answering a question
      //
      // The model had already decided, with the full history in front of it,
      // that this was a command. This threw that away.
      if (text.endsWith('?')) return true;
      final lower = text.toLowerCase();
      return _questionOpeners.any(
        (q) => lower.startsWith(q) || lower.contains('. $q'),
      );
    }
    return false;
  }

  /// Handles one turn of "what should I call that place?".
  ///
  /// Returns true when the reply was consumed as an answer. Returns false
  /// when it was plainly a new instruction instead — the same escape hatch
  /// [_continueClarification] has, and for the same reason: a user is
  /// allowed to abandon a half-finished save by simply asking for something
  /// else, and forcing them to formally cancel first would be its own trap.
  Future<bool> _continuePlaceSave(
    PendingPlaceSave pending,
    String reply,
    UserProfile profile,
    Position? location,
    Dashboard d,
  ) async {
    // An unmistakable command wins. Routing and the safety-critical triggers
    // only — a stray settings phrase should not silently discard the save.
    final escape = LocalIntentMatcher.match(reply, profile.language);
    if (escape != null &&
        const {
          'request_route',
          'replan_route',
          'trigger_emergency',
          'open_passerby_helper',
          'open_hazard_report',
        }.contains(escape.name)) {
      state = state.copyWith(clearPlaceSave: true);
      return false;
    }

    if (DestinationClarifier.isCancellation(reply)) {
      state = state.copyWith(clearPlaceSave: true);
      await _appendAssistantReply(d.clarifyCancelled, profile);
      return true;
    }

    final answer = reply.trim();
    if (answer.isEmpty || pending.isExhausted) {
      state = state.copyWith(clearPlaceSave: true);
      await _appendAssistantReply(d.savedPlaceGaveUp, profile);
      return true;
    }

    // The outstanding question is the name — the only slot that can be
    // missing once the request itself has been rejected as a name.
    final filled = pending.withLabel(answer);
    final turn = await ref
        .read(functionCallExecutorProvider)
        .execute(
          name: 'save_place',
          args: {
            'label': filled.label,
            if (filled.address != null && filled.address!.isNotEmpty)
              'address': filled.address,
          },
          profile: profile,
          location: location,
        );
    if (turn.updatedProfile != null) {
      await ref.read(profileServiceProvider).saveProfile(turn.updatedProfile!);
      state = state.copyWith(clearPlaceSave: true);
    } else {
      // Still not enough — keep the conversation open rather than dropping
      // it, but count the attempt so it cannot run forever.
      state = state.copyWith(pendingPlaceSave: turn.placeSave ?? filled);
    }
    await _appendAssistantReply(
      turn.responseText,
      profile,
      mayInviteAnswer: true,
    );
    return true;
  }

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
        const {
          'request_route',
          'request_alternative_route',
          'replan_route',
          'open_passerby_helper',
          'open_hazard_report',
        }.contains(escape.name)) {
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
          await _appendAssistantReply(
            d.clarifyGaveUp(pending.originalQuery),
            profile,
          );
        } else {
          await _appendAssistantReply(
            d.clarifyUnclear,
            profile,
            mayInviteAnswer: true,
          );
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

  /// Routes to a point the user pinned on the map.
  ///
  /// Separate from [sendFreeText] because a pin has no name. Everything else
  /// that asks for a route hands a *string* to a geocoder; this already has
  /// the coordinates and there is nothing to look up, so it goes straight in
  /// through `knownDestination` — the same door a saved place uses.
  ///
  /// The reverse geocode is for the **sentence**, not for the route. The
  /// route is already fully determined by the pin, so a failed or slow
  /// lookup must not block it: the user hears "the place you picked on the
  /// map" instead of a street name, and still gets taken there. Naming the
  /// destination out loud matters more than usual here — pinning is the one
  /// input method where the user never said where they were going, so the
  /// read-back is their only chance to catch a mis-aimed pin before they
  /// start walking.
  Future<void> routeToCoordinates({
    required double latitude,
    required double longitude,
    required UserProfile profile,
  }) async {
    final d = Dashboard.of(profile.language);
    final destination = LatLng(latitude, longitude);

    Position? location;
    try {
      location = await Geolocator.getLastKnownPosition().timeout(
        _lastFixBudget,
      );
    } catch (_) {
      location = null;
    }
    if (location == null) {
      await _appendAssistantReply(d.mapUnavailableSubtitle, profile);
      return;
    }

    state = state.copyWith(isAssistantTyping: true);
    final planner = ref.read(routePlanningServiceProvider);

    String? label;
    try {
      label = await planner
          .describeLocation(destination)
          .timeout(_lastFixBudget);
    } catch (e) {
      debugPrint('[Chat] could not name the pinned point: $e');
    }
    final spokenLabel = (label == null || label.trim().isEmpty)
        ? d.pathPinnedFallback
        : label;
    _appendUserMessage(d.pathPinnedRequest(spokenLabel));

    final result = await planner.plan(
      destinationQuery: spokenLabel,
      destinationLabel: spokenLabel,
      knownDestination: destination,
      origin: LatLng(location.latitude, location.longitude),
    );
    state = state.copyWith(isAssistantTyping: false);

    switch (result) {
      case RoutePlanned(:final choice, :final alternatives):
        state = state.copyWith(
          pendingRoute: choice,
          routeAlternatives: alternatives,
          clearClarification: true,
        );
        await _appendAssistantReply(
          '${d.savedPlaceRouting(choice.destinationLabel)} '
          '${d.routeSummary(via: choice.viaSummary, distanceMeters: choice.distanceMeters, durationSeconds: choice.durationSeconds)}',
          profile,
        );
        _startNavigation(choice, profile);
      // A pin cannot be ambiguous and cannot be "not found" — it is already a
      // point. Anything else here is a genuine routing failure (no walkable
      // path, backend down), and is reported as one rather than reopening the
      // "where exactly?" conversation, which has no question to ask about a
      // place the user pointed at.
      default:
        await _appendAssistantReply(d.pathPinUnroutable, profile);
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
    final result = await ref
        .read(routePlanningServiceProvider)
        .plan(
          destinationQuery: query,
          destinationLabel: label,
          knownDestination: known,
          origin: LatLng(location.latitude, location.longitude),
        );
    state = state.copyWith(isAssistantTyping: false);

    switch (result) {
      case RoutePlanned(:final choice, :final alternatives):
        state = state.copyWith(
          pendingRoute: choice,
          routeAlternatives: alternatives,
          clearClarification: true,
        );
        // A place that took several questions to find is exactly the one
        // worth never having to find again.
        await _appendAssistantReply(
          '${d.savedPlaceRouting(choice.destinationLabel)} '
          '${d.routeSummary(via: choice.viaSummary, distanceMeters: choice.distanceMeters, durationSeconds: choice.durationSeconds)} '
          '${d.clarifyResolvedOfferSave(choice.destinationLabel)}',
          profile,
          // Ends by offering to save the place, which is a yes/no question.
          mayInviteAnswer: true,
        );
        _startNavigation(choice, profile);

      case RoutePlanAmbiguous(:final options):
        state = state.copyWith(
          pendingClarification:
              (pending ?? DestinationClarification(originalQuery: query))
                  .offering(options),
        );
        await _appendAssistantReply(
          d.clarifyChooseOption(options.map((o) => o.spokenLabel).toList()),
          profile,
          mayInviteAnswer: true,
        );

      case RoutePlanFailed(:final reason):
        if (reason != 'destination_not_found' || pending == null) {
          state = state.copyWith(clearClarification: true);
          await _appendAssistantReply(d.hazardResolveNothingToClear, profile);
          return;
        }
        if (pending.isExhausted) {
          state = state.copyWith(clearClarification: true);
          await _appendAssistantReply(
            d.clarifyGaveUp(pending.originalQuery),
            profile,
          );
          return;
        }
        // Each round asks for a *different* kind of clue. A user who could
        // answer "where is it?" would have answered it the first time.
        await _appendAssistantReply(
          pending.attempts <= 1
              ? d.clarifyAskArea(pending.originalQuery)
              : d.clarifyAskLandmark(pending.originalQuery),
          profile,
          mayInviteAnswer: true,
        );
    }
  }

  /// Ends the walk: stops the narrator, clears the route, and lets the map
  /// close.
  ///
  /// Reported: "Cancel the trip to Dhaka" was answered with "Cancelled your
  /// trip to Dhaka" while the route stayed active and the map kept drawing
  /// it. There was no intent for this at all, so it fell through to Gemini,
  /// which described a state change it had no way to make.
  Future<void> _cancelRoute(UserProfile profile, Dashboard d) async {
    if (state.pendingRoute == null) {
      await _appendAssistantReply(d.routeNothingToCancel, profile);
      return;
    }
    // Silent: the reply below says it, and `navigateStopped` on top of it is
    // the same news twice.
    await ref.read(navigationControllerProvider).stop(silent: true);
    state = state.copyWith(clearRoute: true);
    await _appendAssistantReply(d.routeCancelled, profile);
  }

  /// Begins spoken turn-by-turn guidance the moment a route is accepted.
  ///
  /// Not gated behind a "start navigation" tap: for a user who cannot see
  /// the map, a planned-but-silent route is not usable at all — the arrow
  /// and the polyline are the sighted half of this feature, and the spoken
  /// directions are the whole of the other half.
  /// A one-line weather warning to append to a route, or empty.
  ///
  /// Appended rather than spoken on its own, and only when it clears
  /// `WeatherReading.isWorthMentioning` — an assistant that remarks on the
  /// weather every time somebody asks for a route is one the user learns to
  /// talk over, and the warning that matters goes with it.
  ///
  /// Never blocks. The lookup is bounded and fails to null, because the user
  /// asked to go somewhere and "I could not check the weather" is not a
  /// reason to leave them standing there.
  Future<String> _weatherNoteFor(UserProfile profile, Dashboard d) async {
    Position? here;
    try {
      here = await Geolocator.getLastKnownPosition().timeout(_lastFixBudget);
    } catch (_) {
      return '';
    }
    if (here == null) return '';

    final reading = await ref
        .read(weatherServiceProvider)
        .current(latitude: here.latitude, longitude: here.longitude);
    if (reading == null || !reading.isWorthMentioning) return '';

    // One warning, worst first. Two weather sentences in front of a route is
    // the noise this is trying not to become.
    if (reading.isThunderstorm) return d.weatherThunderstorm;
    if (reading.isRainingNow) return d.weatherRainingNow();
    if (reading.isVeryHot) return d.weatherVeryHot(reading.feelsLikeC.round());
    return d.weatherRainSoon(reading.rainChanceNextHourPercent);
  }

  void _startNavigation(RouteChoice route, UserProfile profile) {
    ref
        .read(navigationControllerProvider)
        .start(
          route,
          language: profile.language,
          // The reply appended just above already said the destination, the
          // road and the distance — see `Dashboard.routeSummary`. Saying all
          // of it again as navigation opens is two announcements for one
          // event, back to back, before the user has moved.
          describeRoute: false,
        );
  }

  void _appendUserMessage(
    String text, {
    String? replyToText,
    String? replyToMessageId,
  }) {
    state = state.copyWith(
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.user,
          text: text,
          timestamp: DateTime.now(),
          replyToMessageId: replyToMessageId,
          replyToText: replyToText,
        ),
      ],
    );
  }

  /// Speaks every assistant reply unless the user is Deaf/hard of hearing —
  /// the same rule `OnboardingController.setDeafHearing` already applies to
  /// spoken onboarding guidance (that profile flag means "show text and
  /// visuals instead of relying on audio").
  /// Whether a reply is the assistant asking the user something.
  ///
  /// Two signals, because neither covers the other. A pending clarification
  /// or a pending place-save *is* a question by construction — the assistant
  /// is holding a slot open and the next utterance is the answer to it. And a
  /// free-text Gemini reply that ends in a question mark is a question with
  /// no state attached to it at all, which is most of what item 60 is about:
  /// "after ai asks a question, it should reopen mic".
  ///
  /// The mark is checked in both scripts. Bangla uses the Latin `?`, but a
  /// reply can end on the danda or a full-width mark depending on what the
  /// model emits, and a question the app fails to recognise as one is a
  /// microphone that does not open.
  bool _invitesAnAnswer(String text) {
    if (state.pendingClarification != null || state.pendingPlaceSave != null)
      return true;
    final trimmed = text.trimRight();
    return trimmed.endsWith('?') || trimmed.endsWith('？');
  }

  /// Speaks an unprompted ambient hazard warning — Module 6.
  ///
  /// Goes through the normal reply path rather than straight to TTS so it
  /// queues behind turn-by-turn guidance instead of cutting across it, and so
  /// it lands in the transcript for a Deaf-blind user or one who has muted
  /// the voice.
  ///
  /// `mayInviteAnswer` is false on purpose: this is a warning, not a
  /// question, and opening the microphone after it would have somebody who
  /// has just been told to stop walking also expected to reply.
  Future<void> announceAmbientHazard(String line, UserProfile profile) =>
      _appendAssistantReply(line, profile);

  /// The Volume-Up hold's entry point — Module 6's physical sweep trigger.
  ///
  /// Public because `VisionChannel` fires from outside any chat turn. It
  /// appends nothing as a user message: the user did not say anything, they
  /// pressed a key, and inventing a line of their speech in the transcript
  /// would misrepresent what happened to anyone reading it back.
  Future<void> runSweep(UserProfile profile) =>
      _runScan(ScanFocus.surroundings, profile);

  /// Runs one Snapshot Vision scan and speaks what it saw — Module 6.
  ///
  /// Lives here rather than on the dashboard screen because, unlike the
  /// Passerby overlay and the Reporting Hub, a scan needs no `BuildContext`:
  /// there is nothing to show. It captures, thinks, and says a sentence,
  /// which is exactly what this controller already does for every other
  /// reply — and routing it through `_appendAssistantReply` means the result
  /// is spoken, lands in the transcript for a Deaf-blind user or one who has
  /// muted the voice, and is persisted by `ChatHistoryStore` like anything
  /// else.
  Future<void> _runScan(
    ScanFocus focus,
    UserProfile profile, {
    String? question,
  }) async {
    final d = Dashboard.of(profile.language);
    if (!await _aimCamera()) {
      await _appendAssistantReply(d.visionCaptureFailed, profile);
      return;
    }
    final vision = ref.read(snapshotVisionServiceProvider);

    // Only the three-frame sweep gets the "hold still" instruction — plan
    // Step 1.2. A single-frame scan is already taken by the time this would
    // finish being spoken, so saying it would be an instruction to do
    // something that no longer matters, which teaches the user to ignore
    // instructions that do.
    if (focus == ScanFocus.surroundings) {
      await _appendAssistantReply(d.visionSweepPrompt, profile);
    }

    state = state.copyWith(isAssistantTyping: true);
    ScanResult result;
    try {
      result = await vision.scan(
        focus: focus,
        language: profile.language,
        // The user's own wording, so "what colour is the rabbit" is asked of
        // the camera as that question rather than reduced to the focus
        // enum's "describe the path ahead".
        question: question,
        // Spoken straight through the TTS chain rather than through
        // `_appendAssistantReply`: "Left." / "Straight ahead." / "Right."
        // are aiming instructions, not conversation, and three bubbles per
        // scan would bury the answer the user actually asked for. They still
        // queue behind the "I will take three looks" line above, because it
        // is the same serialised chain.
        //
        // Nothing is said to a Deaf or hard-of-hearing user — for them the
        // buzz before each frame is the instruction, which is what the
        // fixed left-ahead-right order exists to make learnable.
        narrate: profile.isDeafOrHardOfHearing
            ? null
            : (text) => ref
                  .read(ttsServiceProvider)
                  .speak(text, language: profile.language),
      );
    } catch (e) {
      debugPrint('[Chat] scan failed: $e');
      state = state.copyWith(isAssistantTyping: false);
      await _appendAssistantReply(d.visionCaptureFailed, profile);
      return;
    } finally {
      vision.closeCamera();
    }
    state = state.copyWith(isAssistantTyping: false);

    // The frame rides with the answer, so the user can see what was
    // actually looked at. A wildly wrong description is almost always a
    // wildly wrong aim, and that is invisible without the picture.
    await _appendAssistantReply(
      result.spoken,
      profile,
      imageJpeg: result.frameJpeg,
    );

    // An abort has already buzzed and already said stop. Offering to file a
    // report on top of that is a second demand on somebody who has just been
    // told to stop walking.
    if (result.abortedForHazard) return;

    // Module 5 tie-in, and deliberately an *offer*. Filing automatically
    // would put a road-closing hazard on the shared map because the user
    // asked a question — the failure mode the README names as one a blind
    // user can neither see nor undo.
    final kind = result.hazardPrefillKind;
    if (kind == null) return;
    final label = result.scene?.hazards
        .firstWhere(
          (h) => h.kind == kind,
          orElse: () => result.scene!.hazards.first,
        )
        .description;
    if (label == null || label.isEmpty) return;
    await _appendAssistantReply(
      d.visionOfferReport(label),
      profile,
      mayInviteAnswer: true,
    );
  }

  Future<void> _appendAssistantReply(
    String text,
    UserProfile profile, {

    /// Whether this reply may reopen the microphone when it turns out to be
    /// a question. False for anything the user is not being asked to answer
    /// — a caretaker's memo read aloud is not the app asking them something.
    bool mayInviteAnswer = false,

    /// The camera frame this reply is about — shown under the bubble. See
    /// [ChatMessage.imageJpeg].
    Uint8List? imageJpeg,
  }) async {
    // A function whose confirmation is spoken by whatever it opens returns an
    // empty string rather than talking over it — `record_caretaker_voice_memo`
    // is one. Appending that would leave a blank bubble in the transcript,
    // which for a user reading back through it says nothing happened.
    if (text.isEmpty) return;
    state = state.copyWith(isAssistantTyping: true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    state = state.copyWith(
      isAssistantTyping: false,
      messages: [
        ...state.messages,
        ChatMessage(
          sender: ChatSender.assistant,
          text: text,
          timestamp: DateTime.now(),
          imageJpeg: imageJpeg,
        ),
      ],
    );

    final invites =
        mayInviteAnswer && profile.voiceAutoListen && _invitesAnAnswer(text);
    if (profile.isDeafOrHardOfHearing) {
      // Nothing is spoken, so there is nothing to wait for. A deaf user with
      // auto-listen on still gets the microphone — `voiceAutoListen` is a
      // separate answer from `isDeafOrHardOfHearing` and some users set both.
      if (invites) _inviteAnswer();
      return;
    }
    final speaking = ref
        .read(ttsServiceProvider)
        .speak(text, language: profile.language);
    if (!invites) {
      unawaited(speaking);
      return;
    }
    // Awaited only on the path that is about to open a microphone. Opening
    // it under the question being asked is item 23 — the app transcribing
    // its own narration — and this is the most obvious way to bring it back.
    try {
      await speaking;
    } catch (e) {
      debugPrint('[Chat] narration failed before reopening the mic: $e');
    }
    _inviteAnswer();
  }

  void _inviteAnswer() {
    debugPrint('[Chat] the assistant asked something — inviting an answer');
    state = state.copyWith(answerInvitations: state.answerInvitations + 1);
  }

  /// How long a chat message waits on a cached location fix before going on
  /// without one. Short: it is context, not the answer.
  static const Duration _lastFixBudget = Duration(seconds: 2);

  /// Which user turn is the current one.
  ///
  /// Bumped by every message the user sends, so a reply that arrives for an
  /// earlier turn can tell that it is no longer wanted.
  ///
  /// Confirmed live on 16 Sep: a message sent at 22:39:13 was answered
  /// **114,964ms later**. In the meantime the user asked something else
  /// entirely, got a correct answer at 22:41:07 — and then the two-minute-old
  /// reply landed at 22:41:08 on top of it, answering a question they had
  /// stopped asking. They complained, reasonably, that the assistant was
  /// talking about the wrong thing.
  ///
  /// Nothing cancels the HTTP request itself; the SDK gives no handle for
  /// that. What this does is make the *result* unusable, which is the part
  /// the user experiences.
  int _turnGeneration = 0;

  /// Silences the assistant immediately, for when the user opens the
  /// microphone while it is still talking.
  ///
  /// Reported from the 22 September session: pressing the mic mid-reply left
  /// the queue intact, so the app went on reading **every** utterance still
  /// behind it — old answers, one after another — over the user's new
  /// question. For someone who cannot see the screen, a voice that will not
  /// stop is not a cosmetic annoyance: the microphone is open underneath it,
  /// the app is talking into its own recognizer, and there is no visible way
  /// out. Pressing the button again only queued more.
  ///
  /// Both halves are needed and they do different jobs. [TtsService.stop]
  /// cuts what is playing and abandons what is already queued behind it; the
  /// generation bump stops the *producer*, so a reply still streaming in
  /// cannot enqueue its next sentence a moment later. Stopping only the
  /// player left the chunker feeding a queue that had just been emptied.
  /// Appends a reply that may reopen the microphone, for tests of that rule.
  ///
  /// The rule — invite an answer only after a question, and only once it has
  /// finished being spoken — used to be exercised through the "Route to Work"
  /// chip, whose handler asked "Where would you like to go?". That chip is
  /// now `openPath` and opens the destination sheet instead, so the
  /// behaviour it happened to cover lost its only test entry point while the
  /// behaviour itself did not change. Every remaining caller is behind a
  /// network backend or the camera.
  @visibleForTesting
  Future<void> replyForTest(String text, UserProfile profile) =>
      _appendAssistantReply(text, profile, mayInviteAnswer: true);

  void interruptNarration() {
    _turnGeneration++;
    unawaited(ref.read(ttsServiceProvider).stop());
    if (state.isAssistantTyping)
      state = state.copyWith(isAssistantTyping: false);
  }

  Future<void> sendFreeText(
    String text,
    UserProfile profile, {
    String? replyTo,
    String? replyToMessageId,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _turnGeneration++;
    _appendUserMessage(
      trimmed,
      replyToText: replyTo,
      replyToMessageId: replyToMessageId,
    );

    final d = Dashboard.of(profile.language);

    final forModel = replyTo == null || replyTo.trim().isEmpty
        ? trimmed
        : 'The user is replying to the specific assistant message with id '
              '"${replyToMessageId ?? 'unknown'}". Treat the quoted text as the '
              'message they mean, even if older turns mention similar options.\n'
              'Quoted assistant message: "${replyTo.trim()}"\n'
              'User reply: $trimmed';

    // The emergency is matched and dispatched *before* anything that waits.
    //
    // It used to sit after the location lookup, and behind the pending-save
    // and pending-clarification handlers, so every "save me" paid for a
    // cached GPS fix it never reads — `EmergencyService` fetches its own
    // position, later, on its own budget. That was an unbounded wait until
    // recently and is a two-second one now, on the one command in the app
    // where the reply is the whole point. Reported as "Emergency, SOS, Save
    // me — reply dite koyek second time nicche".
    //
    // Jumping the pending-question queue is not new behaviour, it is the
    // existing rule applied earlier: someone in trouble does not stop being in
    // trouble because the assistant happened to have asked them something.
    final localIntent = LocalIntentMatcher.match(
      trimmed,
      profile.language,
      recentSetting: state.lastSettingChanged,
    );
    if (localIntent?.name == 'trigger_emergency') {
      if (_oneShotCaretakerMessage) {
        _oneShotCaretakerMessage = false;
        state = state.copyWith(caretakerMessageArmed: false);
      }
      debugPrint(
        '[Chat] local match: trigger_emergency (ahead of the location fix)',
      );
      await _runEmergency(profile);
      return;
    }
    if (_oneShotCaretakerMessage) {
      _oneShotCaretakerMessage = false;
      state = state.copyWith(caretakerMessageArmed: false);
      await _deliverCaretakerText(trimmed, profile);
      return;
    }
    if (localIntent?.name == 'arm_caretaker_message') {
      _oneShotCaretakerMessage = true;
      state = state.copyWith(caretakerMessageArmed: true);
      await _appendAssistantReply(
        profile.language == AppLanguage.bangla
            ? 'আপনি কী বার্তা পাঠাতে চান?'
            : 'What message should I send to your caretaker?',
        profile,
        mayInviteAnswer: true,
      );
      return;
    }
    if (localIntent?.name == 'send_photo_to_caretaker') {
      await _sendPhotoToCaretaker(profile, d);
      return;
    }

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
      // Bounded, because this future does not always complete.
      //
      // The try/catch alone only ever covered a *throw*. A platform channel
      // that never answers — an unresponsive location provider, or simply no
      // plugin behind it — leaves `getLastKnownPosition()` pending forever,
      // and this is awaited on the way to *every* chat message. The user
      // would type or say something and get no reply at all, with nothing
      // logged. Confirmed off-device: with no plugin registered it neither
      // resolves nor throws after twenty seconds.
      //
      // Same defect and same fix as the hazard hub's and the Magic Button's
      // position lookups (open_bugs item 27). A cached fix is a nicety here;
      // the reply is not.
      location = await Geolocator.getLastKnownPosition().timeout(
        _lastFixBudget,
      );
    } catch (_) {
      // No last-known fix available (denied permission, web, first launch
      // before any GPS read, or the platform not answering) — proceed
      // without it.
    }

    // A question we just asked takes priority over reading the next
    // message as a fresh command. Without this, "it's in Mirpur" — a
    // perfectly good answer to "which area is it in?" — falls through to
    // the intent matcher, matches nothing, and goes to Gemini as though
    // the assistant had never asked anything, losing the thread entirely.
    // A save waiting on a name owns the next message, for the same reason a
    // pending destination question does: "the clinic" is an answer, and
    // letting the destination matcher see it first is exactly how the save
    // turned into a route on device.
    // Before everything else, and before the intent matcher sees it: a bare
    // "yes" answering a photo request must not be read as a command.
    if (await _continueSnapshotConsent(trimmed, profile, d)) return;

    final pendingSave = state.pendingPlaceSave;
    if (pendingSave != null) {
      final handled = await _continuePlaceSave(
        pendingSave,
        trimmed,
        profile,
        location,
        d,
      );
      if (handled) return;
    }

    final pending = state.pendingClarification;
    if (pending != null) {
      final handled = await _continueClarification(
        pending,
        trimmed,
        profile,
        location,
        d,
      );
      if (handled) return;
    }

    // Checked before ever touching Gemini — `LocalIntentMatcher` recognizes
    // the common, unambiguous settings-change/trigger commands (explicit
    // user request: save the latency and token cost of a full LLM round
    // trip for these, while still falling through to Gemini for anything
    // it isn't confident about). `FunctionCallExecutor` is what actually
    // applies the change — the exact same code Gemini's own function
    // calling uses, so the effect and wording are identical either way.
    // A reply to the assistant's own question belongs to that conversation,
    // not to the command matcher.
    //
    // This is what made every multi-turn exchange collapse. The assistant
    // would ask "which place, and what should I call it?", the user would
    // answer "college", and that answer went to the matcher first, matched
    // as a fresh destination, and the thread was gone. The same for adding a
    // contact: it only ever worked when the whole thing was said in one
    // breath, because any follow-up answer was intercepted. Gemini already
    // receives the history and already has the tools to fill slots across
    // turns — it just never got the chance.
    //
    // The emergency trigger is deliberately exempt. Someone in trouble does
    // not stop being in trouble because the assistant happened to have asked
    // them something.
    final answeringQuestion = _assistantAwaitingAnswer;
    if (localIntent != null &&
        answeringQuestion &&
        localIntent.name != 'trigger_emergency' &&
        localIntent.name != 'arm_caretaker_message' &&
        localIntent.name != 'send_photo_to_caretaker') {
      debugPrint(
        '[Chat] local match ${localIntent.name} suppressed — answering a question',
      );
    } else if (localIntent != null) {
      debugPrint(
        '[Chat] local match: ${localIntent.name} ${localIntent.args} (skipping Gemini)',
      );
      // The Magic Button is a sequence, not a state change — speak, wait,
      // dispatch, call, alert — so it does not go through the executor,
      // which exists to apply one change and describe it. It also must not
      // wait on anything the executor does first.
      // Handled above, before the location lookup — see the comment there.
      // Left as a guard rather than deleted: if the early dispatch is ever
      // moved or gated, an SOS falling through to the executor would be
      // silent, and silence is the one outcome this path must never have.
      if (localIntent.name == 'trigger_emergency') {
        await _runEmergency(profile);
        return;
      }
      // Cancelling a trip is chat-state, not a function call — the executor
      // has no route to clear and no navigator to stop. Handled here for the
      // same reason the emergency is.
      if (localIntent.name == 'cancel_route') {
        await _cancelRoute(profile, d);
        return;
      }
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
            routeAlternatives: state.routeAlternatives,
          );
      if (turn.updatedProfile != null) {
        await ref
            .read(profileServiceProvider)
            .saveProfile(turn.updatedProfile!);
      }
      // Reachable when a local match produces `cancel_route` through the
      // executor rather than through the shortcut above — kept so the two
      // paths cannot disagree about what cancelling means.
      if (turn.cancelsRoute) {
        await _cancelRoute(profile, d);
        return;
      }
      await _appendAssistantReply(
        turn.responseText,
        profile,
        mayInviteAnswer: true,
      );
      if (turn.scanFocus != null) {
        await _runScan(turn.scanFocus!, profile, question: turn.scanQuestion);
      }
      if (turn.replayDirection != null) {
        await replayVoiceMemo(turn.replayDirection!, profile);
      }
      if (turn.sendsPhotoToCaretaker) {
        await _sendPhotoToCaretaker(profile, d);
      }
      if (turn.overlayAction != null) {
        state = state.copyWith(
          pendingOverlayAction: turn.overlayAction,
          pendingHazardPrefill: turn.hazardPrefill,
        );
      }
      if (turn.route != null) {
        state = state.copyWith(
          pendingRoute: turn.route,
          routeAlternatives: turn.routeAlternatives,
        );
        _startNavigation(turn.route!, profile);
        // After the route, never instead of it. Setting off in a Dhaka
        // downpour is a different decision from setting off, and the user
        // cannot look out of a window to make it.
        final weather = await _weatherNoteFor(profile, d);
        if (weather.isNotEmpty) await _appendAssistantReply(weather, profile);
      }
      if (turn.clarification != null) {
        state = state.copyWith(pendingClarification: turn.clarification);
      }
      if (turn.placeSave != null) {
        state = state.copyWith(pendingPlaceSave: turn.placeSave);
      }
      if (localIntent.name == 'update_setting') {
        state = state.copyWith(lastSettingChanged: args['setting'] as String?);
      }
      return;
    }

    final gemini = ref.read(geminiAssistantServiceProvider);
    if (gemini == null) {
      await _appendAssistantReply(
        d.chatStubReply,
        profile,
        mayInviteAnswer: true,
      );
      return;
    }

    // Snapshot history *before* the message just appended above, so it
    // isn't duplicated when handed to Gemini as prior turns.
    final history = state.messages.length > 1
        ? state.messages.sublist(0, state.messages.length - 1)
        : const <ChatMessage>[];

    final stopwatch = Stopwatch()..start();
    // Set the instant the first streamed chunk of a plain-text reply
    // arrives — lets the rest of this method tell "already showing a
    // streaming bubble, just reconcile/finish it" apart from "never
    // streamed anything, append normally" (the function-call and
    // stub/fallback paths, where no partial text ever arrives — see
    // `GeminiAssistantService.converse`'s doc comment).
    var streaming = false;
    // Time to the *first* byte back, logged separately from the total.
    // Measured on device at 20-29s end to end, against 17ms for a
    // locally-matched command — and the two numbers answer different
    // questions. A slow first chunk is the model thinking before it commits
    // to anything; a fast first chunk with a slow total is it streaming a
    // long answer. Only the first is worth taking to Google.
    int? firstChunkMs;
    // Nothing is spoken until the whole response lands, so a slow turn is
    // *silence* to somebody who cannot see the typing indicator. They
    // reasonably conclude the wake word missed them and say it again — which
    // is very likely what "the wake word works inconsistently" actually is.
    Timer? stillWorking;
    if (!profile.isDeafOrHardOfHearing) {
      stillWorking = Timer(_stillWorkingAfter, () {
        unawaited(
          ref
              .read(ttsServiceProvider)
              .speak(d.chatStillWorking, language: profile.language),
        );
      });
    }
    // Whose turn this reply belongs to. Anything that comes back for an
    // older one is discarded rather than spoken — see `_turnGeneration`.
    final myTurn = _turnGeneration;
    bool superseded() => _turnGeneration != myTurn;

    // ---- streaming narration ------------------------------------------------
    //
    // Speaks each sentence as it completes rather than waiting for the whole
    // reply. Ported from `f5f5b1f` on `testers-flashlite-prompts`.
    //
    // **Worth far less on Groq than it looks, and that is fine.** Measured on
    // the 17 September Qwen logs: median full reply 916 ms against a median
    // first chunk of 866 ms — fifty milliseconds of silence removed. Qwen
    // streams its whole answer almost at once, so there is nothing to overlap.
    //
    // It earns its place on the *fallback*. Gemini flash-lite measured
    // 1.2-6.9 s, and there the difference between speaking at the first full
    // stop and speaking at the end is the difference between a pause and a
    // silence — to somebody who cannot see a spinner and has no way to tell a
    // thinking app from a dead one.
    //
    // `।` is the Bangla full stop (danda) and is load-bearing: without it
    // every Bangla reply is one unbroken chunk and this does nothing at all
    // in the app's primary language.
    var lastSpokenIndex = 0;
    final sentenceEnd = RegExp(r'[.!?।\n]');

    try {
      debugPrint('[Chat] -> Gemini: "$trimmed"');
      state = state.copyWith(isAssistantTyping: true);
      final turn = await gemini
          .converse(
            userText: forModel,
            profile: profile,
            recentHistory: history,
            location: location,
            // Scopes `resolve_hazard` to what the user is actually walking.
            activeRoute: state.pendingRoute,
            routeAlternatives: state.routeAlternatives,
            onPartialText: (partial) {
              // A superseded turn must not keep writing into the bubble — its
              // chunks would overwrite the newer answer as they arrive.
              if (superseded()) return;
              firstChunkMs ??= stopwatch.elapsedMilliseconds;
              if (!streaming) {
                streaming = true;
                state = state.copyWith(
                  isAssistantTyping: false,
                  messages: [
                    ...state.messages,
                    ChatMessage(
                      sender: ChatSender.assistant,
                      text: partial,
                      timestamp: DateTime.now(),
                    ),
                  ],
                );
              } else {
                state = state.copyWith(
                  messages: _withLastReplaced(text: partial),
                );
              }

              // A shorter partial than we have already spoken means a *different
              // backend* started streaming — the fallback took over after the
              // primary died mid-sentence. Without this the user hears Groq's
              // half-finished sentence and then Gemini's whole answer on top of
              // it. Stop, forget what was said, and start again from the new
              // stream. (`f5f5b1f` predates the fallback and has no such case.)
              if (partial.length < lastSpokenIndex) {
                debugPrint(
                  '[Chat] narration restarting — a second backend took the turn',
                );
                unawaited(ref.read(ttsServiceProvider).stop());
                lastSpokenIndex = 0;
              }

              if (profile.isDeafOrHardOfHearing) return;
              final bound = partial.lastIndexOf(sentenceEnd);
              if (bound < lastSpokenIndex) return;
              final chunk = partial.substring(lastSpokenIndex, bound + 1);
              lastSpokenIndex = bound + 1;
              // A chunk of nothing but punctuation or a newline is not speech,
              // and handing it to the engine costs a platform round trip to say
              // silence.
              if (chunk.trim().isEmpty) return;
              unawaited(
                ref
                    .read(ttsServiceProvider)
                    .speak(chunk, language: profile.language),
              );
            },
          )
          .timeout(_geminiBudget);
      stillWorking?.cancel();
      if (superseded()) {
        // The user moved on. Speaking this now would answer a question they
        // have stopped asking, on top of an answer they already got.
        debugPrint(
          '[Chat] discarding a stale Gemini reply for turn $myTurn '
          '(now on $_turnGeneration) after ${stopwatch.elapsedMilliseconds}ms',
        );
        if (streaming)
          state = state.copyWith(messages: _withoutLastAssistantBubble());
        state = state.copyWith(isAssistantTyping: false);
        return;
      }
      debugPrint(
        '[Chat] <- Gemini in ${stopwatch.elapsedMilliseconds}ms '
        '(first chunk ${firstChunkMs ?? -1}ms): "${turn.responseText}" '
        '(overlay=${turn.overlayAction}, route=${turn.route != null}, '
        'scan=${turn.scanFocus?.name ?? '-'}'
        '${turn.scanQuestion == null ? '' : ' q="${turn.scanQuestion}"'}, '
        'emergency=${turn.triggersEmergency}, cancelRoute=${turn.cancelsRoute}, '
        'profileChanged=${turn.updatedProfile != null})',
      );
      if (turn.updatedProfile != null) {
        await ref
            .read(profileServiceProvider)
            .saveProfile(turn.updatedProfile!);
      }
      // The model judged the user to be in danger. Handled before the reply
      // is spoken, and instead of it: the emergency sequence announces
      // itself immediately, and making someone in trouble listen to a
      // conversational sentence first would waste the seconds this exists
      // to save. Same path a locally-matched trigger takes.
      if (turn.triggersEmergency) {
        debugPrint('[Chat] Gemini judged this an emergency');
        state = state.copyWith(isAssistantTyping: false);
        await _runEmergency(profile);
        return;
      }
      // Item 51. `cancel_route` was declared to the model and handled nowhere
      // — the executor fell through to 'unknown function' and the route
      // stayed on the map while the user was told something had happened.
      // Handled here, instead of the reply, because `_cancelRoute` is the one
      // thing that knows whether there was a journey to cancel, stops the
      // narrator, and says the right sentence either way.
      if (turn.cancelsRoute) {
        debugPrint('[Chat] Gemini asked to cancel the route');
        state = state.copyWith(isAssistantTyping: false);
        await _cancelRoute(profile, d);
        return;
      }
      if (streaming) {
        // Reconcile with the final text and speak whatever the sentence
        // chunker did not already say — the tail after the last full stop,
        // which is most replies' final clause.
        state = state.copyWith(
          isAssistantTyping: false,
          messages: _withLastReplaced(text: turn.responseText),
        );
        final spokenSoFar = lastSpokenIndex.clamp(0, turn.responseText.length);
        final remaining = turn.responseText.substring(spokenSoFar);
        if (!profile.isDeafOrHardOfHearing && remaining.trim().isNotEmpty) {
          unawaited(
            ref
                .read(ttsServiceProvider)
                .speak(remaining, language: profile.language),
          );
        }
      } else {
        await _appendAssistantReply(
          turn.responseText,
          profile,
          mayInviteAnswer: true,
        );
      }
      // No "answering a question" guard here any more, and that is the fix
      // rather than an oversight.
      //
      // It was added on 16 Sep for a real case — the user said "বিপদজনক"
      // ("dangerous") while answering a question about whether a toilet was
      // safe, and the hazard report opened. But suppressing the *model's*
      // decision is the wrong lever for it. The local matcher is
      // context-blind and genuinely needs the guard; the model is handed the
      // conversation, its own question included, so when it still chooses
      // `open_map` it has strictly more information than a heuristic over
      // the last message's punctuation. Overriding it inverted that.
      //
      // The cost was the whole "it used to work" cluster: map, route,
      // setting and location commands all discarded mid-conversation. The
      // genuine multi-turn cases are protected where they belong — by
      // `_continuePlaceSave` and `_continueClarification`, which own the
      // next message outright and return before reaching here — and the
      // system prompt now tells the model not to act on words inside an
      // answer to its own question.
      if (turn.overlayAction != null) {
        state = state.copyWith(
          pendingOverlayAction: turn.overlayAction,
          pendingHazardPrefill: turn.hazardPrefill,
        );
      }
      if (turn.scanFocus != null) {
        await _runScan(turn.scanFocus!, profile, question: turn.scanQuestion);
      }
      if (turn.replayDirection != null) {
        await replayVoiceMemo(turn.replayDirection!, profile);
      }
      if (turn.sendsPhotoToCaretaker) {
        await _sendPhotoToCaretaker(profile, d);
      }
      if (turn.route != null) {
        state = state.copyWith(
          pendingRoute: turn.route,
          routeAlternatives: turn.routeAlternatives,
        );
        _startNavigation(turn.route!, profile);
        // After the route, never instead of it. Setting off in a Dhaka
        // downpour is a different decision from setting off, and the user
        // cannot look out of a window to make it.
        final weather = await _weatherNoteFor(profile, d);
        if (weather.isNotEmpty) await _appendAssistantReply(weather, profile);
      }
      if (turn.placeSave != null) {
        state = state.copyWith(pendingPlaceSave: turn.placeSave);
      }
    } catch (e, st) {
      stillWorking?.cancel();
      state = state.copyWith(isAssistantTyping: false);
      // Previously a bare `catch (_)` — silently swallowed *every* Gemini
      // failure (network, quota, malformed response, anything) with zero
      // visibility into why, then fell back to `OfflineIntentMatcher`,
      // which only recognizes a handful of safety keywords (help/stop/
      // where-am-i/emergency). Confirmed live: this is why "screen দেখাও"
      // (or any other intent the offline matcher doesn't know) silently
      // did nothing instead of opening Show Screen — Gemini's real call
      // was failing for an unknown reason, and there was no way to tell.
      debugPrint(
        '[Chat] Gemini call FAILED after ${stopwatch.elapsedMilliseconds}ms: $e',
      );
      debugPrintStack(stackTrace: st, label: '[Chat] Gemini failure stack');
      final fallback =
          OfflineIntentMatcher.match(trimmed, profile.language) ??
          d.chatStubReply;
      await _appendAssistantReply(fallback, profile, mayInviteAnswer: true);
    }
  }

  /// How long the assistant may stay silent before saying it is still
  /// working. Long enough that a normal reply never triggers it, short
  /// enough that the user has not yet decided nothing happened.
  static const Duration _stillWorkingAfter = Duration(seconds: 3);

  /// The longest the assistant may leave someone standing in silence.
  ///
  /// There was no bound at all, and the 17 Sep session shows what that cost:
  /// calls that failed after **59,144ms** and **42,898ms** — a full minute of
  /// nothing, and then a fallback reply anyway. For a user who cannot see a
  /// spinner, that is indistinguishable from the app being dead, and the
  /// spoken "still working on it" at three seconds only covers the first few
  /// of those sixty.
  ///
  /// Thirty seconds is deliberately generous rather than tight: a genuine
  /// route request with a POI search and a safety check behind it has been
  /// measured at 26s, and cutting those off would trade a rare bad wait for
  /// a common wrong answer. This is a bound on pathology, not on patience.
  ///
  /// Timing out is not a dead end — it lands in the same fallback that every
  /// other Gemini failure does, and `OfflineIntentMatcher` still answers the
  /// safety keywords with no model at all.
  static const Duration _geminiBudget = Duration(seconds: 30);

  /// Chips that are pure chat replies. [SuggestedChipAction.showScreenToPasserby],
  /// [SuggestedChipAction.reportHazard] and
  /// [SuggestedChipAction.sendCaretakerVoiceMemo] open overlays instead — the
  /// dashboard screen handles those directly rather than routing them
  /// through here.
  Future<void> handleChip(
    SuggestedChip chip,
    UserProfile profile,
    String chipLabel,
  ) async {
    _appendUserMessage(chipLabel);
    switch (chip.action) {
      case SuggestedChipAction.cameraScan:
        // The wide sweep, not the bus-only frame this chip used to take.
        // Same path Volume Up and `look_around` use.
        await runSweep(profile);
      case SuggestedChipAction.openPath:
      case SuggestedChipAction.showScreenToPasserby:
      case SuggestedChipAction.reportHazard:
      case SuggestedChipAction.sendCaretakerVoiceMemo:
      case SuggestedChipAction.showMap:
      case SuggestedChipAction.hideMap:
        break; // Handled by the screen — see above.
    }
  }
}

/// Keeps the chat transcript across restarts — item 52.
final chatHistoryStoreProvider = Provider<ChatHistoryStore>((ref) {
  final store = ChatHistoryStore();
  // Whatever is still queued goes out before the container dies, so the last
  // few messages of a session are not the ones that get lost.
  ref.onDispose(store.flush);
  return store;
});

final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
