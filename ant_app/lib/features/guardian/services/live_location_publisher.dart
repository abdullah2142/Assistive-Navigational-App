import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'alert_service.dart';

/// Publishes the user's position to `liveLocations/{uid}` while the app is
/// open, so their caretaker can see where they are.
///
/// ## Why this exists
///
/// Item 58, and the first line of the round 3 report: "caretaker doesnt get
/// location".
///
/// Everything else was already in place and had been for some time — the
/// Overwatch map reads this document, `LiveLocation` parses it,
/// `firestore.rules` lets the user's own device write it and lets their
/// paired caretaker read it. The only thing missing was anything that ever
/// wrote it. `AlertService.publishLocation` had exactly one caller, in the
/// emergency sequence, so a caretaker could see where someone was *after*
/// they had triggered an SOS and at no other time. Which is the one moment
/// it is already too late to be useful as reassurance.
///
/// ## What this is not
///
/// Not the background isolate Module 8 describes. This publishes while the
/// app is in the foreground and stops when it is not, which is an honest
/// half of the feature rather than a pretend whole one: a caretaker sees a
/// position with a timestamp on it, and a stale timestamp reads as stale
/// rather than as a lie. Genuine background tracking is a separate piece of
/// work with its own battery, permission and consent questions.
///
/// ## What it costs
///
/// Two throttles, both needed. [_minDistanceMeters] keeps a phone sitting on
/// a table from writing anything at all, and [_minWriteInterval] bounds what
/// a fast walk with a jittery fix can spend — without it, an urban GPS
/// wandering either side of the distance filter can produce a write every
/// second or two, all day, for one user.
class LiveLocationPublisher {
  LiveLocationPublisher({
    AlertService? alerts,
    Stream<Position> Function()? positionStream,
  })  : _injectedAlerts = alerts,
        _positionStream = positionStream ?? _defaultPositionStream;

  final AlertService? _injectedAlerts;

  /// Built on first use, not in the constructor.
  ///
  /// `AlertService`'s default reaches for `FirebaseFirestore.instance`, which
  /// throws outright when no Firebase app has been initialized — so an eager
  /// field makes this unconstructible in a widget test, and the dashboard
  /// creates one the moment it is built. Same reason `FunctionCallExecutor`
  /// defers its own services.
  late final AlertService _alerts = _injectedAlerts ?? AlertService();

  final Stream<Position> Function() _positionStream;

  /// Far enough that ordinary GPS wander does not count as movement, close
  /// enough to still say which road somebody is on.
  static const int _minDistanceMeters = 25;

  /// A floor on how often a write can happen regardless of movement.
  static const Duration _minWriteInterval = Duration(seconds: 30);

  static Stream<Position> _defaultPositionStream() => Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: _minDistanceMeters,
        ),
      );

  StreamSubscription<Position>? _sub;
  DateTime? _lastWriteAt;
  String? _uid;

  bool get isRunning => _sub != null;

  /// Begins publishing for [uid].
  ///
  /// Does nothing when [isPaired] is false. There is nobody to read the
  /// document, and writing a blind user's position to a server that no one
  /// is watching is a privacy cost with no benefit attached — the more so
  /// while item 35 stands and unpairing does not exist.
  void start({required String uid, required bool isPaired}) {
    if (!isPaired) {
      debugPrint('[LiveLocation] not publishing — no caretaker is paired');
      return;
    }
    if (_sub != null && _uid == uid) return;
    stop();
    _uid = uid;
    // Reset rather than carry over: the first fix after starting should go
    // out immediately, so a caretaker opening their app sees something
    // current rather than waiting out an interval inherited from earlier.
    _lastWriteAt = null;
    debugPrint('[LiveLocation] publishing for $uid');
    _sub = _positionStream().listen(
      _onPosition,
      onError: (Object e) => debugPrint('[LiveLocation] position stream: $e'),
    );
  }

  void stop() {
    if (_sub == null) return;
    debugPrint('[LiveLocation] stopped publishing');
    _sub?.cancel();
    _sub = null;
    _uid = null;
  }

  Future<void> _onPosition(Position position) async {
    final uid = _uid;
    if (uid == null) return;
    final now = DateTime.now();
    final last = _lastWriteAt;
    if (last != null && now.difference(last) < _minWriteInterval) return;
    // Set before awaiting, not after. A slow write must not let the next
    // position through behind it and turn the throttle into no throttle.
    _lastWriteAt = now;
    final ok = await _alerts.publishLocation(
      disabledUserUid: uid,
      lat: position.latitude,
      lng: position.longitude,
    );
    // Publishing is best-effort — `publishLocation` swallows its own errors
    // and reports false. Letting the clock stand on a failure would retry on
    // the very next fix and hammer a backend that is already refusing.
    if (!ok) debugPrint('[LiveLocation] publish failed (will retry on the next interval)');
  }
}
