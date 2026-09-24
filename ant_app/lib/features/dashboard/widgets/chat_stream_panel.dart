import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/routing_service.dart' show ManeuverKind;
import '../../../core/services/vision/ambient_hazard_scanner.dart';
import '../../../core/services/vision/snapshot_vision_service.dart';
import '../../../core/services/vision/vision_channel.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/background_listening_service.dart';
import '../../../core/services/emergency_channel.dart';
import '../../../core/services/dhaka_places.dart';
import '../../../core/services/earcon_service.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/wake_word_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/user_profile.dart';
import '../screens/camera_aiming_screen.dart';
import '../models/chat_message.dart';
import '../models/hazard_report.dart';
import '../models/suggested_chip.dart';
import '../providers/chat_providers.dart';
import 'chat_bubble.dart';
import 'suggested_chip_row.dart';
import 'camera_aiming_dialog.dart';

/// The Dynamic Chat Stream — top 60% of the Split-Mode Dashboard.
class ChatStreamPanel extends ConsumerStatefulWidget {
  const ChatStreamPanel({
    super.key,
    required this.onOverlayChip,
    required this.profile,
    this.onToggleMap,
    this.mapVisible = false,
  });

  /// Shows/hides the map. Null hides the control entirely — the panel is
  /// usable without one.
  final VoidCallback? onToggleMap;
  final bool mapVisible;

  /// [SuggestedChipAction.showScreenToPasserby] and
  /// [SuggestedChipAction.reportHazard] open full-screen overlays owned by
  /// the parent screen rather than staying inside the chat, so this callback
  /// hands those two actions back up — whether triggered by a chip tap or
  /// by the AI Assistant's function calling (see [ChatState.pendingOverlayAction]).
  /// Second argument is non-null only for
  /// [SuggestedChipAction.reportHazard] triggered by a command that already
  /// named the hazard — see [HazardReportPrefill].
  final void Function(SuggestedChipAction action, HazardReportPrefill? prefill)
  onOverlayChip;
  final UserProfile profile;

  @override
  ConsumerState<ChatStreamPanel> createState() => _ChatStreamPanelState();
}

class _ChatStreamPanelState extends ConsumerState<ChatStreamPanel>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _listening = false;
  bool _caretakerMode = false;
  bool _draftHasText = false;
  bool _cameraAimDialogOpen = false;
  bool _snapshotConsentDialogOpen = false;

  /// The assistant message the next thing typed or said will answer.
  ///
  /// Set by long-pressing a bubble. Cleared on send and by the × on the
  /// banner — a reply target that outlived its turn would silently attach an
  /// old quote to an unrelated question.
  ChatMessage? _replyingTo;

  /// True between "a listen was requested" and "that listen finished".
  /// Separate from [_listening], which only becomes true once the recognizer
  /// is actually up — the gap between the two is what a second wake-word
  /// detection used to land in.
  bool _startingListen = false;

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live: "Bad state: Using 'ref' when a widget is about to or has been
  // unmounted is unsafe").
  late final SttService _stt = ref.read(sttServiceProvider);
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);
  late final BackgroundListeningService _backgroundListening = ref.read(
    backgroundListeningServiceProvider,
  );

  /// The Volume-Down hold. Registered here because this panel is alive for
  /// the whole time the dashboard is, which is the whole time the physical
  /// trigger can fire — Android only delivers key events to a foregrounded
  /// activity.
  final _emergencyChannel = EmergencyChannel();

  /// The Volume-Up hold — Module 6's sweep trigger. Registered alongside the
  /// emergency one and for the same reason: Android delivers key events only
  /// to a foregrounded activity, and this panel is alive exactly as long as
  /// the dashboard is.
  final _visionChannel = VisionChannel();

  /// Held as a field rather than read from `ref` at the point of use, for the
  /// same reason `_wakeWord` and `_backgroundListening` are: `dispose()`
  /// releases the camera, and `ref` is unsafe once the widget is unmounting.
  /// Forced in `initState` alongside the others.
  late final SnapshotVisionService _vision = ref.read(
    snapshotVisionServiceProvider,
  );
  late final ChatController _chatController = ref.read(
    chatControllerProvider.notifier,
  );

  /// Module 6's unprompted hazard scanning. Held as a field for the same
  /// `ref`-in-dispose reason as the others.
  late final AmbientHazardScanner _ambient = ref.read(
    ambientHazardScannerProvider,
  );
  StreamSubscription<String>? _ambientSub;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onDraftChanged);
    // Forces both lazy `late final` initializers to run now, while `ref` is
    // still safe to use — otherwise, if push-to-talk is never tapped and
    // wake-word is off, `dispose()` ends up being the *first* access to one
    // or both, which is exactly the unsafe-`ref` crash these fields were
    // introduced to avoid.
    _stt;
    _wakeWord;
    _backgroundListening;
    _vision;
    _ambient;
    _chatController.registerCameraAimer(
      _openCameraAim,
      finish: _closeCameraAim,
    );
    // Spoken through the chat controller rather than straight to TTS, so an
    // ambient warning queues behind turn-by-turn guidance instead of talking
    // over it, and lands in the transcript for a Deaf-blind user.
    _ambientSub = _ambient.announcements.listen((line) {
      if (!mounted) return;
      unawaited(
        ref
            .read(chatControllerProvider.notifier)
            .announceAmbientHazard(line, widget.profile),
      );
    });
    final foregroundBusy = ref.read(foregroundAssistantBusyProvider);
    foregroundBusy.value = ref.read(chatControllerProvider).isAssistantTyping;
    ref.listenManual(
      chatControllerProvider.select((state) => state.isAssistantTyping),
      (_, isBusy) => foregroundBusy.value = isBusy,
    );
    unawaited(_ambient.start(widget.profile));
    // Feeds the scanner what is already known to be on this journey, so it
    // looks harder near a reported hazard or a crossing than it does on an
    // ordinary stretch of road. Cleared when the route goes away.
    ref.listenManual(chatControllerProvider.select((s) => s.pendingRoute), (
      previous,
      route,
    ) {
      _ambient.setRouteContext(
        hazards: route?.verdict.allHazards ?? const [],
        crossings: [
          for (final step in route?.steps ?? const [])
            if (step.maneuver == ManeuverKind.crossing) step.location,
        ],
      );
    });
    _emergencyChannel.onPhysicalTrigger(() async {
      if (!mounted) return;
      debugPrint('[Emergency] volume-down hold');
      await ref
          .read(chatControllerProvider.notifier)
          .triggerEmergency(widget.profile);
    });
    _visionChannel.onSnapshotTrigger(() async {
      if (!mounted) return;
      await ref
          .read(chatControllerProvider.notifier)
          .runSnapshot(widget.profile);
    });
    ref.read(ttsServiceProvider).setVoiceId(widget.profile.voiceId);
    _applyWakeWordThreshold();
    // The saved strength has to reach the service before the first turn, not
    // on the first visit to settings.
    ref.read(hapticsServiceProvider).intensity = widget.profile.hapticIntensity;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final d = Dashboard.of(widget.profile.language);
      final controller = ref.read(chatControllerProvider.notifier);
      // Item 52 — the transcript comes back before the welcome line does, so
      // a restored conversation is not preceded by a greeting that implies
      // nothing happened before it.
      await controller.restoreHistory(widget.profile.uid, d);
      controller.ensureWelcomeMessage(d);
    });
    if (widget.profile.wakeWordEnabled) _startWakeWordListening();
  }

  void _onDraftChanged() {
    final hasText = _textController.text.isNotEmpty;
    if (!mounted || hasText == _draftHasText) return;
    setState(() => _draftHasText = hasText);
  }

  Future<Uint8List?> _openCameraAim() async {
    if (!mounted) return null;
    final vision = _vision;
    if (!await vision.camera.open()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera is unavailable or permission was denied.'),
          ),
        );
      }
      vision.closeCamera();
      return null;
    }
    final controller = vision.camera.controller;
    if (controller == null || !mounted) {
      vision.closeCamera();
      return null;
    }
    _cameraAimDialogOpen = true;
    try {
      final captured = await showDialog<Uint8List>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CameraAimingDialog(controller: controller),
      );
      if (captured == null) vision.closeCamera();
      return captured;
    } finally {
      _cameraAimDialogOpen = false;
    }
  }

  Future<void> _closeCameraAim() async {
    if (!mounted || !_cameraAimDialogOpen) return;
    Navigator.of(context).pop();
  }

  /// Backgrounding/locking is exactly when continuous listening matters
  /// most (the user isn't looking at the screen at all) and exactly when
  /// Android would otherwise freeze or kill this process — start the
  /// foreground service so it doesn't, and stop it again once the app is
  /// back in front (no need for a persistent notification while visible).
  /// A no-op whenever wake-word itself is off.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Module 6, and checked before the wake-word guard below rather than
    // after: a camera left open is a hot phone and a draining battery for
    // somebody who cannot see the indicator light, and that is true whether
    // or not they use the wake word. Android reclaims the sensor on
    // backgrounding anyway, but it does so by invalidating the controller
    // rather than disposing it — which leaves a stale handle that throws on
    // the next scan and reads to the user as the feature having broken for
    // good. See `SnapshotCamera.releaseNow`.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      // Stops the ambient timer as well as releasing the sensor. A periodic
      // camera scan running behind a locked screen is the exact drain this
      // module is built to avoid, and the user cannot see it happening.
      _ambient.stop();
      _vision.releaseCamera();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_ambient.start(widget.profile));
    }

    if (!widget.profile.wakeWordEnabled) return;
    switch (state) {
      // `paused`/`hidden` mean the app really has gone away. `inactive` is
      // deliberately NOT in this list: it fires transiently while the app is
      // still on screen and fully usable — pulling down the notification
      // shade, an incoming-call banner, a permission dialog, the app
      // switcher — so starting on it put an ongoing "listening in the
      // background" notification in front of a user who had not
      // backgrounded anything, and flapped the service on every one of
      // those, since `inactive` is also the state every app passes through
      // on its way back to `resumed`.
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundListening.start();
      case AppLifecycleState.resumed:
        _backgroundListening.stop();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  void didUpdateWidget(covariant ChatStreamPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile.voiceId != oldWidget.profile.voiceId) {
      ref.read(ttsServiceProvider).setVoiceId(widget.profile.voiceId);
    }
    // Before the enabled check below, which returns early. The dial can be
    // moved without the toggle changing at all — in fact that is the normal
    // case, since somebody tuning it has the wake word switched on already.
    if (widget.profile.wakeWordThreshold !=
        oldWidget.profile.wakeWordThreshold) {
      _applyWakeWordThreshold();
    }
    if (widget.profile.hapticIntensity != oldWidget.profile.hapticIntensity) {
      ref.read(hapticsServiceProvider).intensity =
          widget.profile.hapticIntensity;
    }
    if (widget.profile.wakeWordEnabled == oldWidget.profile.wakeWordEnabled)
      return;
    if (widget.profile.wakeWordEnabled) {
      _startWakeWordListening();
    } else {
      _wakeWord.stop();
      _backgroundListening.stop();
    }
  }

  /// Pushes the user's chosen sensitivity into the detector.
  ///
  /// No restart needed — detection reads the threshold at comparison time,
  /// so a change takes effect on the very next scored window. That is what
  /// makes the dial usable at all: somebody tuning it says the phrase, reads
  /// the score, moves the slider, and says it again, without a round trip
  /// through a rebuild or a rebuilt APK.
  ///
  /// A null threshold means the profile has never been tuned, and the build's
  /// own default stands.
  void _applyWakeWordThreshold() {
    final chosen = widget.profile.wakeWordThreshold;
    _wakeWord.threshold = chosen ?? WakeWordService.defaultDetectionThreshold;
  }

  /// Starts (or restarts, after a command was just handled) continuous
  /// "Hey ANT" listening. Stopped while push-to-talk command listening is
  /// actually in progress — the two shouldn't fight over the microphone —
  /// and restarted once that finishes, so detection is effectively
  /// continuous whenever the toggle is on. The actual stop/restart around
  /// the STT session lives in [_toggleListening] itself now, not here — see
  /// its doc comment for why.
  Future<void> _startWakeWordListening() async {
    await _wakeWord.start(
      onDetected: () {
        if (!mounted) return;
        HapticFeedback.mediumImpact();
        _listenFromWakeWord(Dashboard.of(widget.profile.language));
      },
    );
  }

  @override
  void dispose() {
    _vision.closeCamera();
    _chatController.registerCameraAimer(null);
    WidgetsBinding.instance.removeObserver(this);
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _scrollController.dispose();
    _stt.stop();
    _wakeWord.stop();
    _backgroundListening.stop();
    _visionChannel.dispose();
    unawaited(_ambientSub?.cancel());
    _ambient.stop();
    // Leaving the dashboard releases the sensor rather than waiting out the
    // warm window — see `SnapshotCamera`.
    _vision.releaseCamera();
    super.dispose();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _handleChip(SuggestedChip chip, Dashboard d) async {
    // Chips the *screen* owns, because they open something that needs a
    // `BuildContext` this panel does not have a route from.
    //
    // `openPath` was missing from this list and that was the whole bug:
    // tapping পথ appended a user bubble and then did nothing at all, because
    // `ChatController.handleChip` has only a `break` for it and
    // `_openPathSheet` is on the dashboard. Reported twice as the
    // maps/location feature not existing — it existed and was unreachable.
    if (chip.action == SuggestedChipAction.showScreenToPasserby ||
        chip.action == SuggestedChipAction.reportHazard ||
        chip.action == SuggestedChipAction.openPath ||
        chip.action == SuggestedChipAction.sendCaretakerVoiceMemo) {
      widget.onOverlayChip(chip.action, null);
      return;
    }

    // An explicit camera tap always opens the viewfinder. Analyze the exact
    // shutter frame; spoken/Volume Up sweeps remain separate commands.
    if (chip.action == SuggestedChipAction.cameraScan &&
        shouldOfferAiming(widget.profile.visionLevel)) {
      final captured = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => CameraAimingScreen(language: widget.profile.language),
        ),
      );
      if (captured == null || !mounted) return;
      await ref
          .read(chatControllerProvider.notifier)
          .runSnapshot(widget.profile, capturedJpeg: captured);
      _scrollToEnd();
      return;
    }
    if (chip.action == SuggestedChipAction.cameraScan) {
      await ref
          .read(chatControllerProvider.notifier)
          .runSnapshot(widget.profile);
      _scrollToEnd();
      return;
    }
    await ref
        .read(chatControllerProvider.notifier)
        .handleChip(chip, widget.profile, chip.labelFor(d));
    _scrollToEnd();
  }

  Future<void> _submitText() async {
    final text = _textController.text;
    final replyTo = _replyingTo;
    _textController.clear();
    if (replyTo != null) setState(() => _replyingTo = null);
    final chat = ref.read(chatControllerProvider.notifier);
    if (_caretakerMode) {
      await chat.sendCaretakerText(text, widget.profile);
    } else {
      await chat.sendFreeText(
        text,
        widget.profile,
        replyTo: replyTo?.text,
        replyToMessageId: replyTo?.id,
      );
    }
    _scrollToEnd();
  }

  /// Push-to-talk, triggered either by the mic button or by wake-word
  /// detection. Pausing/resuming wake-word listening around this session
  /// is handled centrally inside `SttService.listenOnce` now (see its doc
  /// comment) — every mic entry point in the app gets that coordination
  /// automatically, so this doesn't need its own copy of that logic.
  /// The mic button. A tap while a session is running ends it.
  ///
  /// It used to do nothing at all. One method served both the button and
  /// wake-word detection, and its reentrancy guard — there to stop a second
  /// detection cancelling the session the first one started — was held for
  /// the whole of `listenOnce`, not just the start. So every tap on the red
  /// mic hit `if (_startingListen) return`, and the `if (_listening)` branch
  /// under it was unreachable. A user who opened the microphone by accident
  /// had no way to close it, which for someone who cannot see that it is
  /// open is worse than a stuck button.
  ///
  /// The two callers want opposite things from a session that is already
  /// running, so they are two methods now: a tap stops it, a wake word
  /// leaves it alone.
  Future<void> _toggleListening(Dashboard d) async {
    if (_listening || _startingListen) {
      // `SttService.stop()` completes the pending session's completer, so
      // the `listenOnce` below returns and its `finally` clears both flags.
      await _stt.stop();
      // The falling half of item 59's pair. Deliberately only on a manual
      // close: a session that ends because the user finished speaking is
      // followed by the assistant's reply, which is its own confirmation —
      // a tone in front of it would be noise. A session the user closed by
      // hand has nothing else to confirm it, and "is it still listening?"
      // is unanswerable without sight.
      unawaited(ref.read(earconServiceProvider).play(Earcon.stopped));
      return;
    }
    await _beginListening(d);
  }

  /// Wake-word detection. Never cancels a session already in progress: the
  /// phrase was almost certainly the user starting to talk into a
  /// microphone that is already open, and stopping it there is how "Hey ANT
  /// works once, then stops working while the mic icon stays on" happened —
  /// alternating start/stop, the icon left showing whenever the pair ended
  /// on a start.
  Future<void> _listenFromWakeWord(Dashboard d) async {
    if (_listening || _startingListen) return;
    await _beginListening(d);
  }

  Future<void> _beginListening(Dashboard d) async {
    // Set synchronously, before the first await, so two calls in the same
    // turn cannot both get past the guards above.
    _startingListen = true;
    // Opening the microphone is the user saying "stop talking and listen to
    // me". Until this call they had no way to say it: the mic opened
    // *underneath* the narration and the app kept reading its backlog into
    // its own recognizer. See `ChatController.interruptNarration`.
    //
    // Before `ensureAvailable`, deliberately. That check can take a platform
    // round trip and can fail, and the one thing the user unambiguously
    // asked for — silence — should not be contingent on the microphone
    // turning out to be available.
    ref.read(chatControllerProvider.notifier).interruptNarration();
    try {
      if (!await _stt.ensureAvailable()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
        return;
      }
      setState(() => _listening = true);
      // Item 59 — "sound cue when mic is activated after hey jarvis or any
      // autolistening". There was a haptic and nothing audible, which is the
      // right cue for a phone in a hand and no cue at all for one in a
      // pocket, which is where a blind user walking with a cane keeps it.
      //
      // Started here and deliberately **not awaited**. Awaiting it was the
      // first version and it was wrong: it put audio playback on the
      // critical path of opening the microphone, so a device where the audio
      // plugin stalls or is missing gets no microphone at all. In an app
      // whose most repeated complaint is some form of "it didn't hear me",
      // a cue that can prevent listening is worse than no cue.
      //
      // The tone therefore overlaps the first moments of the session. That
      // is an acceptable trade where narration would not be (item 23): a
      // 160ms pure sine is not speech, and no recognizer turns it into
      // words, whereas the app reading a sentence aloud into its own
      // microphone genuinely did.
      unawaited(ref.read(earconServiceProvider).play(Earcon.listening));
      await _stt.listenOnce(
        language: widget.profile.language,
        // The main mic: anything can be said into it, and a destination is
        // among the most common. Reported directly — a Dhaka place name comes
        // back as something unrelated, because a general model is weighted
        // towards ordinary vocabulary and thana names are rare words that
        // sound like common ones. The user's own saved places lead the list:
        // what somebody calls their own home is a far stronger hint than any
        // gazetteer entry, and it is the name they will actually say.
        phraseHints: placeNameHints(
          savedPlaceLabels: [
            for (final p in widget.profile.savedPlaces) p.label,
          ],
          homeAddress: widget.profile.homeAddress,
          safePlaceAddress: widget.profile.safePlaceAddress,
        ),
        onResult: (text, isFinal) {
          // `mounted` must gate the whole callback — a pending listen session
          // can still deliver a result after this widget is gone (same crash
          // class confirmed live elsewhere: writing into a disposed
          // controller).
          if (!mounted) return;
          _textController.text = text;
          _textController.selection = TextSelection.collapsed(
            offset: text.length,
          );
          if (isFinal) {
            setState(() => _listening = false);
            if (text.trim().isNotEmpty) _submitText();
          }
        },
      );
    } finally {
      // In `finally` so a throw from `listenOnce` cannot strand the flag —
      // that would wedge the mic button permanently, with no way back short
      // of leaving the screen.
      _startingListen = false;
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatControllerProvider);
    final d = Dashboard.of(widget.profile.language);
    _scrollToEnd();

    // Item 60 — "after ai asks a question, it should reopen mic".
    //
    // Auto-listen was a setting with no reader on this screen: `profile
    // .voiceAutoListen` was consulted by onboarding and by the settings
    // toggle, and by nothing on the dashboard at all. So the microphone
    // reopened after no chat reply whatever, question or not, and a user who
    // was asked "which one did you mean?" had to find the mic button to
    // answer — which is the one thing someone who cannot see the screen
    // should never have to do mid-conversation.
    //
    // The controller decides *when* (after the question has finished being
    // spoken, so the recognizer never opens under the app's own voice) and
    // this decides *whether the microphone is free* — `_beginListening`'s
    // own guards refuse if a session is already running.
    ref.listen(chatControllerProvider.select((s) => s.answerInvitations), (
      previous,
      next,
    ) {
      if (previous == null || next <= previous) return;
      if (_listening || _startingListen) return;
      unawaited(_beginListening(Dashboard.of(widget.profile.language)));
    });

    ref.listen(chatControllerProvider.select((s) => s.pendingOverlayAction), (
      previous,
      next,
    ) {
      if (next == null) return;
      // Read the prefill from the same state snapshot, before clearing —
      // `clearPendingOverlay` clears both.
      widget.onOverlayChip(
        next,
        ref.read(chatControllerProvider).pendingHazardPrefill,
      );
      ref.read(chatControllerProvider.notifier).clearPendingOverlay();
    });

    ref.listen(
      chatControllerProvider.select((s) => s.snapshotConsentPrompt),
      (previous, pending) {
        if (pending && !_snapshotConsentDialogOpen) {
          _snapshotConsentDialogOpen = true;
          unawaited(_showSnapshotConsentDialog(d));
        } else if (!pending && _snapshotConsentDialogOpen) {
          _snapshotConsentDialogOpen = false;
          if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        }
      },
    );

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            itemCount:
                chatState.messages.length +
                (chatState.isAssistantTyping ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= chatState.messages.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      liveRegion: true,
                      label: d.chatAssistantTyping,
                      child: SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                );
              }
              final message = chatState.messages[index];
              return ChatBubble(
                message: message,
                strings: d,
                // Only the assistant's messages are worth replying to — a
                // user quoting themselves tells the model nothing it does
                // not already have.
                onReply:
                    message.sender == ChatSender.assistant &&
                        message.text.trim().isNotEmpty
                    ? () => setState(() => _replyingTo = message)
                    : null,
              );
            },
          ),
        ),
        if (_replyingTo != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Semantics(
              liveRegion: true,
              label: d.chatReplyingTo(_replyingTo!.text),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                decoration: BoxDecoration(
                  color: AppColors.primaryLight.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: const Border(
                    left: BorderSide(width: 3, color: AppColors.primary),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _replyingTo!.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: d.chatReplyCancel,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => setState(() => _replyingTo = null),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (!_draftHasText)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.profile.pairedUserId != null)
                  FilterChip(
                    avatar: Icon(
                      _caretakerMode
                          ? Icons.support_agent_rounded
                          : Icons.support_agent_outlined,
                      size: 18,
                    ),
                    label: const Text('Caretaker'),
                    selected: _caretakerMode || chatState.caretakerMessageArmed,
                    onSelected: (_) {
                      final turnOn =
                          !(_caretakerMode || chatState.caretakerMessageArmed);
                      ref
                          .read(chatControllerProvider.notifier)
                          .clearOneShotCaretakerMessage();
                      setState(() => _caretakerMode = turnOn);
                    },
                  ),
                if (widget.profile.pairedUserId != null)
                  ActionChip(
                    avatar: const Icon(Icons.image_outlined, size: 18),
                    label: const Text('Send image'),
                    onPressed: () => ref
                        .read(chatControllerProvider.notifier)
                        .sendPhotoToCaretaker(widget.profile),
                  ),
                SuggestedChipRow(
                  // The voice-message chip only exists once there is somebody to
                  // send one to — see `suggestedChipsFor`.
                  chips: suggestedChipsFor(
                    caretakerPaired: widget.profile.pairedUserId != null,
                  ),
                  strings: d,
                  onTap: (chip) => _handleChip(chip, d),
                ),
              ],
            ),
          ),
        // Mic on the left of the input bar rather than on its own row.
        //
        // It was a 76dp button centred on a line of its own, which read as
        // the panel's main control — true — but cost a whole row of height
        // to say so, on top of the row the text field already took. Side by
        // side, it is still the largest and left-most target on the bar (the
        // first thing a thumb or a screen reader reaches) while the chat
        // above keeps the space both rows used to consume.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!_draftHasText && widget.onToggleMap != null) ...[
                // Shaped like the mic and the send button, not like a bare
                // app-bar icon.
                //
                // It sits between two filled circles and was a flat glyph, so
                // it read as decoration rather than as the third control on
                // the row — the one a sighted companion reaches for first.
                // A filled circle of the same family says "this is a button
                // of the same kind", which is most of what makes a row of
                // controls scannable at a glance or at low vision.
                //
                // The on/off state is still carried three ways over, because
                // colour alone is not a state indicator: the icon stays
                // filled-vs-outlined, the circle changes colour, and the
                // semantics label says show or hide.
                Semantics(
                  button: true,
                  label: widget.mapVisible
                      ? d.mapHideSemantics
                      : d.mapShowSemantics,
                  child: Material(
                    color: widget.mapVisible
                        ? AppColors.primary
                        : AppColors.primaryLight,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      // Beside the mic and the send button rather than in the
                      // app bar's far corner, which is the furthest point on
                      // the screen from a thumb that is already on this row.
                      onTap: widget.onToggleMap,
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          widget.mapVisible
                              ? Icons.map_rounded
                              : Icons.map_outlined,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (!_draftHasText) const SizedBox(width: 8),
              if (!_draftHasText)
                Semantics(
                  button: true,
                  label: _listening
                      ? d.chatListeningSemantics
                      : d.chatSpeakSemantics,
                  hint: d.chatSpeakHint,
                  liveRegion: _listening,
                  child: Material(
                    color: _listening ? AppColors.danger : AppColors.primary,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _toggleListening(d),
                      child: SizedBox(
                        width: 52,
                        height: 52,
                        child: Icon(
                          _listening
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          color: Colors.white,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_draftHasText) const SizedBox(width: 10),
              Expanded(
                child: Semantics(
                  textField: true,
                  label: d.chatInputHint,
                  child: TextField(
                    controller: _textController,
                    onSubmitted: (_) => _submitText(),
                    textInputAction: TextInputAction.send,
                    minLines: 1,
                    maxLines: 1,
                    keyboardType: TextInputType.text,
                    // Denser than the theme default, which was sized for a
                    // form rather than for one line in a crowded panel.
                    decoration: InputDecoration(
                      hintText: d.chatInputHint,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Semantics(
                button: true,
                label: d.chatSendSemantics,
                child: Material(
                  color: AppColors.primaryLight,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _submitText(),
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(
                        Icons.send_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showSnapshotConsentDialog(Dashboard d) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(d.caretakerSnapshotAsk),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _snapshotConsentDialogOpen = false;
              unawaited(
                _chatController.resolveSnapshotConsent(false, widget.profile),
              );
            },
            child: Text(d.caretakerSnapshotNoButton),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _snapshotConsentDialogOpen = false;
              unawaited(
                _chatController.resolveSnapshotConsent(null, widget.profile),
              );
            },
            child: Text(d.caretakerSnapshotLaterButton),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _snapshotConsentDialogOpen = false;
              unawaited(
                _chatController.resolveSnapshotConsent(true, widget.profile),
              );
            },
            child: Text(d.caretakerSnapshotSendButton),
          ),
        ],
      ),
    );
    _snapshotConsentDialogOpen = false;
  }
}
