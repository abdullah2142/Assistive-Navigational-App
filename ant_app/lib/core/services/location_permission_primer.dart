import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Asks for location permission during onboarding, rather than leaving it
/// until the map needs it.
///
/// ## Why
///
/// Item 50: "app should ask for location right away when asking for mic
/// permission too."
///
/// Nothing asked for location anywhere in onboarding. The microphone prompt
/// appears on the very first screen, because narrating and then listening is
/// the first thing this app does, and `SpeechToText.initialize()` triggers it
/// as a side effect. Location was requested only by `DashboardMapPanel`, on
/// first build of the map — so a user met a second, unexplained system dialog
/// some minutes later, on a screen about something else entirely, and a user
/// who dismissed it had no route, no "where am I" and no caretaker tracking
/// with nothing to say why.
///
/// ## Why here and not on the first screen
///
/// Role selection is the earliest point at which this is known to be a
/// disabled user's device. A **caretaker's phone never needs its own
/// location** — the Overwatch map shows where the person they care for is,
/// which comes from that person's device. Asking a caretaker for a permission
/// nothing will ever use is a privacy cost for no benefit, so this is asked
/// one screen later than it could be in exchange for not asking half the
/// users at all.
///
/// ## Why it does not block
///
/// Onboarding must not stall behind a system dialog. The request is fired and
/// not waited on, exactly as the microphone's already is, so the next screen
/// narrates underneath it and the user answers when they get there. It cannot
/// throw and cannot hang: `Geolocator` calls need a Dart-side timeout as well
/// as the platform one, because `LocationSettings.timeLimit` is enforced
/// platform-side and does nothing when the channel itself is the thing not
/// answering.
class LocationPermissionPrimer {
  LocationPermissionPrimer({
    Future<LocationPermission> Function()? check,
    Future<LocationPermission> Function()? request,
    this.budget = const Duration(minutes: 2),
  })  : _check = check ?? Geolocator.checkPermission,
        _request = request ?? Geolocator.requestPermission;

  final Future<LocationPermission> Function() _check;
  final Future<LocationPermission> Function() _request;

  /// Generous by default: this is a human reading a dialog, not a network
  /// call. It is a bound on the channel never answering, not on the person.
  /// Injectable so a test can prove the bound exists without waiting it out.
  final Duration budget;

  /// Requests location permission if it has not already been decided.
  ///
  /// Returns whether the app ended up holding permission, which is for tests
  /// and logging — onboarding does not branch on it. A user who says no is
  /// not blocked from finishing; they are told later, by the feature that
  /// needed it, in words about that feature.
  Future<bool> prime() async {
    try {
      var permission = await _check().timeout(budget);
      // Already answered, either way. Asking again is something the platform
      // would refuse anyway, and `deniedForever` has to be changed in system
      // settings rather than by another prompt.
      if (permission == LocationPermission.denied) {
        debugPrint('[Permissions] asking for location during onboarding');
        permission = await _request().timeout(budget);
      }
      final granted = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
      debugPrint('[Permissions] location after onboarding prompt: $permission');
      return granted;
    } catch (e) {
      // A permission primer must never be the reason onboarding fails. The
      // map still asks for itself later.
      debugPrint('[Permissions] location prime failed (non-fatal): $e');
      return false;
    }
  }
}
