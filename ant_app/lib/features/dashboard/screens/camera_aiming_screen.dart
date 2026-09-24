import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/vision/snapshot_camera.dart';
import '../../onboarding/models/disability_profile_enums.dart';

/// A short viewfinder for a user-requested camera capture.
///
/// ## Why this does not break the "no live video" rule
///
/// `SnapshotCamera`'s doc comment bans a long-lived streaming controller,
/// and it is right to: the Snapshot Architecture exists because a phone with
/// its camera open cooks itself and flattens its battery, which for somebody
/// who cannot see the indicator light is a failure they discover when the
/// app they were relying on is dead.
///
/// The rule that matters is *bounded*, not *never*. This preview lives only
/// while this screen is on top, is capped by [maxAimingDuration], and is
/// released in `dispose` whichever way the screen is left. Nothing here
/// survives a back press. `SnapshotCamera.open()` and its `controller`
/// getter were already written for "an explicit aiming session" — the
/// affordance was anticipated; only the screen was missing.
///
/// ## Who it is for
///
/// Any user who explicitly opens the camera can aim and capture the frame
/// that will be analyzed. Volume Up remains an immediate one-frame action,
/// and a spoken surroundings request remains a guided multi-frame sweep.
class CameraAimingScreen extends ConsumerStatefulWidget {
  const CameraAimingScreen({super.key, required this.language});

  final AppLanguage language;

  /// The hard cap on a viewfinder nobody closed.
  ///
  /// A user who opens this and puts the phone in a pocket must not leave a
  /// sensor streaming until the battery is gone. Generous enough to line up
  /// a shot unhurried, short enough that forgetting costs nothing.
  static const Duration maxAimingDuration = Duration(seconds: 45);

  @override
  ConsumerState<CameraAimingScreen> createState() => _CameraAimingScreenState();
}

/// Explicit camera requests offer the viewfinder regardless of vision level.
bool shouldOfferAiming(VisionLevel _) => true;

class _CameraAimingScreenState extends ConsumerState<CameraAimingScreen> {
  late final SnapshotCamera _camera = ref
      .read(snapshotVisionServiceProvider)
      .camera;

  bool _opening = true;
  bool _failed = false;
  Timer? _deadline;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _deadline = Timer(CameraAimingScreen.maxAimingDuration, () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _deadline?.cancel();
    // Whichever way the screen was left — shutter, back button, or the
    // deadline above. The camera is never this screen's to keep.
    _camera.releaseNow();
    super.dispose();
  }

  Future<void> _open() async {
    final ok = await _camera.open();
    if (!mounted) return;
    setState(() {
      _opening = false;
      _failed = !ok;
    });
  }

  /// Captures the exact frame shown in the viewfinder and returns it to the
  /// controller for the normal analysis/transcript path.
  Future<void> _shoot() async {
    final controller = _camera.controller;
    if (controller == null || !controller.value.isInitialized) {
      Navigator.of(context).pop<Uint8List>();
      return;
    }
    try {
      final photo = await controller.takePicture();
      final bytes = await photo.readAsBytes();
      if (mounted) Navigator.of(context).pop<Uint8List>(bytes);
    } catch (e) {
      debugPrint('[CameraAim] shutter failed: $e');
      if (mounted) Navigator.of(context).pop<Uint8List>();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.language);
    final controller = _camera.controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(d.cameraAimingTitle)),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: switch ((_opening, _failed, controller)) {
                (true, _, _) => const CircularProgressIndicator(),
                (_, true, _) || (_, _, null) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    d.visionNoCamera,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                _ => AspectRatio(
                  aspectRatio: controller!.value.aspectRatio,
                  child: CameraPreview(controller),
                ),
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Text(
                    d.cameraAimingHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Semantics(
                    button: true,
                    label: d.cameraAimingShoot,
                    child: SizedBox(
                      height: 64,
                      width: double.infinity,
                      child: FilledButton.icon(
                        // Enabled even when the preview failed. A blind user
                        // who opened this by accident should still be able
                        // to take the picture the button promises — the scan
                        // does not need the viewfinder, only this screen
                        // does.
                        onPressed: _opening || _failed ? null : _shoot,
                        icon: const Icon(Icons.camera_alt_rounded, size: 28),
                        label: Text(d.cameraAimingShoot),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
