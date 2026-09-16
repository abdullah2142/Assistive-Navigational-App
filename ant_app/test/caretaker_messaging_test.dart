// Sending to the caretaker, in the user's own words — the other direction of
// Module 8.
//
// Requested directly: "user should have a feature to send text or voice memos
// back to caretaker."
//
// Most of the plumbing was already there and pointing the wrong way.
// `CommunicationService._send` has always taken `fromUid` and `toUid`;
// `firestore.rules` has always allowed `request.auth.uid == disabledUserUid`
// to create one; and the caretaker's hub already draws a received message
// with a different arrow from a sent one and can play a voice memo. The only
// missing piece was any way for the user to say one — every caller passed the
// caretaker as the sender.
//
// The two halves are deliberately split. A written memo needs free text
// pulled out of an arbitrary sentence, which `LocalIntentMatcher` refuses to
// do on principle — a wrong local guess there does not fail visibly, it sends
// somebody's caretaker half a sentence — so Gemini extracts it. A voice memo
// has no text to extract, because the message has not been spoken yet, so it
// is safe to match locally and reaches the recorder without a round trip.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/function_call_executor.dart';
import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_planning_service.dart';
import 'package:ant_app/features/dashboard/models/suggested_chip.dart';
import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:ant_app/features/guardian/services/communication_service.dart';
import 'package:ant_app/features/onboarding/models/user_profile.dart';
import 'package:ant_app/features/onboarding/models/user_role.dart';

void main() {
  group('a written message', () {
    test('the model has something to call, with the words to put in it', () {
      final send = GeminiAssistantService.functionDeclarations
          .firstWhere((f) => f.name == 'send_caretaker_message');
      expect(send.description, contains('own words'));
    });

    test('goes to the caretaker, from the user', () async {
      // Every existing caller passed the caretaker as `fromUid`. This is the
      // first thing that sends in the other direction.
      final comms = _RecordingComms();
      await _executor(comms).execute(
        name: 'send_caretaker_message',
        args: const {'message': "I'll be home late"},
        profile: _paired,
        location: null,
      );
      expect(comms.memos, hasLength(1));
      expect(comms.memos.single.text, "I'll be home late");
      expect(comms.memos.single.from, 'u1');
      expect(comms.memos.single.to, 'caretaker-1');
    });

    test('is read back verbatim', () async {
      // A blind user cannot check what was sent on their behalf against a
      // screen, and this app mis-transcribes often enough (items 46, 54) that
      // hearing it is the only chance to catch it.
      final turn = await _executor(_RecordingComms()).execute(
        name: 'send_caretaker_message',
        args: const {'message': 'I got to the clinic safely'},
        profile: _paired,
        location: null,
      );
      expect(turn.responseText, contains('I got to the clinic safely'));
    });

    test('an empty message is not sent — it is asked about', () async {
      // An empty memo landing on a caretaker's phone is worse than no memo.
      final comms = _RecordingComms();
      final turn = await _executor(comms).execute(
        name: 'send_caretaker_message',
        args: const {'message': '   '},
        profile: _paired,
        location: null,
      );
      expect(comms.memos, isEmpty);
      expect(turn.responseText, contains('tell them'));
    });

    test('with nobody paired it says how to pair', () async {
      final comms = _RecordingComms();
      final turn = await _executor(comms).execute(
        name: 'send_caretaker_message',
        args: const {'message': 'on my way'},
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        location: null,
      );
      expect(comms.memos, isEmpty);
      expect(turn.responseText, contains('pair with my caretaker'));
    });

    test('a failed send points at the Magic Button', () async {
      final turn = await _executor(_RecordingComms(throws: true)).execute(
        name: 'send_caretaker_message',
        args: const {'message': 'on my way'},
        profile: _paired,
        location: null,
      );
      expect(turn.responseText, contains('Magic Button'));
    });

    test('a message with content is left to Gemini, not eaten locally', () async {
      // The regression this guards is subtle and silent: "tell my caretaker"
      // is in item 57's alert vocabulary, so without a bound on how much may
      // follow it, this sentence raises a flag and drops every word the user
      // actually wanted passed on.
      final intent = LocalIntentMatcher.match(
          'tell my caretaker I will be home late tonight', AppLanguage.english);
      expect(intent, isNull,
          reason: 'the message text is Gemini\'s to extract — see the class comment');
    });

    test('a bare request to alert them is still handled locally', () async {
      expect(LocalIntentMatcher.match('alert my caretaker', AppLanguage.english)?.name,
          'alert_caretaker');
      expect(LocalIntentMatcher.match('let my caretaker know', AppLanguage.english)?.name,
          'alert_caretaker');
    });
  });

  group('a voice message', () {
    test('the model has something to call', () {
      final names = GeminiAssistantService.functionDeclarations.map((f) => f.name);
      expect(names, contains('record_caretaker_voice_memo'));
    });

    for (final phrase in [
      'send a voice message to my caretaker',
      'record a message for my carer',
      'i want to send a voice note',
      'let them hear me say it',
    ]) {
      test('"$phrase" is matched locally', () {
        // Safe to match locally in a way the written memo is not: there is no
        // free text in the sentence, because the message has not been spoken
        // yet — the recorder is what collects it.
        expect(LocalIntentMatcher.match(phrase, AppLanguage.english)?.name,
            'record_caretaker_voice_memo');
      });
    }

    for (final phrase in ['ভয়েস বার্তা পাঠাও', 'record kore pathao']) {
      test('"$phrase" is matched too — item 54', () {
        expect(LocalIntentMatcher.match(phrase, AppLanguage.bangla)?.name,
            'record_caretaker_voice_memo');
      });
    }

    test('it opens the recorder rather than replying', () async {
      // The audio does not exist yet at the point the call is made, so the
      // executor can only hand back the overlay that collects it.
      final turn = await _executor(_RecordingComms()).execute(
        name: 'record_caretaker_voice_memo',
        args: const {},
        profile: _paired,
        location: null,
      );
      expect(turn.overlayAction, SuggestedChipAction.sendCaretakerVoiceMemo);
    });

    test('and says nothing, so it does not talk over the recorder', () async {
      // The overlay speaks the moment it opens. A confirmation here would
      // land underneath its own narration — and recording under narration is
      // item 23 all over again.
      final turn = await _executor(_RecordingComms()).execute(
        name: 'record_caretaker_voice_memo',
        args: const {},
        profile: _paired,
        location: null,
      );
      expect(turn.responseText, isEmpty);
    });

    test('with nobody paired the recorder never opens', () async {
      // Recording twenty seconds of somebody's voice and then discovering
      // there is nowhere to send it is the wrong order to find that out in.
      final turn = await _executor(_RecordingComms()).execute(
        name: 'record_caretaker_voice_memo',
        args: const {},
        profile: UserProfile(uid: 'u1', role: UserRole.disabledUser),
        location: null,
      );
      expect(turn.overlayAction, isNull);
      expect(turn.responseText, contains('pair with my caretaker'));
    });
  });

  group('the two directions stay distinguishable', () {
    test('a message from the user is not an emergency', () async {
      final turn = await _executor(_RecordingComms()).execute(
        name: 'send_caretaker_message',
        args: const {'message': 'running late'},
        profile: _paired,
        location: null,
      );
      expect(turn.triggersEmergency, isFalse);
      expect(turn.updatedProfile, isNull);
    });

    test('an emergency that mentions a voice note is still an emergency', () {
      final intent = LocalIntentMatcher.match(
          'help me i have fallen record a message', AppLanguage.english);
      expect(intent?.name, 'trigger_emergency');
    });
  });
}

final _paired = UserProfile(
  uid: 'u1',
  role: UserRole.disabledUser,
  pairedUserId: 'caretaker-1',
);

FunctionCallExecutor _executor(CommunicationService comms) =>
    FunctionCallExecutor(routePlanning: _NoPlanning(), communicationService: comms);

class _NoPlanning implements RoutePlanningService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecordingComms implements CommunicationService {
  _RecordingComms({this.throws = false});

  final bool throws;
  final memos = <({String from, String to, String text})>[];
  final voiceMemos = <({String from, String to, int seconds})>[];

  @override
  Future<void> sendMemo({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required String text,
  }) async {
    if (throws) throw Exception('offline');
    memos.add((from: fromUid, to: toUid, text: text));
  }

  @override
  Future<void> sendVoiceMemo({
    required String disabledUserUid,
    required String fromUid,
    required String toUid,
    required String audioBase64,
    required int durationSeconds,
  }) async {
    if (throws) throw Exception('offline');
    voiceMemos.add((from: fromUid, to: toUid, seconds: durationSeconds));
  }

  @override
  Stream<List<CommunicationMessage>> watchMessages(String disabledUserUid) =>
      const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
