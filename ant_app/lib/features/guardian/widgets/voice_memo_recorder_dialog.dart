import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/wav_encoder.dart';

const _sampleRate = 8000; // Telephone-quality mono — plenty for a short voice memo.
const _maxSeconds = 20; // Hard cap so the base64 WAV stays well under Firestore's 1MiB doc limit.

/// Records a short voice memo (mic → WAV bytes → base64) and returns the
/// result, or null if cancelled. No real filesystem path needed — streams
/// raw PCM16 directly, which works identically on web and native (unlike
/// file-based encoders, which need a real path web doesn't have the same
/// way). See `wav_encoder.dart` for why PCM16 needs a header stitched back on.
class VoiceMemoRecorderDialog extends StatefulWidget {
  const VoiceMemoRecorderDialog({super.key});

  static Future<({String audioBase64, int durationSeconds})?> show(BuildContext context) {
    return showDialog(context: context, builder: (_) => const VoiceMemoRecorderDialog());
  }

  @override
  State<VoiceMemoRecorderDialog> createState() => _VoiceMemoRecorderDialogState();
}

class _VoiceMemoRecorderDialogState extends State<VoiceMemoRecorderDialog> {
  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  Timer? _ticker;
  final _pcm = BytesBuilder();
  int _elapsedSeconds = 0;
  bool _recording = false;
  bool _finished = false;
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission is needed to record a voice memo.');
      return;
    }
    final stream = await _recorder.startStream(
      const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: _sampleRate, numChannels: 1),
    );
    setState(() {
      _recording = true;
      _error = null;
    });
    _sub = stream.listen((chunk) => _pcm.add(chunk));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _elapsedSeconds++);
      if (_elapsedSeconds >= _maxSeconds) _stop();
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    await _sub?.cancel();
    await _recorder.stop();
    setState(() {
      _recording = false;
      _finished = true;
    });
  }

  void _send() {
    final wav = wrapPcm16AsWav(_pcm.toBytes(), sampleRate: _sampleRate, numChannels: 1);
    Navigator.of(context).pop((audioBase64: base64Encode(wav), durationSeconds: _elapsedSeconds));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Voice Memo'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: AppColors.danger)),
            const SizedBox(height: 12),
          ],
          Semantics(
            liveRegion: true,
            label: _recording
                ? 'Recording, $_elapsedSeconds seconds, maximum $_maxSeconds seconds'
                : _finished
                    ? 'Recording finished, $_elapsedSeconds seconds'
                    : 'Ready to record',
            child: Text(
              _recording
                  ? '● Recording… ${_elapsedSeconds}s / ${_maxSeconds}s'
                  : _finished
                      ? 'Recorded ${_elapsedSeconds}s'
                      : 'Tap Record to start (max ${_maxSeconds}s)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 16),
          if (!_recording && !_finished)
            ElevatedButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.mic_rounded),
              label: const Text('Record'),
            )
          else if (_recording)
            OutlinedButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('Stop'),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        if (_finished)
          ElevatedButton(onPressed: _send, child: const Text('Send')),
      ],
    );
  }
}
