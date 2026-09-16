// The caretaker's half of "where are they" — open_bugs item 58.
//
// Reported as the first line of the round 3 report: "caretaker doesnt get
// location".
//
// Every other part of this had been built. The Overwatch map reads
// `liveLocations/{uid}`, `LiveLocation` parses it, and `firestore.rules` has
// allowed the user's own device to write it and their paired caretaker to
// read it since Module 2. What no one had noticed was that
// `AlertService.publishLocation` had exactly one caller — the emergency
// sequence — so the document only ever appeared once somebody had already
// triggered an SOS, and a caretaker checking on someone in the ordinary way
// saw nothing at all.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:ant_app/features/guardian/services/alert_service.dart';
import 'package:ant_app/features/guardian/services/live_location_publisher.dart';

void main() {
  test('an ordinary walk reaches the caretaker, with no emergency involved', () async {
    // The whole of item 58.
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
        .start(uid: 'u1', isPaired: true);
    await _settle();

    positions.add(_at(23.7461, 90.3742));
    await _settle();

    expect(alerts.published, hasLength(1));
    expect(alerts.published.single.uid, 'u1');
    expect(alerts.published.single.lat, 23.7461);
  });

  test('the first fix goes out immediately', () async {
    // A caretaker opening their app should see something current, not wait
    // out an interval before the first write.
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
        .start(uid: 'u1', isPaired: true);
    await _settle();

    positions.add(_at(23.7461, 90.3742));
    await _settle();
    expect(alerts.published, hasLength(1));
  });

  test('a burst of fixes is throttled to one write', () async {
    // An urban GPS wandering either side of the distance filter can produce
    // a fix every second or two, all day, for one user.
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
        .start(uid: 'u1', isPaired: true);
    await _settle();

    for (var i = 0; i < 20; i++) {
      positions.add(_at(23.7461 + i * 0.0001, 90.3742));
      await _settle();
    }
    expect(alerts.published, hasLength(1),
        reason: 'nineteen of those fell inside the minimum write interval');
  });

  test('nothing is published when no caretaker is paired', () async {
    // Nobody to read it, so writing a blind user's position to a server is a
    // privacy cost with nothing on the other side of it — the more so while
    // item 35 stands and unpairing does not exist.
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    final publisher =
        LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
          ..start(uid: 'u1', isPaired: false);
    await _settle();

    positions.add(_at(23.7461, 90.3742));
    await _settle();

    expect(publisher.isRunning, isFalse);
    expect(alerts.published, isEmpty);
  });

  test('stopping ends it — a closed app does not keep reporting', () async {
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    final publisher =
        LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
          ..start(uid: 'u1', isPaired: true);
    await _settle();
    publisher.stop();
    expect(publisher.isRunning, isFalse);

    positions.add(_at(23.7461, 90.3742));
    await _settle();
    expect(alerts.published, isEmpty);
  });

  test('a stream that errors does not take the session down', () async {
    // Losing the location stream must not be able to crash the dashboard of
    // someone who cannot see a crash dialog.
    final alerts = _RecordingAlerts();
    final positions = StreamController<Position>.broadcast();
    LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
        .start(uid: 'u1', isPaired: true);
    await _settle();

    positions.addError(Exception('location provider went away'));
    await _settle();
    positions.add(_at(23.7461, 90.3742));
    await _settle();

    expect(alerts.published, hasLength(1), reason: 'and it recovers afterwards');
  });

  test('a failed write does not retry on the very next fix', () async {
    // `publishLocation` swallows its own errors and reports false. Letting
    // the clock stand on a failure would hammer a backend already refusing.
    final alerts = _RecordingAlerts(succeed: false);
    final positions = StreamController<Position>.broadcast();
    LiveLocationPublisher(alerts: alerts, positionStream: () => positions.stream)
        .start(uid: 'u1', isPaired: true);
    await _settle();

    positions.add(_at(23.7461, 90.3742));
    await _settle();
    positions.add(_at(23.7500, 90.3742));
    await _settle();

    expect(alerts.published, hasLength(1));
  });

  test('starting twice for the same user does not open a second stream', () async {
    final alerts = _RecordingAlerts();
    var streamsOpened = 0;
    final positions = StreamController<Position>.broadcast();
    final publisher = LiveLocationPublisher(
      alerts: alerts,
      positionStream: () {
        streamsOpened++;
        return positions.stream;
      },
    );
    publisher.start(uid: 'u1', isPaired: true);
    publisher.start(uid: 'u1', isPaired: true);
    await _settle();
    expect(streamsOpened, 1);
  });
}

/// Waits for the stream event and the write behind it to finish.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

class _RecordingAlerts implements AlertService {
  _RecordingAlerts({this.succeed = true});

  final bool succeed;
  final published = <({String uid, double lat, double lng})>[];

  @override
  Future<bool> publishLocation({
    required String disabledUserUid,
    required double lat,
    required double lng,
  }) async {
    published.add((uid: disabledUserUid, lat: lat, lng: lng));
    return succeed;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Position _at(double lat, double lng) => Position(
      latitude: lat,
      longitude: lng,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 1.2,
      speedAccuracy: 0,
    );
