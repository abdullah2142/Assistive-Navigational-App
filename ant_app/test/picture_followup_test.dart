// Right after a camera scan, ordinary requests must not be answered as
// questions about the photo, and real questions about it must be.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/features/dashboard/providers/chat_providers.dart';

void main() {
  const about = [
    'what colour is the bus',
    'which bus is this',
    'is there a rickshaw on the left',
    'what does the sign say',
    'what is that',
    'read it to me',
    'what else is in the picture',
    'tell me more',
    'how many people are there',
    'ছবিতে কী আছে',
  ];
  const ordinary = [
    'what time is it',
    'where is the nearest bus stop',
    'take me to the bus station',
    'i need to turn left at the next road',
    'make the text bigger',
    'cancel that',
    'what can you do',
    'is it going to rain',
    'i am tired',
    'call my caretaker',
  ];
  for (final q in about) {
    test('about the photo: "$q"', () => expect(looksLikePictureFollowUp(q), isTrue));
  }
  for (final q in ordinary) {
    test('ordinary request: "$q"', () => expect(looksLikePictureFollowUp(q), isFalse));
  }
}
