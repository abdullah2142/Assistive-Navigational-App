import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/vision/snapshot_camera.dart';
import '../../onboarding/models/disability_profile_enums.dart';

/// A viewfinder, for the people who can use one.
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
/// Not the blind user, and that is the point of it being a *screen* rather
/// than a step. Asked for as: the camera should open for aiming when the
/// button is tapped. A low-vision user can see roughly where the phone is
/// pointed, and a sighted companion helping somebody at a kerb can aim it
/// exactly — and neither had any way to tell whether the camera was facing a
/// signboard or the inside of a bag.
///
/// The paths that serve a blind user are untouched and still bypass this
/// entirely: holding Volume Up, and asking out loud. Both still run the
/// three-frame sweep with its spoken Left / Straight ahead / Right cues,
/// which is the aiming interface for somebody who cannot use this one.
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

class _CameraAimingScreenState extends ConsumerState<CameraAimingScreen> {
  late final SnapshotCamera _camera = ref.read(snapshotVisionServiceProvider).camera;

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

  /// Closes the viewfinder and asks the caller to take the shot.
  ///
  /// The scan itself is run by `ChatController` after this pops, not here:
  /// it owns the narration, the transcript entry and the cloud budget, and a
  /// second path into the vision tier would bypass all three.
  void _shoot() => Navigator.of(context).pop(true);

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
                        onPressed: _shoot,
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

/// Whether a viewfinder is worth offering at all.
///
/// A user with no usable vision gets the sweep straight away instead: a
/// preview they cannot see is a screen between them and the answer, and the
/// spoken Left / Straight ahead / Right cues are their aiming interface.
bool shouldOfferAiming(VisionLevel level) => level != VisionLevel.none;
