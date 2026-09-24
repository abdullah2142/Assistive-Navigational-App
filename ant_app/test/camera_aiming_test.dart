import 'package:ant_app/features/dashboard/screens/camera_aiming_screen.dart';
import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:flutter_test/flutter_test.dart';

/// The viewfinder is a deliberate, bounded exception to the Snapshot
/// Architecture's ban on a live camera. These pin the bounds.
void main() {
  group('an explicit camera request always offers a viewfinder', () {
    test('including for a user with no vision', () {
      expect(shouldOfferAiming(VisionLevel.none), isTrue);
    });

    test('low vision does', () {
      expect(shouldOfferAiming(VisionLevel.low), isTrue);
    });

    test('full vision does', () {
      expect(shouldOfferAiming(VisionLevel.full), isTrue);
    });
  });

  test('the viewfinder cannot be left open indefinitely', () {
    // The whole reason the Snapshot Architecture bans live video: a phone
    // with its camera open cooks itself and flattens its battery, which for
    // somebody who cannot see the indicator light is a failure they find out
    // about when the app they were relying on is dead.
    expect(CameraAimingScreen.maxAimingDuration, lessThanOrEqualTo(const Duration(minutes: 1)));
    expect(CameraAimingScreen.maxAimingDuration, greaterThan(const Duration(seconds: 10)),
        reason: 'long enough to line up a shot unhurried');
  });
}
