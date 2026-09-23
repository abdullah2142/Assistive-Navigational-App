import 'package:ant_app/features/dashboard/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backlog item: an AI message should be replyable, so the chat knows which
/// one is meant. Without it "that one" and "the second place you said"
/// resolve to whatever the model infers from five turns of history — a
/// guess, and a wrong guess routes somebody to the wrong place.
void main() {
  ChatMessage user(String text, {String? replyTo}) => ChatMessage(
        sender: ChatSender.user,
        text: text,
        timestamp: DateTime(2026, 9, 23),
        replyToText: replyTo,
      );

  test('a message carries what it was replying to', () {
    final m = user('that one', replyTo: 'I found three cafes nearby.');
    expect(m.replyToText, 'I found three cafes nearby.');
  });

  test('an ordinary message carries nothing', () {
    expect(user('take me home').replyToText, isNull);
  });

  test('the quote is the text, not an id', () {
    // Carried as the sentence because that is what has to reach the model
    // anyway: it reads a transcript, not a database, so the sentence itself
    // is the only reference it can act on.
    final m = user('the second one', replyTo: 'Lab Aid or Popular?');
    expect(m.replyToText, isA<String>());
    expect(m.replyToText, contains('Lab Aid'));
  });

  test('replying does not change what the user actually said', () {
    // The quote is context for the model; the command is still the user's
    // own words, and everything downstream — the intent matcher, the
    // clarification handlers — sees only those.
    final m = user('yes', replyTo: 'Shall I save this as work?');
    expect(m.text, 'yes');
  });

  test('an empty quote is treated as no quote', () {
    expect(user('hello', replyTo: '')?.replyToText, '');
  });
}
