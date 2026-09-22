import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import '../../config/vision_config.dart';

/// Owns the camera for the length of a snapshot and no longer.
///
/// ## The rule this class exists to enforce
///
/// `claude.md` and both plan documents ban live video outright: the
/// Snapshot Architecture is the answer to thermal throttling and battery
/// drain, and a `CameraController` left streaming is exactly the thing it
/// bans. So there is no preview stream, no image stream, and no long-lived
/// controller here — the sensor opens, a frame is taken, and it closes.
///
/// ## Why it does not close *instantly*
///
/// A cold camera open costs 300-600 ms on budget Android hardware, which is
/// a large share of the latency budget for "what bus is this" — and somebody
/// who asks that question usually asks a follow-up within seconds. So the
/// controller is kept for [VisionConfig.cameraWarmWindow] and then released.
///
/// The warm window is bounded in three independent ways, because a camera
/// left on by a bug is a hot phone and a flat battery for a user who cannot
/// see the indicator light:
///  * the timer above,
///  * [releaseNow], called when the app is backgrounded or the dashboard is
///    disposed,
///  * and the fact that nothing here ever *starts* the camera except an
///    explicit [capture].
/// ## A note on `UserProfile.snapshotConsent`
///
/// It does **not** gate this, and should not be wired to. That setting asks
/// "can your caretaker request a photo anytime?" — it is about somebody
/// *else* reaching for this user's camera, which is Module 8's Snapshot
/// Request, and `never` there means "my guardian may not take pictures
/// through my phone".
///
/// Module 6 is the opposite direction: the user asking their own phone what
/// is in front of them. Gating it on that preference would mean somebody who
/// declined remote surveillance also silently lost the ability to ask which
/// bus is pulling in, for a reason they were never told about and could not
/// connect to the answer they gave in onboarding.
class SnapshotCamera {
  SnapshotCamera({
    @visibleForTesting Future<List<CameraDescription>> Function()? listCameras,
    @visibleForTesting CameraController Function(CameraDescription)? buildController,
  })  : _listCameras = listCameras ?? availableCameras,
        _buildController = buildController ?? _defaultController;

  final Future<List<CameraDescription>> Function() _listCameras;
  final CameraController Function(CameraDescription) _buildController;

  static CameraController _defaultController(CameraDescription description) =>
      CameraController(
        description,
        // Medium, not max. The cloud tier is sent 320x240 regardless (see
        // `VisionConfig.uploadWidth` — token cost is flat across resolution,
        // so a larger capture buys nothing) and the edge detector downsamples
        // to 300x300. A high-resolution capture would cost encode time,
        // memory and heat to produce pixels that are immediately thrown away.
        ResolutionPreset.medium,
        enableAudio: false,
      );

  CameraController? _controller;
  Timer? _releaseTimer;
  Future<void>? _initialising;

  /// Guards two captures racing each other into initialisation — the chip and
  /// a voice command can both land within a frame of each other.
  bool _capturing = false;

  bool get isOpen => _controller?.value.isInitialized ?? false;

  /// Whether the device has a usable camera at all. Null until first checked.
  bool? _available;
  bool get isAvailable => _available ?? true;

  /// Takes [count] frames [gap] apart, returning JPEG bytes for each.
  ///
  /// Returns an empty list rather than throwing when the camera is
  /// unavailable or permission was refused — a scan that cannot happen is a
  /// spoken apology, not a crash, and every caller here is on a path a blind
  /// user triggered by voice.
  /// Takes [count] frames.
  ///
  /// [onBeforeFrame] is awaited before each capture, with the frame's index.
  /// That is what turns a burst into a *guided* sweep: the caller uses it to
  /// buzz, say "left", and wait for the user to actually get there.
  ///
  /// Capturing between cues rather than during a continuous pan is the whole
  /// point — a frame taken mid-movement is motion-blurred, and blur is
  /// exactly what was measured destroying Bangla sign reading. Three sharp
  /// frames at three angles beat three smeared ones.
  Future<List<Uint8List>> capture({
    int count = 1,
    Duration gap = VisionConfig.sweepFrameGap,
    Future<void> Function(int index)? onBeforeFrame,
  }) async {
    if (_capturing) {
      debugPrint('[SnapshotCamera] capture already in flight — ignoring');
      return const [];
    }
    _capturing = true;
    _releaseTimer?.cancel();
    try {
      if (!await _ensureOpen()) return const [];
      final controller = _controller;
      if (controller == null) return const [];

      final frames = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        if (onBeforeFrame != null) {
          await onBeforeFrame(i);
        } else if (i > 0) {
          // Unguided burst — the old behaviour, still used by anything that
          // wants frames without asking the user to move.
          await Future<void>.delayed(gap);
        }
        try {
          final file = await controller.takePicture();
          frames.add(await file.readAsBytes());
        } catch (e) {
          // One bad frame out of three is not a failed sweep. Only a sweep
          // that produced nothing at all is.
          debugPrint('[SnapshotCamera] frame ${i + 1}/$count failed: $e');
        }
      }
      debugPrint('[SnapshotCamera] captured ${frames.length}/$count frames');
      return frames;
    } finally {
      _capturing = false;
      _scheduleRelease();
    }
  }

  Future<bool> _ensureOpen() async {
    if (isOpen) return true;
    // A second caller arriving mid-initialisation waits for the first rather
    // than opening the sensor twice — which on Android fails outright with a
    // camera-in-use error and leaves both callers with nothing.
    final pending = _initialising;
    if (pending != null) {
      await pending;
      return isOpen;
    }

    final completer = Completer<void>();
    _initialising = completer.future;
    try {
      final cameras = await _listCameras();
      if (cameras.isEmpty) {
        _available = false;
        debugPrint('[SnapshotCamera] no cameras on this device');
        return false;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = _buildController(back);
      await controller.initialize();
      // Fixed focus would be wrong for a signboard several metres away and a
      // manhole at the user's feet in the same session, and a blind user
      // cannot tap to focus.
      await _bestEffort(() => controller.setFocusMode(FocusMode.auto));
      await _bestEffort(() => controller.setFlashMode(FlashMode.off));
      _controller = controller;
      _available = true;
      debugPrint('[SnapshotCamera] opened ${back.name}');
      return true;
    } catch (e) {
      // Includes the permission denial path: `initialize()` throws
      // `CameraAccessDenied` rather than returning a flag.
      debugPrint('[SnapshotCamera] could not open camera: $e');
      _available = false;
      _controller = null;
      return false;
    } finally {
      completer.complete();
      _initialising = null;
    }
  }

  /// Flash and focus modes are not supported on every device, and a
  /// `setFocusMode` that throws must not lose the camera that already opened
  /// successfully.
  Future<void> _bestEffort(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('[SnapshotCamera] optional camera setting refused: $e');
    }
  }

  void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(VisionConfig.cameraWarmWindow, () {
      debugPrint('[SnapshotCamera] warm window elapsed — releasing sensor');
      releaseNow();
    });
  }

  /// Closes the camera immediately.
  ///
  /// Call on app pause and on dashboard dispose. Android will take the camera
  /// away on backgrounding anyway, but it does so by invalidating the
  /// controller rather than cleaning it up — leaving a stale controller that
  /// throws on the next capture, which reads to the user as the scan feature
  /// having broken permanently.
  void releaseNow() {
    _releaseTimer?.cancel();
    _releaseTimer = null;
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    unawaited(controller.dispose().catchError((Object e) {
      debugPrint('[SnapshotCamera] dispose failed: $e');
    }));
  }

  void dispose() => releaseNow();
}
