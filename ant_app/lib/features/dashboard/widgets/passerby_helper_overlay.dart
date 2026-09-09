import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/cloud_stt_service.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/theme/app_colors.dart';

/// Full-screen route for the "Show Screen" Passerby Helper overlay: forces
/// landscape, solid bright yellow, massive black text. Tap anywhere to
/// dismiss and restore portrait — or, since the person who opened this
/// can't necessarily see it to find that tap target, just say "go back"
/// at any point; the overlay listens continuously for that the whole time
/// it's showing, via [CloudSttService] (a real open stream, no restarts)
/// when configured, or a restart-loop over the on-device recognizer when
/// it isn't — see [_startListeningForDismiss].
class PasserbyHelperOverlay extends ConsumerStatefulWidget {
  const PasserbyHelperOverlay({super.key, required this.message, required this.strings, required this.language});

  final String message;
  final Dashboard strings;
  final AppLanguage language;

  /// How long tap-anywhere stays inert.
  ///
  /// Reported as "it closed in 1 sec without me doing anything while its
  /// narration kept on playing on the dashboard", and the device log shows
  /// exactly what closed it — a two-finger, 15 ms touch delivered to the
  /// activity in the same frame the overlay pushed:
  ///
  ///   ACTION_DOWN             pointerCount=1
  ///   ACTION_POINTER_DOWN(1)  pointerCount=2
  ///   ...15ms...
  ///   ACTION_POINTER_UP(0) / ACTION_UP
  ///
  /// A full-screen surface whose entire body is a dismiss target will always
  /// be vulnerable to whatever touch stream was in progress when it arrived —
  /// a rotation re-dispatch, a lingering finger, an accessibility gesture.
  /// The grace window is the standard guard, and it costs nothing: nobody
  /// opens this and then dismisses it inside a second on purpose.
  ///
  /// The explicit back button is deliberately *not* gated. A press on a
  /// specific control is an intention; a touch anywhere on a yellow rectangle
  /// is not.
  static const Duration tapGrace = Duration(milliseconds: 900);

  static Future<void> show(BuildContext context, String message, Dashboard strings, AppLanguage language) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, _, _) => PasserbyHelperOverlay(message: message, strings: strings, language: language),
      ),
    );
  }

  @override
  ConsumerState<PasserbyHelperOverlay> createState() => _PasserbyHelperOverlayState();
}

class _PasserbyHelperOverlayState extends ConsumerState<PasserbyHelperOverlay> {
  bool _dismissed = false;

  /// False until [PasserbyHelperOverlay.tapGrace] has elapsed, so
  /// tap-anywhere ignores a touch that was already in flight when this
  /// appeared. A timer rather than a wall-clock comparison: the behaviour is
  /// then drivable from a widget test, which a `DateTime.now()` check is not.
  bool _tapsArmed = false;
  Timer? _armTimer;


  late final TtsService _tts = ref.read(ttsServiceProvider);

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting.
  late final SttService _stt = ref.read(sttServiceProvider);
  late final CloudSttService _cloudStt = ref.read(cloudSttServiceProvider);

  // Short *roots* rather than full fixed phrases — a longer exact phrase
  // (e.g. "বন্ধ করো") missed a live, genuine "go back" attempt outright
  // just because the recognizer heard "বন্ধ কর" (a different, equally
  // valid verb ending) instead. A root match is forgiving of that kind of
  // natural variation.
  static const _dismissPhrasesEn = ['back', 'close', 'dismiss', 'home'];
  static const _dismissPhrasesBn = ['ফির', 'পিছ', 'ড্যাশবোর্ড', 'বন্ধ'];
  // The locale this listener runs in is locked to `widget.language` for
  // the whole session (the recognizer API only takes one locale at a
  // time) — so if that's Bangla and the user actually says "go back" in
  // English, it doesn't get recognized as English at all. Confirmed live:
  // it comes back as a Bangla-script phonetic approximation of the English
  // words instead ("গো ব্যাক"), consistently. Matched explicitly here as
  // its own case rather than trying to generalize it.
  static const _dismissPhrasesPhoneticBn = ['গো ব্যাক', 'গোব্যাক'];

  bool _isDismissPhrase(String text) {
    final lower = text.toLowerCase();
    return _dismissPhrasesEn.any(lower.contains) ||
        _dismissPhrasesBn.any(text.contains) ||
        _dismissPhrasesPhoneticBn.any(text.contains);
  }

  @override
  void initState() {
    super.initState();
    // Forces both lazy `late final` initializers to run now, while `ref`
    // is still safe to use — otherwise `dispose()` could end up being the
    // first access to one of them, which is unsafe (see the established
    // pattern elsewhere in this app for the crash this avoids).
    _stt;
    _cloudStt;
    _tts;
    _armTimer = Timer(PasserbyHelperOverlay.tapGrace, () {
      if (mounted) _tapsArmed = true;
    });
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (ref.read(ttsEnabledProvider)) {
        await ref.read(ttsServiceProvider).speak(widget.strings.passerbyOverlayShownAnnouncement,
            language: widget.language);
      }
      if (mounted) _startListeningForDismiss();
    });
  }

  void _handleDismissResult(String text, bool isFinal) {
    debugPrint('[PasserbyOverlay] heard "$text" (isFinal=$isFinal)');
    if (!mounted || _dismissed) return;
    // Checked on every result, not gated on `isFinal` — confirmed live
    // (with the on-device recognizer) that the dismiss phrase was
    // consistently transcribed correctly as a partial result, but the
    // session then ended via error/timeout without ever delivering a
    // final one, so a match that only ever looked at final results
    // silently never fired despite the right words genuinely being heard.
    if (_isDismissPhrase(text)) {
      debugPrint('[PasserbyOverlay] matched dismiss phrase, popping');
      _dismissed = true;
      Navigator.of(context).maybePop();
    }
  }

  /// Prefers [CloudSttService] — a genuinely continuous stream, no
  /// restarts, no mic-indicator flicker — falling back to a restart-loop
  /// over the on-device recognizer when Cloud STT isn't configured or
  /// fails to start. Either way, listening stays available for the whole
  /// time this overlay is up, since the person who opened it may not be
  /// able to see the tap-to-close hint at all.
  Future<void> _startListeningForDismiss() async {
    if (!mounted || _dismissed) return;
    // A reliable, app-controlled "listening started" cue, fired once here
    // rather than on every internal restart of the fallback loop below —
    // requested explicitly live since the OS's own mic-start sound wasn't
    // consistently present.
    HapticFeedback.lightImpact();
    final usingCloud = await _cloudStt.start(language: widget.language, onResult: _handleDismissResult);
    if (usingCloud) {
      debugPrint('[PasserbyOverlay] listening for dismiss phrase via Cloud STT (continuous)');
      return;
    }
    debugPrint('[PasserbyOverlay] Cloud STT unavailable — falling back to on-device restart-loop listening');
    _listenForDismissOnDeviceLoop();
  }

  /// Fallback only — each iteration is a discrete `SpeechToText.listen()`
  /// session that ends and gets restarted, which is visibly audible/visible
  /// on-device as the mic indicator flickering on the same cycle (confirmed
  /// live). `pauseFor` is set higher than this app's usual few-seconds
  /// default specifically to space those restarts out — a real trade-off
  /// against dismiss responsiveness, not a full fix; [CloudSttService]
  /// above is the actual fix, used automatically whenever it's configured.
  Future<void> _listenForDismissOnDeviceLoop() async {
    if (!mounted || _dismissed) return;
    if (!await _stt.ensureAvailable()) {
      debugPrint('[PasserbyOverlay] on-device STT not available either, not listening for dismiss');
      return;
    }
    debugPrint('[PasserbyOverlay] listening for dismiss phrase (on-device loop)...');
    await _stt.listenOnce(
      language: widget.language,
      pauseFor: const Duration(seconds: 6),
      onResult: _handleDismissResult,
    );
    if (mounted && !_dismissed) _listenForDismissOnDeviceLoop();
  }

  @override
  void dispose() {
    _dismissed = true;
    _armTimer?.cancel();
    // A screen's narration belongs to that screen. This one kept talking on
    // the dashboard after the overlay closed — the announcement is six
    // seconds long and the overlay can be gone in one, so the user was left
    // being told how to use something that was no longer in front of them.
    _tts.stop();
    _stt.stop();
    _cloudStt.stop();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _dismiss() {
    _dismissed = true;
    Navigator.of(context).maybePop();
  }

  /// Tap-anywhere, guarded by [tapGrace]. See its doc comment.
  void _dismissByTap() {
    if (!_tapsArmed) {
      debugPrint('[PasserbyOverlay] ignoring a tap inside the grace window');
      return;
    }
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.passerbyHelperBackground,
      body: Stack(
        children: [
          Semantics(
            label: '${widget.message}. ${widget.strings.passerbyOverlayTapToClose}',
            liveRegion: true,
            child: GestureDetector(
              onTap: _dismissByTap,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    widget.message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.passerbyHelperText,
                      fontSize: 56,
                      fontWeight: FontWeight.w900,
                      height: 1.15,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // A visible, discoverable way back beyond tap-anywhere/voice — a
          // sighted passerby (or the person who opened this, once handed
          // the phone back) has no other obvious affordance on an
          // otherwise chrome-free full-screen display.
          Positioned(
            top: 16,
            left: 16,
            child: SafeArea(
              child: Semantics(
                button: true,
                label: widget.strings.passerbyOverlayTapToClose,
                child: Material(
                  color: AppColors.passerbyHelperText.withValues(alpha: 0.12),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    color: AppColors.passerbyHelperText,
                    onPressed: _dismiss,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
