import 'package:ant_app/features/guardian/models/communication_message.dart';
import 'package:flutter_test/flutter_test.dart';

/// Backlog item 6 — voluntary image sending, both directions. Deliberately
/// distinct from the snapshot reply: that is the camera answering a request
/// on the user's behalf and is governed by their snapshot-consent setting;
/// this is a person choosing to show somebody something.
void main() {
  group('the message model carries a picture either way', () {
    test('a photo is its own type, not a snapshot reply', () {
      // Conflating them would make the snapshot-consent setting govern
      // ordinary photo sharing, which is not what the user agreed to when
      // they set it.
      expect(CommunicationType.photo, isNot(CommunicationType.snapshotReply));
      expect(CommunicationType.values, contains(CommunicationType.photo));
    });

    test('it round-trips through Firestore json', () {
      final m = CommunicationMessage.fromJson('id1', {
        'fromUid': 'c1',
        'toUid': 'u1',
        'type': 'photo',
        'text': 'the bus stop',
        'imageBase64': 'AAAA',
      });
      expect(m.type, CommunicationType.photo);
      expect(m.imageBase64, 'AAAA');
      expect(m.text, 'the bus stop');
    });

    test('an unknown type degrades to a memo rather than throwing', () {
      // A guardian on an older build must not crash a newer user's app.
      final m = CommunicationMessage.fromJson('id2', {
        'fromUid': 'c1',
        'toUid': 'u1',
        'type': 'something_from_the_future',
        'text': 'hello',
      });
      expect(m.type, CommunicationType.memo);
    });

    test('a photo with no image is still a readable message', () {
      // The description is sent even when the frame is missing — "they sent
      // a photo I could not make out" is still news.
      final m = CommunicationMessage.fromJson('id3', {
        'fromUid': 'u1',
        'toUid': 'c1',
        'type': 'photo',
        'text': 'could not see',
      });
      expect(m.imageBase64, isNull);
      expect(m.text, isNotEmpty);
    });
  });

  test('every type is handled somewhere — the switch is exhaustive', () {
    // `ChatController.receiveCaretakerMessage` switches without a default,
    // so adding a type here is a compile error until it is handled. This
    // asserts the set is what that switch was written against.
    expect(CommunicationType.values.map((t) => t.name).toSet(), {
      'memo',
      'voiceMemo',
      'snapshotRequest',
      'snapshotReply',
      'photo',
    });
  });
}
