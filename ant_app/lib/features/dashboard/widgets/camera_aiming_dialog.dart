import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// A short, user-triggered camera preview. Capture remains in
/// SnapshotVisionService after the person confirms the aim.
class CameraAimingDialog extends StatefulWidget {
  const CameraAimingDialog({
    super.key,
    required this.controller,
    required this.onUseView,
  });

  final CameraController controller;
  final VoidCallback onUseView;

  @override
  State<CameraAimingDialog> createState() => _CameraAimingDialogState();
}

class _CameraAimingDialogState extends State<CameraAimingDialog> {
  bool _analyzing = false;

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
                  onPressed: _analyzing
                      ? null
                      : () => Navigator.of(context).pop(false),
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
                onPressed: _analyzing
                    ? null
                    : () {
                        setState(() => _analyzing = true);
                        widget.onUseView();
                      },
                icon: Icon(
                  _analyzing ? Icons.auto_awesome : Icons.camera_alt_rounded,
                ),
                label: Text(
                  _analyzing ? 'Analyzing snapshot…' : 'Use this view',
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
