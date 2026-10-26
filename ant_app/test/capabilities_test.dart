// The app never told anyone what it could do, or that the Magic Button
// exists. Asking "what can you do" now gets the whole list, including the
// Magic Button, without a network.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/localization/onboarding_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';

void main() {
  const asks = {
    AppLanguage.english: [
      'What can you do?',
      'what can I say',
      'how do I use this app',
      'tell me what you can do',
      'what is the Magic Button',
      'where is the magic button',
      'how do I call for help',
    ],
    AppLanguage.bangla: [
      'তুমি কী করতে পারো',
      'কীভাবে ব্যবহার করব',
      'ম্যাজিক বাটন কী',
      'tumi ki ki korte paro',
      'magic button ki',
    ],
  };

  for (final entry in asks.entries) {
    for (final phrase in entry.value) {
      test('[${entry.key.name}] "$phrase" lists the capabilities', () {
        expect(
          LocalIntentMatcher.match(phrase, entry.key)?.name,
          'describe_capabilities',
        );
      });
    }
  }

  test('neighbouring requests are not swallowed', () {
    expect(LocalIntentMatcher.match('what can you see', AppLanguage.english)?.name,
        isNot('describe_capabilities'));
    expect(LocalIntentMatcher.match('where am i', AppLanguage.english)?.name,
        'describe_current_location');
    expect(LocalIntentMatcher.match('help', AppLanguage.english)?.name,
        isNot('describe_capabilities'));
    expect(LocalIntentMatcher.match('somebody help me', AppLanguage.english)?.name,
        isNot('describe_capabilities'));
  });

  for (final language in AppLanguage.values) {
    test('[${language.name}] the overview explains the Magic Button', () {
      final text = Dashboard.of(language).capabilitiesOverview;
      final bn = language == AppLanguage.bangla;
      expect(text, contains(bn ? 'ম্যাজিক বাটন' : 'Magic Button'));
      expect(text, contains(bn ? 'ভলিউম ডাউন' : 'Volume Down'));
      expect(text, contains(bn ? 'তিন সেকেন্ড' : 'three seconds'));
    });

    test('[${language.name}] the setup tour teaches the Magic Button', () {
      final groups = Onboarding.of(language).commandTourGroups;
      final bn = language == AppLanguage.bangla;
      expect(
        groups.any((g) => (g.note ?? '').contains(bn ? 'ম্যাজিক বাটন' : 'Magic Button')),
        isTrue,
      );
    });
  }
}
