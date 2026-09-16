// Keeping the conversation across restarts — open_bugs item 52.
//
// Reported: "chat elements go away after closing app."
//
// `ChatState.messages` lived in memory and nothing wrote it anywhere. For a
// user who cannot see the screen the transcript is not decoration: it is the
// only record of what was agreed — which of three similarly-named places got
// picked, what the caretaker said, what the app claimed it had done. Losing it
// on every close leaves nothing to go back and check, and no way to show
// somebody else what happened.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:ant_app/features/dashboard/services/chat_history_store.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('ant-chat-test'));
  tearDown(() => dir.deleteSync(recursive: true));

  ChatHistoryStore store() => ChatHistoryStore(directory: dir);

  ChatMessage msg(String text, {ChatSender sender = ChatSender.user, int minute = 0}) =>
      ChatMessage(sender: sender, text: text, timestamp: DateTime.utc(2026, 9, 16, 10, minute));

  File file() => File('${dir.path}/${ChatHistoryStore.fileName}');

  test('the conversation survives the app being closed', () async {
    // The whole of item 52.
    final first = store();
    first.save('u1', [
      msg('take me to the clinic'),
      msg('Which one did you mean?', sender: ChatSender.assistant, minute: 1),
    ]);
    await first.flush();

    final restored = await store().load('u1');
    expect(restored, hasLength(2));
    expect(restored.first.text, 'take me to the clinic');
    expect(restored.last.sender, ChatSender.assistant);
  });

  test('who said what, and when, both come back', () async {
    // A transcript that cannot tell the user's words from the app's is not a
    // record of anything.
    final s = store();
    s.save('u1', [msg('I said this', minute: 5)]);
    await s.flush();

    final restored = await store().load('u1');
    expect(restored.single.sender, ChatSender.user);
    expect(restored.single.timestamp, DateTime.utc(2026, 9, 16, 10, 5));
  });

  test('another account cannot read it', () async {
    // A caretaker and the person they care for sharing a handset is ordinary
    // during testing, and a transcript surfacing under the wrong account
    // would be a real disclosure rather than a glitch.
    final s = store();
    s.save('u1', [msg('where is my sister')]);
    await s.flush();

    expect(await store().load('someone-else'), isEmpty);
    expect(await store().load('u1'), hasLength(1), reason: 'still there for its owner');
  });

  test('a burst in one turn is one write, and the last one wins', () async {
    // Coalesced per event-loop turn rather than behind a timer: a timer
    // batches more, and leaves a live one behind whenever the app closes
    // between the last message and the write — which is the exact moment
    // this feature exists for.
    final s = store();
    for (var i = 0; i < 20; i++) {
      s.save('u1', [for (var j = 0; j <= i; j++) msg('line $j')]);
    }
    await s.flush();
    expect(await store().load('u1'), hasLength(20));
  });

  test('a save with nothing after it still reaches disk', () async {
    // No explicit flush: the scheduled write has to happen on its own, or
    // every conversation loses its last message.
    store().save('u1', [msg('the last thing I said')]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((await store().load('u1')).single.text, 'the last thing I said');
  });

  test('it keeps the end of the conversation, not the beginning', () async {
    // The end is what somebody is going back to check.
    final s = store();
    s.save('u1', [
      for (var i = 0; i < ChatHistoryStore.maxMessages + 50; i++) msg('line $i'),
    ]);
    await s.flush();

    final restored = await store().load('u1');
    expect(restored, hasLength(ChatHistoryStore.maxMessages));
    expect(restored.last.text, 'line ${ChatHistoryStore.maxMessages + 49}');
    expect(restored.map((m) => m.text), isNot(contains('line 0')));
  });

  test('a corrupt file is not a crash', () async {
    // A partial write, or a file from an older shape of this model. A
    // transcript is a convenience; failing to read one must never stop the
    // dashboard from opening.
    file().writeAsStringSync('{"uid": "u1", "messages": [this is not json');
    expect(await store().load('u1'), isEmpty);
  });

  test('entries that make no sense are skipped, not fatal', () async {
    file().writeAsStringSync(jsonEncode({
      'uid': 'u1',
      'messages': [
        {'sender': 'user', 'text': 'this one is fine', 'timestamp': '2026-09-16T10:00:00.000Z'},
        {'sender': 'user'}, // no text, no timestamp
        {'sender': 'user', 'text': '', 'timestamp': '2026-09-16T10:00:00.000Z'},
        'not even an object',
      ],
    }));
    final restored = await store().load('u1');
    expect(restored, hasLength(1));
    expect(restored.single.text, 'this one is fine');
  });

  test('nothing stored yet is not an error', () async {
    expect(await store().load('u1'), isEmpty);
  });

  test('clearing removes it from the device', () async {
    final s = store();
    s.save('u1', [msg('something private')]);
    await s.flush();
    expect(file().existsSync(), isTrue);

    await s.clear();
    expect(file().existsSync(), isFalse);
    expect(await store().load('u1'), isEmpty);
  });

  test('the transcript is stored whole, not redacted', () async {
    // Deliberately unlike the diagnostics log, which redacts on the way in
    // because it is written to be *sent*. This one is read back by the person
    // who said it, on the phone they said it on — redacting it would destroy
    // the only thing it is for.
    final s = store();
    s.save('u1', [msg('take me to 12 Green Road')]);
    await s.flush();
    expect(file().readAsStringSync(), contains('12 Green Road'));
  });
}
