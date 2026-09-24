import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// A short, user-triggered camera preview. The exact frame shown in the
/// viewfinder is returned for analysis or caretaker sharing.
class CameraAimingDialog extends StatefulWidget {
  const CameraAimingDialog({super.key, required this.controller});

  final CameraController controller;

  @override
  State<CameraAimingDialog> createState() => _CameraAimingDialogState();
}

class _CameraAimingDialogState extends State<CameraAimingDialog> {
  bool _capturing = false;

  Future<void> _capture() async {
    setState(() => _capturing = true);
    try {
      final photo = await widget.controller.takePicture();
      final bytes = await photo.readAsBytes();
      if (mounted) Navigator.of(context).pop<Uint8List>(bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() => _capturing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not capture this frame. Try again.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Close camera',
                  onPressed: _capturing
                      ? null
                      : () => Navigator.of(context).pop<Uint8List>(),
                  icon: const Icon(Icons.close_rounded),
                ),
                const Expanded(
                  child: Text(
                    'Aim the camera at what you want to share or ask about',
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: widget.controller.value.aspectRatio,
                child: CameraPreview(widget.controller),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _capturing ? null : _capture,
                icon: Icon(
                  _capturing ? Icons.hourglass_top : Icons.camera_alt_rounded,
                ),
                label: Text(_capturing ? 'Capturing…' : 'Capture this frame'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
