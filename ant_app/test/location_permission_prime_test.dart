// Asking for location during onboarding — open_bugs item 50.
//
// Reported: "app should ask for location right away when asking for mic
// permission too."
//
// Nothing asked for it anywhere in onboarding. The microphone prompt appears
// on the very first screen, as a side effect of narrating and then listening;
// location was requested only by the dashboard map, on first build. So a user
// met a second unexplained system dialog minutes later on a screen about
// something else, and one who dismissed it had no route, no "where am I" and
// no caretaker tracking, with nothing said about why.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:ant_app/core/services/location_permission_primer.dart';

void main() {
  test('an undecided permission is asked for', () {
    return _run(
      current: LocationPermission.denied,
      answer: LocationPermission.whileInUse,
      expectAsked: true,
      expectGranted: true,
    );
  });

  test('a permission already granted is not asked for again', () {
    // The platform would refuse a second prompt anyway, and a user who has
    // already said yes should not be asked twice.
    return _run(
      current: LocationPermission.whileInUse,
      expectAsked: false,
      expectGranted: true,
    );
  });

  test('"always" counts as granted', () {
    return _run(
      current: LocationPermission.always,
      expectAsked: false,
      expectGranted: true,
    );
  });

  test('a permanent refusal is not re-prompted', () {
    // `deniedForever` is changed in system settings, not by another dialog.
    // Prompting again would do nothing and teach the user the app is broken.
    return _run(
      current: LocationPermission.deniedForever,
      expectAsked: false,
      expectGranted: false,
    );
  });

  test('saying no is reported, not treated as an error', () {
    return _run(
      current: LocationPermission.denied,
      answer: LocationPermission.denied,
      expectAsked: true,
      expectGranted: false,
    );
  });

  test('a channel that never answers does not hang onboarding', () async {
    // The trap this codebase has hit four times: `LocationSettings.timeLimit`
    // is enforced platform-side and does nothing when the channel itself is
    // unresponsive, so every Geolocator call needs a Dart-side timeout too.
    final primer = LocationPermissionPrimer(
      check: () => Completer<LocationPermission>().future,
      request: () async => LocationPermission.whileInUse,
      budget: const Duration(milliseconds: 50),
    );
    // Returns, rather than the test giving up on it. The distinction is the
    // whole point: a bound inside the primer means onboarding carries on,
    // where a pending future means it never does.
    expect(await primer.prime(), isFalse);
  });

  test('a throwing platform does not take onboarding down', () async {
    // A permission primer must never be the reason onboarding fails — the
    // map still asks for itself later.
    final primer = LocationPermissionPrimer(
      check: () async => throw Exception('no location provider on this device'),
      request: () async => LocationPermission.whileInUse,
    );
    expect(await primer.prime(), isFalse);
  });
}

Future<void> _run({
  required LocationPermission current,
  LocationPermission? answer,
  required bool expectAsked,
  required bool expectGranted,
}) async {
  var asked = 0;
  final primer = LocationPermissionPrimer(
    check: () async => current,
    request: () async {
      asked++;
      return answer ?? current;
    },
  );
  expect(await primer.prime(), expectGranted);
  expect(asked, expectAsked ? 1 : 0);
}
