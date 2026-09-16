import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/haptics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/wav_encoder.dart';
import '../../guardian/providers/guardian_providers.dart';

/// Records a short message in the user's own voice and sends it to their
/// caretaker.
///
/// ## Why this is not `VoiceMemoRecorderDialog`
///
/// That dialog already exists and does the same recording, but it is the
/// *caretaker's*: a small `AlertDialog` with a Record button, a Stop button
/// and a Send button, driven by reading the screen. Handing that to a blind
/// user would mean asking them to find three small targets in sequence, with
/// nothing spoken and no way to tell whether the microphone is open.
///
/// So this is the same recording with the interaction turned inside out:
///
/// - It **says what it is doing** before the microphone opens, and waits for
///   that to finish. Starting the recorder under its own narration is item
///   23 all over again — the app recording itself.
/// - It **buzzes** when recording actually starts. Item 59 asks for a cue
///   when the mic opens, and a user with the phone in their pocket has
///   nothing else to go on.
/// - The **whole screen is the send button** while recording. One target the
///   size of the display needs no aiming, and is the only shape of control
///   that works reliably without sight.
/// - It **stops itself** at the cap and sends what it has, so a user who
///   walks off mid-sentence still gets their message delivered rather than
///   leaving the microphone open.
///
/// ## Why a recording at all, when speech could be transcribed
///
/// Because this app mis-hears people constantly — items 46 and 54 are both
/// that — and the caretaker is the one person for whom being misquoted
/// matters. A recording cannot be mis-transcribed. It also carries the thing
/// a transcript throws away, which is how the person sounded.
class CaretakerVoiceMemoOverlay {
  CaretakerVoiceMemoOverlay._();

  static Future<void> show(
    BuildContext context, {
    required String disabledUserUid,
    required String caretakerUid,
    required Dashboard strings,
    required AppLanguage language,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MemoRecorder(
        disabledUserUid: disabledUserUid,
        caretakerUid: caretakerUid,
        strings: strings,
        language: language,
      ),
    );
  }
}

/// Telephone-quality mono. Plenty for speech, and a quarter the bytes of
/// anything higher — which matters, because the clip is base64'd into a
/// Firestore document rather than uploaded to Storage.
const int _sampleRate = 8000;

/// Hard cap. Keeps the encoded WAV well under Firestore's 1MiB document
/// limit, and keeps a forgotten recorder from running until the battery goes.
const int _maxSeconds = 20;

/// Below this there is nothing worth sending — a mis-tap, or a pocket.
const int _minSeconds = 1;

class _MemoRecorder extends ConsumerStatefulWidget {
  const _MemoRecorder({
    required this.disabledUserUid,
    required this.caretakerUid,
    required this.strings,
    required this.language,
  });

  final String disabledUserUid;
  final String caretakerUid;
  final Dashboard strings;
  final AppLanguage language;

  @override
  ConsumerState<_MemoRecorder> createState() => _MemoRecorderState();
}

enum _Phase { announcing, recording, sending, done }

class _MemoRecorderState extends ConsumerState<_MemoRecorder> {
  final _recorder = AudioRecorder();
  final _pcm = BytesBuilder();
  StreamSubscription<Uint8List>? _sub;
  Timer? _ticker;

  _Phase _phase = _Phase.announcing;
  int _elapsedSeconds = 0;
  String? _error;

  /// Guards the send path. The cap timer and a tap can land together, and
  /// sending the same clip twice would put two copies on a caretaker's phone.
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_begin());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    final d = widget.strings;
    // Spoken first, and awaited. Opening the microphone underneath this would
    // record the app's own narration — the exact defect of item 23.
    try {
      await ref.read(ttsServiceProvider).speak(d.voiceMemoIntro, language: widget.language);
    } catch (_) {
      // A silent device must not stop somebody sending a message.
    }
    if (!mounted) return;

    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      setState(() {
        _error = d.voiceMemoNoMic;
        _phase = _Phase.done;
      });
      await _say(d.voiceMemoNoMic);
      return;
    }

    final Stream<Uint8List> stream;
    try {
      stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );
    } catch (e) {
      debugPrint('[VoiceMemo] could not start the recorder: $e');
      if (!mounted) return;
      setState(() {
        _error = d.voiceMemoNoMic;
        _phase = _Phase.done;
      });
      return;
    }
    if (!mounted) return;

    // Item 59's cue, applied here: something has to say "the microphone is
    // open now" to a user who cannot see the screen turn red.
    unawaited(ref.read(hapticsServiceProvider).play(HapticCue.confirmation));

    setState(() => _phase = _Phase.recording);
    _sub = stream.listen(
      _pcm.add,
      onError: (Object e) => debugPrint('[VoiceMemo] recording stream: $e'),
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
      // Stops itself rather than waiting to be told. Someone who has walked
      // off mid-sentence still gets what they said delivered.
      if (_elapsedSeconds >= _maxSeconds) unawaited(_finish(send: true));
    });
  }

  Future<void> _say(String text) async {
    try {
      await ref.read(ttsServiceProvider).speak(text, language: widget.language);
    } catch (_) {
      // Nothing useful to do about a device that will not speak.
    }
  }

  Future<void> _finish({required bool send}) async {
    if (_finishing) return;
    _finishing = true;
    _ticker?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[VoiceMemo] stop failed: $e');
    }
    if (!mounted) return;

    final d = widget.strings;
    if (!send) {
      await _say(d.voiceMemoCancelled);
      if (mounted) Navigator.of(context).pop();
      return;
    }

    final seconds = _elapsedSeconds;
    if (seconds < _minSeconds || _pcm.isEmpty) {
      // Nothing was captured. Saying so beats a caretaker receiving silence
      // and wondering what it meant.
      await _say(d.voiceMemoTooShort);
      if (mounted) Navigator.of(context).pop();
      return;
    }

    setState(() => _phase = _Phase.sending);
    final wav = wrapPcm16AsWav(_pcm.toBytes(), sampleRate: _sampleRate, numChannels: 1);
    try {
      await ref.read(communicationServiceProvider).sendVoiceMemo(
            disabledUserUid: widget.disabledUserUid,
            fromUid: widget.disabledUserUid,
            toUid: widget.caretakerUid,
            audioBase64: base64Encode(wav),
            durationSeconds: seconds,
          );
      await _say(d.voiceMemoSent(seconds));
    } catch (e) {
      debugPrint('[VoiceMemo] send failed: $e');
      await _say(d.caretakerMessageFailed);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.strings;
    final theme = Theme.of(context);
    final recording = _phase == _Phase.recording;

    return PopScope(
      // The back gesture cancels the recording rather than leaving a
      // microphone open behind a dismissed dialog.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_finish(send: false));
      },
      child: Dialog.fullscreen(
        backgroundColor: theme.scaffoldBackgroundColor,
        child: Semantics(
          button: recording,
          liveRegion: true,
          label: recording
              ? '${d.voiceMemoRecording} $_elapsedSeconds. ${d.voiceMemoSendButton}'
              : _error ?? d.voiceMemoRecording,
          // The whole screen. One target the size of the display needs no
          // aiming, which is the only kind that works without sight.
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: recording ? () => unawaited(_finish(send: true)) : null,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      recording ? Icons.mic_rounded : Icons.hourglass_empty_rounded,
                      size: 92,
                      color: recording ? AppColors.danger : theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _error ?? (recording ? d.voiceMemoRecording : ''),
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    if (recording) ...[
                      const SizedBox(height: 8),
                      Text('$_elapsedSeconds / $_maxSeconds s',
                          style: theme.textTheme.titleLarge),
                      const SizedBox(height: 28),
                      Text(
                        d.voiceMemoSendButton,
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(color: theme.colorScheme.primary),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 36),
                    SizedBox(
                      width: double.infinity,
                      child: Semantics(
                        button: true,
                        label: d.voiceMemoCancelButton,
                        child: OutlinedButton(
                          onPressed: _finishing ? null : () => unawaited(_finish(send: false)),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                          ),
                          child: Text(d.voiceMemoCancelButton),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
