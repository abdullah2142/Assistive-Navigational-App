import 'package:ant_app/features/onboarding/models/disability_profile_enums.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'blind profiles enable depth scanning and keep the map closed by default',
    () {
      const profile = UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        visionLevel: VisionLevel.none,
      );

      expect(profile.visionLevel, VisionLevel.none);
      expect(profile.depthScanningEnabled, isTrue);
      expect(profile.autoOpenMapOnRoute, isFalse);
    },
  );

  test('both preferences round-trip and can be changed independently', () {
    const profile = UserProfile(
      uid: 'u1',
      role: UserRole.disabledUser,
      visionLevel: VisionLevel.none,
      depthScanningEnabled: false,
      autoOpenMapOnRoute: true,
    );

    final restored = UserProfile.fromJson(profile.toJson());
    expect(restored.depthScanningEnabled, isFalse);
    expect(restored.autoOpenMapOnRoute, isTrue);
    expect(
      restored.copyWith(depthScanningEnabled: true).depthScanningEnabled,
      isTrue,
    );
    expect(
      restored.copyWith(autoOpenMapOnRoute: false).autoOpenMapOnRoute,
      isFalse,
    );
  });

  test('older blind profiles receive the accessibility defaults', () {
    final restored = UserProfile.fromJson({
      'uid': 'u1',
      'role': 'disabledUser',
      'visionLevel': 'none',
    });

    expect(restored.depthScanningEnabled, isTrue);
    expect(restored.autoOpenMapOnRoute, isFalse);
  });
}
