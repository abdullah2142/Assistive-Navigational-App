import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three tool pairs were merged into single tools with an action argument, to
/// claw back input tokens. A merge is only safe if the action actually
/// routes — a `set_map` that always opens, or a `remember_about_me` that
/// always saves, is worse than the two tools it replaced, because it fails
/// silently and in the user's favour exactly half the time.
void main() {
  UserProfile user() => const UserProfile(
        uid: 'u1',
        role: UserRole.disabledUser,
        rememberedNotes: ['Cannot manage stairs'],
        passerbyHelperMessages: ['Please help me cross'],
      );

  Future<({SuggestedChipAction? overlay, UserProfile profile})> run(
    String name,
    Map<String, Object?> args,
  ) async {
    final applied = await FunctionCallExecutor().execute(
      name: name,
      args: args,
      profile: user(),
    );
    return (overlay: applied.overlayAction, profile: applied.updatedProfile ?? user());
  }

  group('set_map routes on its argument', () {
    test('visible true shows', () async {
      expect((await run('set_map', {'visible': 'true'})).overlay,
          SuggestedChipAction.showMap);
    });

    test('visible false hides', () async {
      expect((await run('set_map', {'visible': 'false'})).overlay,
          SuggestedChipAction.hideMap);
    });

    test('a real bool works as well as the string', () async {
      // Tool arguments arrive as whatever JSON the model emitted, and the two
      // backends do not agree on which.
      expect((await run('set_map', {'visible': false})).overlay,
          SuggestedChipAction.hideMap);
      expect((await run('set_map', {'visible': true})).overlay,
          SuggestedChipAction.showMap);
    });

    test('a missing argument shows rather than hides', () async {
      // Asking for the map and getting nothing is the failure that was
      // reported; asking to hide it and having it stay is merely untidy.
      expect((await run('set_map', const {})).overlay, SuggestedChipAction.showMap);
    });

    test('the old names still work', () async {
      // The local matcher and the suggested chips still emit them.
      expect((await run('open_map', const {})).overlay, SuggestedChipAction.showMap);
      expect((await run('close_map', const {})).overlay, SuggestedChipAction.hideMap);
    });
  });

  group('remember_about_me routes on forget', () {
    test('without the flag it saves', () async {
      final r = await run('remember_about_me', {'note': 'Prefers quiet routes'});
      expect(r.profile.rememberedNotes, contains('Prefers quiet routes'));
      expect(r.profile.rememberedNotes, contains('Cannot manage stairs'));
    });

    test('with forget true it removes, and removes the right one', () async {
      final r = await run('remember_about_me', {'note': 'stairs', 'forget': 'true'});
      expect(r.profile.rememberedNotes, isEmpty);
    });

    test('forget false still saves', () async {
      final r = await run('remember_about_me', {'note': 'Likes the park', 'forget': 'false'});
      expect(r.profile.rememberedNotes, contains('Likes the park'));
    });

    test('the old forget_about_me name still works', () async {
      final r = await run('forget_about_me', {'note': 'stairs'});
      expect(r.profile.rememberedNotes, isEmpty);
    });
  });

  group('passerby_message routes on remove', () {
    test('without the flag it adds', () async {
      final r = await run('passerby_message', {'message': 'I need a seat'});
      expect(r.profile.passerbyHelperMessages, contains('I need a seat'));
    });

    test('with remove true it removes', () async {
      final r = await run(
          'passerby_message', {'message': 'Please help me cross', 'remove': 'true'});
      expect(r.profile.passerbyHelperMessages, isEmpty);
    });

    test('the old names still work', () async {
      final added = await run('add_passerby_message', {'message': 'x'});
      expect(added.profile.passerbyHelperMessages, contains('x'));
      final removed =
          await run('remove_passerby_message', {'message': 'Please help me cross'});
      expect(removed.profile.passerbyHelperMessages, isEmpty);
    });
  });
}
