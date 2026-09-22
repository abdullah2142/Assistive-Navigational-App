import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:image/image.dart' as img;

import '../../config/vision_config.dart';
import '../../localization/dashboard_strings.dart';
import '../../../features/onboarding/models/disability_profile_enums.dart';
import '../../../features/onboarding/models/user_profile.dart';
import '../emergency_channel.dart';
import '../haptics_service.dart';
import '../route_safety_service.dart';
import 'ambient_scan_policy.dart';
import 'depth_dropoff_detector.dart';
import 'edge_hazard_detector.dart';
import 'snapshot_camera.dart';
import 'vision_detection.dart';

/// Looks around on its own, so a blind user does not have to ask.
///
/// ## What it is
///
/// A periodic, **edge-only** hazard check: open the camera, take one frame,
/// run the on-device detector, and speak only if something is genuinely in
/// the way. It never reaches the cloud — no tokens, no data, no radio — which
/// is what makes running it for a whole walk affordable.
///
/// This is `claude.md`'s Snapshot Architecture used as written: the rule bans
/// *video* and in the same sentence prescribes "taking periodic high-res
/// photos for edge processing". An earlier draft of this module cut periodic
/// capture on battery grounds, which read the rule backwards.
///
/// ## What it deliberately cannot do
///
/// It cannot read a sign, name a rickshaw, or spot an open manhole. Those are
/// cloud questions — COCO has no class for any of them — and asking them
/// every thirty seconds would spend the conversation's token budget and the
/// user's data plan on a street that is usually empty. The ambient tier
/// answers one question, *is something large and close*, and hands everything
/// else to a scan the user asks for.
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
    DepthDropoffDetector? depth,
    AmbientScanPolicy? policy,
    EmergencyChannel? battery,
    Stream<Position>? positionStream,
    DateTime Function()? now,
    // ignore_for_file: prefer_initializing_formals
  })  : _camera = camera,
        _edge = edge,
        _haptics = haptics,
        _depth = depth ?? DepthDropoffDetector(),
        _policy = policy ?? AmbientScanPolicy(),
        _battery = battery ?? EmergencyChannel(),
        _injectedStream = positionStream,
        _now = now ?? DateTime.now;

  final SnapshotCamera _camera;
  final EdgeHazardDetector _edge;
  final HapticsService _haptics;

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

  StreamSubscription<Position>? _positionSub;
  Timer? _tick;
  Position? _lastScanPosition;
  Position? _current;
  bool _scanning = false;
  UserProfile? _profile;

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
      debugPrint('[Ambient] not enabled for visionLevel=${profile.visionLevel.name}');
      return;
    }
    if (isRunning) return;

    _policy.reset();
    _positionSub ??= (_injectedStream ??
            Geolocator.getPositionStream(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: 5,
              ),
            ))
        .listen((p) {
      _current = p;
      // Re-evaluated on every fix rather than once per route: the whole point
      // is to raise the pace *as the user approaches* something, and a route
      // is planned once while the walking takes twenty minutes.
      _refreshProximity();
    }, onError: (Object e) {
      debugPrint('[Ambient] position stream error: $e');
    });

    // A short tick against a long interval, on purpose. The policy owns the
    // pacing and can change it between ticks — speeding up near a hazard,
    // backing off on a quiet street — and a timer set to the interval itself
    // could not react until the interval it was already committed to elapsed.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) => _maybeScan());
    debugPrint('[Ambient] started (${_policy.currentInterval.inSeconds}s pace)');
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
    debugPrint('[Ambient] ${value ? 'alert' : 'normal'} pace '
        '(${_policy.currentInterval.inSeconds}s)');
  }

  Future<void> _maybeScan() async {
    final profile = _profile;
    if (profile == null || _scanning) return;

    final here = _current;
    final moved = (here == null || _lastScanPosition == null)
        ? double.infinity
        : Geolocator.distanceBetween(
            _lastScanPosition!.latitude,
            _lastScanPosition!.longitude,
            here.latitude,
            here.longitude,
          );

    final decision = _policy.decide(
      enabled: true,
      now: _now(),
      metersMoved: moved,
      batteryPercent: await _cachedBatteryPercent(),
    );
    if (decision != AmbientDecision.scan) return;

    _scanning = true;
    try {
      await _scanOnce(profile);
      _lastScanPosition = here;
    } finally {
      _scanning = false;
    }
  }

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
    final frames = await _camera.capture(count: 1);
    if (frames.isEmpty) return;
    final frame = img.decodeJpg(frames.first);
    if (frame == null) return;

    if (!await _edge.ensureLoaded()) return;
    final verdict = await _edge.detect(frame);
    _policy.recordScan(_now(), verdict);

    final d = Dashboard.of(profile.language);

    // Ground first, and that ordering is the point. A vehicle is a collision
    // the user may hear coming; a missing pavement is a fall they cannot.
    // When both are true in one frame, the ground is what gets said.
    if (await _depth.ensureLoaded()) {
      final ground = await _depth.detect(frame);
      if (ground.isDangerous) {
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

    if (verdict.level != HazardLevel.imminent) {
      // Deliberately silent on `caution`. An ambient tier that narrates every
      // parked car becomes noise the user learns to ignore, and it is talking
      // over the traffic they are actually navigating by. Only a reason to
      // stop walking earns an interruption.
      return;
    }

    await _haptics.play(HapticCue.hazard);
    final line = d.visionHazardAbort(d.visionObjectLabel(verdict.nearest?.label));
    debugPrint('[Ambient] imminent ${verdict.nearest?.label} '
        'score=${verdict.threatScore.toStringAsFixed(2)}');
    if (!_announcements.isClosed) _announcements.add(line);
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
    debugPrint('[Ambient] route context: $located/${hazards.length} hazards '
        'with a position, ${crossings.length} crossings');
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
        Geolocator.distanceBetween(here.latitude, here.longitude, lat, lng) <= radius;

    final nearHazard = _hazards.any((h) =>
        h.hasPosition && near(h.lat!, h.lng!, VisionConfig.hazardApproachMeters));
    final nearCrossing = _crossings
        .any((c) => near(c.latitude, c.longitude, VisionConfig.crossingApproachMeters));

    alert = nearHazard || nearCrossing;
  }

  void dispose() {
    stop();
    _depth.dispose();
    unawaited(_announcements.close());
  }
}
