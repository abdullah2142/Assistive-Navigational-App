import 'package:ant_app/core/services/voice_memo_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('send and stop utterances finish and send the memo', () {
    for (final phrase in ['send', 'send it', 'stop', 'stop recording']) {
      expect(voiceMemoCommand(phrase), VoiceMemoCommand.send, reason: phrase);
    }
  });

  test('cancel utterances discard the memo', () {
    for (final phrase in ['cancel', 'cancel it', 'cancel recording']) {
      expect(voiceMemoCommand(phrase), VoiceMemoCommand.cancel, reason: phrase);
    }
  });

  test('ordinary content is not mistaken for a control', () {
    expect(voiceMemoCommand('Please send the groceries tomorrow'), isNull);
    expect(voiceMemoCommand('stop by the pharmacy'), isNull);
  });

  test('Bangla send and cancel utterances are supported', () {
    expect(voiceMemoCommand('পাঠাও'), VoiceMemoCommand.send);
    expect(voiceMemoCommand('বাতিল করো'), VoiceMemoCommand.cancel);
  });
}
