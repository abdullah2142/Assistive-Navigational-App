import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:image/image.dart' as img;

import '../../config/vision_config.dart';
import '../../localization/app_language.dart';
import '../../localization/dashboard_strings.dart';
import '../../../features/onboarding/models/disability_profile_enums.dart';
import '../../../features/onboarding/models/user_profile.dart';
import '../emergency_channel.dart';
import '../haptics_service.dart';
import '../route_safety_service.dart';
import 'ambient_scan_policy.dart';
import 'depth_dropoff_detector.dart';
import 'edge_hazard_detector.dart';
import 'vision_backend.dart';
import 'snapshot_camera.dart';
import 'vision_detection.dart';
import 'vision_scene.dart';

/// Looks around on its own, so a blind user does not have to ask.
///
/// ## What it is
///
/// A periodic, one-frame hazard check: try Gemini Flash-Lite first, then use
/// on-device SSD and optional depth inference if the online check is
/// unavailable. The frame is never added to chat.
///
/// This is `claude.md`'s Snapshot Architecture used as written: the rule bans
/// *video* and in the same sentence prescribes "taking periodic high-res
/// photos for edge processing". An earlier draft of this module cut periodic
/// capture on battery grounds, which read the rule backwards.
///
/// ## What it deliberately cannot do
///
/// The offline detector cannot read a sign, identify a rickshaw or detect an
/// open manhole. The online pass looks for a broader set of navigation
/// challenges, while the local SSD and optional depth model remain available
/// when the network or Gemini quota is unavailable. Explicit scans still
/// handle detailed questions such as sign reading and object identification.
///
/// ## What stops it
///
/// Four independent things, because a camera left running is a hot phone and
/// a flat battery for somebody who cannot see either happening:
///  * the user is not blind or low-vision, or has it switched off;
///  * the phone has not moved since the last look;
///  * the battery is under [VisionConfig.ambientMinBatteryPercent];
///  * the app is backgrounded, or the dashboard was disposed.
class AmbientHazardScanner {
  AmbientHazardScanner({
    required SnapshotCamera camera,
    required EdgeHazardDetector edge,
    required HapticsService haptics,
    VisionBackend? onlineVision,
    ValueNotifier<bool>? sharedScanBusy,
    DepthDropoffDetector? depth,
    AmbientScanPolicy? policy,
    EmergencyChannel? battery,
    Stream<Position>? positionStream,
    DateTime Function()? now,
    bool Function()? shouldDeferScan,
    // ignore_for_file: prefer_initializing_formals
  }) : _camera = camera,
       _edge = edge,
       _haptics = haptics,
       _onlineVision = onlineVision,
       _sharedScanBusy = sharedScanBusy,
       _depth = depth ?? DepthDropoffDetector(),
       _policy = policy ?? AmbientScanPolicy(),
       _battery = battery ?? EmergencyChannel(),
       _injectedStream = positionStream,
       _shouldDeferScan = shouldDeferScan ?? _neverDefer,
       _now = now ?? DateTime.now;

  final SnapshotCamera _camera;
  final EdgeHazardDetector _edge;
  final HapticsService _haptics;
  final VisionBackend? _onlineVision;
  final ValueNotifier<bool>? _sharedScanBusy;

  /// Reads whether the ground keeps going — the one hazard class the object
  /// detector structurally cannot see, and the one that causes a fall rather
  /// than a bump.
  final DepthDropoffDetector _depth;
  final AmbientScanPolicy _policy;

  /// Battery percentage comes from the Magic Button's existing native bridge
  /// rather than a new plugin — it already exposes exactly this, for exactly
  /// the reason it matters here.
  final EmergencyChannel _battery;

  final Stream<Position>? _injectedStream;
  final DateTime Function() _now;
  final bool Function() _shouldDeferScan;
  static bool _neverDefer() => false;

  StreamSubscription<Position>? _positionSub;
  Timer? _tick;
  Position? _lastScanPosition;
  Position? _current;
  bool _scanning = false;
  UserProfile? _profile;
  final Map<String, DateTime> _recentCloudAnnouncements = {};
  static const Duration _cloudAnnouncementCooldown = Duration(minutes: 2);

  /// Emits a sentence whenever something is worth saying out loud.
  ///
  /// A stream rather than a callback so the dashboard can route it through
  /// the same narration path every other spoken line uses — which is what
  /// keeps it from talking over turn-by-turn guidance.
  final _announcements = StreamController<String>.broadcast();
  Stream<String> get announcements => _announcements.stream;

  bool get isRunning => _tick != null;

  /// Battery percentage is re-read periodically, not per scan: it is a
  /// platform channel round trip and the number does not move in 30 seconds.
  int? _batteryPercent;
  DateTime? _batteryReadAt;
  static const Duration _batteryFreshness = Duration(minutes: 5);

  /// Whether this profile should get ambient scanning at all.
  ///
  /// Blind and low-vision only, per the feature's whole purpose. A sighted
  /// caretaker running the same build gets nothing, and neither does a user
  /// whose difficulty is mobility or hearing — the camera would cost them
  /// battery to answer a question they can answer by looking.
  static bool appliesTo(UserProfile profile) =>
      profile.visionLevel == VisionLevel.none ||
      profile.visionLevel == VisionLevel.low;

  /// Starts watching. Safe to call repeatedly.
  Future<void> start(UserProfile profile) async {
    _profile = profile;
    if (!appliesTo(profile)) {
      debugPrint(
        '[Ambient] not enabled for visionLevel=${profile.visionLevel.name}',
      );
      return;
    }
    if (isRunning) return;

    _policy.reset();
    _positionSub ??=
        (_injectedStream ??
                Geolocator.getPositionStream(
                  locationSettings: const LocationSettings(
                    accuracy: LocationAccuracy.high,
                    distanceFilter: 5,
                  ),
                ))
            .listen(
              (p) {
                _current = p;
                // Re-evaluated on every fix rather than once per route: the whole point
                // is to raise the pace *as the user approaches* something, and a route
                // is planned once while the walking takes twenty minutes.
                _refreshProximity();
              },
              onError: (Object e) {
                debugPrint('[Ambient] position stream error: $e');
              },
            );

    // A short tick against a long interval, on purpose. The policy owns the
    // pacing and can change it between ticks — speeding up near a hazard,
    // backing off on a quiet street — and a timer set to the interval itself
    // could not react until the interval it was already committed to elapsed.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _maybeScan());
    debugPrint(
      '[Ambient] started (${_policy.currentInterval.inSeconds}s pace)',
    );
  }

  /// Stops, and releases the camera.
  void stop() {
    _tick?.cancel();
    _tick = null;
    unawaited(_positionSub?.cancel());
    _positionSub = null;
    _camera.releaseNow();
    debugPrint('[Ambient] stopped');
  }

  /// Tells the scanner it is near something the map already flagged.
  ///
  /// Called by the navigation layer when a reported hazard or a crossing is
  /// within range. Raises the pace; does not itself force a scan, because the
  /// policy still owns whether one is due.
  set alert(bool value) {
    if (_policy.alert == value) return;
    _policy.alert = value;
    debugPrint(
      '[Ambient] ${value ? 'alert' : 'normal'} pace '
      '(${_policy.currentInterval.inSeconds}s)',
    );
  }

  Future<void> _maybeScan() async {
    final profile = _profile;
    if (profile == null || _scanning) return;
    // Ambient work yields to an explicit scan or any active conversation.
    // It will be reconsidered on the next timer tick, without losing the
    // user's foreground operation or reserving the shared camera.
    if (_shouldDeferScan()) return;

    final here = _current;
    final moved = (here == null || _lastScanPosition == null)
        ? double.infinity
        : Geolocator.distanceBetween(
            _lastScanPosition!.latitude,
            _lastScanPosition!.longitude,
            here.latitude,
            here.longitude,
          );

    final battery = await _cachedBatteryPercent();
    final decision = _policy.decide(
      enabled: true,
      now: _now(),
      metersMoved: moved,
      batteryPercent: battery,
    );

    // Say it, once, when the cover goes away.
    //
    // Path-watching has always stopped below `ambientMinBatteryPercent` and
    // has always done it in silence, which is the worst way to withdraw a
    // safety feature from somebody who cannot see that it is gone: they keep
    // walking as though the ground is still being checked. Latched so it is
    // said once per discharge rather than every thirty seconds — a warning
    // on a timer is one the user turns the app off to escape — and re-armed
    // only once the battery has genuinely recovered, not on a reading that
    // jitters across the threshold.
    if (decision == AmbientDecision.batteryLow) {
      if (!_announcedBatteryLow) {
        _announcedBatteryLow = true;
        final d = Dashboard.of(profile.language);
        debugPrint('[Ambient] stopping — battery ${battery ?? -1}%');
        if (!_announcements.isClosed) {
          _announcements.add(d.batteryLowScanningStopped(battery ?? 0));
        }
      }
      return;
    }
    if (_announcedBatteryLow &&
        battery != null &&
        battery >= _policy.minBatteryPercent + _batteryRecoveryMargin) {
      _announcedBatteryLow = false;
      final d = Dashboard.of(profile.language);
      debugPrint('[Ambient] resuming — battery $battery%');
      if (!_announcements.isClosed) {
        _announcements.add(d.batteryRecoveredScanningResumed);
      }
    }

    if (decision != AmbientDecision.scan) return;
    // Recheck after the awaited battery read; an explicit snapshot may have
    // started while that platform call was pending.
    if (_shouldDeferScan() || (_sharedScanBusy?.value ?? false)) return;

    _scanning = true;
    try {
      await _scanOnce(profile);
      _lastScanPosition = here;
    } finally {
      _scanning = false;
    }
  }

  /// Latched so the low-battery warning is said once, not every scan.
  bool _announcedBatteryLow = false;

  /// How far above the cut-off the battery must climb before the warning
  /// re-arms. Without it a reading hovering on the threshold announces
  /// itself repeatedly, which is the noise the latch exists to prevent.
  static const int _batteryRecoveryMargin = 5;

  Future<int?> _cachedBatteryPercent() async {
    final read = _batteryReadAt;
    if (read != null && _now().difference(read) < _batteryFreshness) {
      return _batteryPercent;
    }
    _batteryReadAt = _now();
    _batteryPercent = await _battery.batteryPercent();
    return _batteryPercent;
  }

  Future<void> _scanOnce(UserProfile profile) async {
    // Logged on every scan, not only when something is found.
    //
    // Nothing here said anything on the normal path, and the tier is
    // deliberately silent below "stop walking" — so a working scanner and a
    // dead one produced identical logs and identical silence. Asked directly
    // on 23 September: "I don't know whether the depth model or the ambient
    // scanner is working". It was working; there was simply no way to tell.
    final scanClock = Stopwatch()..start();
    List<Uint8List> frames;
    if (_sharedScanBusy != null) _sharedScanBusy!.value = true;
    try {
      frames = await _camera.capture(count: 1);
    } finally {
      if (_sharedScanBusy != null) _sharedScanBusy!.value = false;
    }
    if (frames.isEmpty) {
      debugPrint('[Ambient] scan aborted — no frame');
      return;
    }
    final frame = img.decodeJpg(frames.first);
    if (frame == null) return;

    final cloud = _onlineVision;
    if (cloud != null && cloud.isConfigured) {
      try {
        final jpeg = _encodeAmbientFrame(frame);
        final scene = await cloud.describe(
          jpegs: [jpeg],
          focus: ScanFocus.hazard,
          language: profile.language,
          question: _ambientQuestion,
        );
        if (scene != null) {
          final hasFindings = scene.hazards.isNotEmpty;
          _policy.recordScan(
            _now(),
            HazardVerdict(
              level: hasFindings ? HazardLevel.caution : HazardLevel.clear,
              detections: const [],
            ),
          );
          debugPrint(
            '[Ambient] ${cloud.name} ${jpeg.length} bytes '
            '(${VisionConfig.uploadWidth}x${VisionConfig.uploadHeight} cap), '
            'findings=${scene.hazards.length}',
          );
          if (hasFindings) await _announceCloudFindings(scene);
          return;
        }
      } catch (e) {
        debugPrint('[Ambient] ${cloud.name} unavailable; using offline scan: $e');
      }
    }

    debugPrint('[Ambient] cloud unavailable; falling back to offline detectors');

    final edgeReady = await _edge.ensureLoaded();
    final verdict = edgeReady ? await _edge.detect(frame) : HazardVerdict.empty;

    final d = Dashboard.of(profile.language);

    // The local depth pass supplements SSD when the online check is down. A
    // missing pavement is a fall hazard the object detector cannot see.
    if (profile.depthScanningEnabled && await _depth.ensureLoaded()) {
      final ground = await _depth.detect(frame);
      if (ground.isDangerous) {
        _policy.recordScan(
          _now(),
          const HazardVerdict(level: HazardLevel.caution, detections: []),
        );
        await _haptics.play(HapticCue.hazard);
        if (!_announcements.isClosed) {
          _announcements.add(d.visionGroundDrops(ground.paces));
        }
        return;
      }
      // `risesUp` and `unreadable` both stay silent here. A step up is worth
      // knowing and not worth interrupting a walk for, and an unreadable
      // frame is worth nothing at all — saying something about it would turn
      // "I could not see" into a noise the user has to interpret.
    }

    _policy.recordScan(
      _now(),
      edgeReady
          ? verdict
          : const HazardVerdict(level: HazardLevel.caution, detections: []),
    );

    if (verdict.level != HazardLevel.imminent) {
      // Deliberately silent on `caution`. An ambient tier that narrates every
      // parked car becomes noise the user learns to ignore, and it is talking
      // over the traffic they are actually navigating by. Only a reason to
      // stop walking earns an interruption. Silent to the *user*; the log
      // still records that the scan happened and what it saw.
      debugPrint(
        '[Ambient] scan ${scanClock.elapsedMilliseconds}ms '
        'level=${verdict.level.name} '
        'score=${verdict.threatScore.toStringAsFixed(2)} '
        'nearest=${verdict.nearest?.label ?? '-'} (silent)',
      );
      return;
    }

    await _haptics.play(HapticCue.hazard);
    final line = d.visionHazardAbort(
      d.visionObjectLabel(verdict.nearest?.label),
    );
    debugPrint(
      '[Ambient] imminent ${verdict.nearest?.label} '
      'score=${verdict.threatScore.toStringAsFixed(2)}',
    );
    if (!_announcements.isClosed) _announcements.add(line);
  }

  static const String _ambientQuestion = '''
This is one forward-facing photo from a blind pedestrian's phone during a walk. Check what is visible ahead and relevant to navigating safely: obstacles or blocked pavement; vehicles or crowds in the walking path; open drains, manholes, construction, broken pavement, flooding or slippery ground; sidewalk edges, kerbs, crossings and platform edges; changes in ground level; stairs up or down; ramps; escalators and their direction; tactile paving; and visible lift/elevator doors or entrances. Distinguish something directly in the path from something merely nearby or to the side. Do not guess distance, depth, direction of travel, hidden hazards, or whether a lift works. Put each clearly visible obstacle or access feature in the hazards array, with a brief description and severity from 1 (note) to 3 (urgent). If there is no clearly visible issue or useful access feature, return an empty hazards array and say nothing actionable is visible. Do not claim the route is safe based on one frame.''';

  /// Uses the same bounded sweep upload dimensions and JPEG quality as the
  /// explicit sweep path, preserving the captured aspect ratio and avoiding
  /// upscaling.
  Uint8List _encodeAmbientFrame(img.Image frame) {
    final scale = <double>[
      VisionConfig.uploadWidth / frame.width,
      VisionConfig.uploadHeight / frame.height,
      1,
    ].reduce((a, b) => a < b ? a : b);
    final resized = img.copyResize(
      frame,
      width: (frame.width * scale).round().clamp(1, VisionConfig.uploadWidth),
      height: (frame.height * scale).round().clamp(1, VisionConfig.uploadHeight),
      interpolation: img.Interpolation.average,
    );
    return Uint8List.fromList(
      img.encodeJpg(resized, quality: VisionConfig.uploadJpegQuality),
    );
  }

  Future<void> _announceCloudFindings(VisionScene scene) async {
    final findings = scene.hazards;
    final text = scene.spoken.trim();
    if (findings.isEmpty || text.isEmpty) return;
    final key = findings
        .map((h) => h.kind == 'other'
            ? '${h.kind}:${h.description.toLowerCase()}'
            : h.kind)
        .toSet()
        .join('|');
    final now = _now();
    _recentCloudAnnouncements.removeWhere(
      (_, at) => now.difference(at) >= _cloudAnnouncementCooldown,
    );
    final last = _recentCloudAnnouncements[key];
    if (last != null && now.difference(last) < _cloudAnnouncementCooldown) {
      debugPrint('[Ambient] repeated cloud finding suppressed');
      return;
    }
    _recentCloudAnnouncements[key] = now;
    if (findings.any((h) => h.severity >= 3)) {
      await _haptics.play(HapticCue.hazard);
    }
    if (!_announcements.isClosed) _announcements.add(text);
  }

  List<RouteHazard> _hazards = const [];
  List<LatLng> _crossings = const [];

  /// Gives the scanner the things on this journey worth looking harder at.
  ///
  /// Called once when a route is planned. Both lists come straight off the
  /// route: [hazards] are the crowdsourced and crime pins the safety function
  /// already found on it, and [crossings] are the `ManeuverKind.crossing`
  /// steps the router itself produced.
  ///
  /// Pass empty lists when a journey ends, or the last route's hazards keep
  /// raising the pace on a street the user is no longer walking.
  void setRouteContext({
    List<RouteHazard> hazards = const [],
    List<LatLng> crossings = const [],
  }) {
    _hazards = hazards;
    _crossings = crossings;
    final located = hazards.where((h) => h.hasPosition).length;
    debugPrint(
      '[Ambient] route context: $located/${hazards.length} hazards '
      'with a position, ${crossings.length} crossings',
    );
    _refreshProximity();
  }

  /// Raises the pace when the user is near something the map already flagged.
  ///
  /// Hazards without a position are skipped rather than guessed at — see
  /// [RouteHazard.lat] for why some lack one.
  void _refreshProximity() {
    final here = _current;
    if (here == null) return;
    if (_hazards.isEmpty && _crossings.isEmpty) {
      alert = false;
      return;
    }

    bool near(double lat, double lng, double radius) =>
        Geolocator.distanceBetween(here.latitude, here.longitude, lat, lng) <=
        radius;

    final nearHazard = _hazards.any(
      (h) =>
          h.hasPosition &&
          near(h.lat!, h.lng!, VisionConfig.hazardApproachMeters),
    );
    final nearCrossing = _crossings.any(
      (c) => near(c.latitude, c.longitude, VisionConfig.crossingApproachMeters),
    );

    alert = nearHazard || nearCrossing;
  }

  void dispose() {
    stop();
    _depth.dispose();
    unawaited(_announcements.close());
  }
}
