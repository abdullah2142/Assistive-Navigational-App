// A model's own look_around / plan_commute / send_photo / replay calls were
// dropped by FunctionCallExecutor.execute(), so the camera never opened.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  final profile = UserProfile(uid: 'u', role: UserRole.disabledUser, pairedUserId: 'c');

  test('look_around carries its focus and question into the turn', () async {
    final turn = await FunctionCallExecutor().execute(
      name: 'look_around',
      args: {'focus': 'vehicle', 'question': 'which bus is this'},
      profile: profile,
    );
    expect(turn.scanFocus, ScanFocus.vehicle);
    expect(turn.scanQuestion, 'which bus is this');
  });

  test('plan_commute and send_photo_to_caretaker are not dropped', () async {
    final ex = FunctionCallExecutor();
    final commute = await ex.execute(
      name: 'plan_commute', args: {'destination': 'Gulshan'}, profile: profile);
    expect(commute.commuteDestination, 'Gulshan');
    final photo = await ex.execute(
      name: 'send_photo_to_caretaker', args: const {}, profile: profile);
    expect(photo.sendsPhotoToCaretaker, isTrue);
  });
}
