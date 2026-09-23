// Every item the 22 September field report named, pinned to a test.
//
// The report was "a lot of things that were said to be functional in previous
// builds no longer work in this field". Most of them turned out to be one
// cause with many faces — a keyword filter that decided which tools the model
// was even allowed to call — but each symptom gets its own assertion here, so
// a regression is reported in the user's words rather than as an internal
// invariant.

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/groq_assistant_service.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/place_categories.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('"telling it to turn of hey ant in bangla didnt work"', () {
    // `হেই` vs `হে` — one vowel sign, and the anchor list only had the
    // second. The user says the first.
    const offPhrasings = [
      'হেই অ্যান্ট বন্ধ করো',
      'হে অ্যান্ট বন্ধ করো',
      'হেই এন্ট বন্ধ করো',
      'হেই অ্যান্ট অফ করো',
      'ওয়েক ওয়ার্ড বন্ধ করো',
      'ওয়েকওয়ার্ড বন্ধ করো',
      'ভয়েস ট্রিগার বন্ধ করো',
      'হেই জার্ভিস বন্ধ করো',
    ];
    for (final said in offPhrasings) {
      test('"$said" turns it off', () {
        final intent = LocalIntentMatcher.match(said, AppLanguage.bangla);
        expect(intent?.name, 'update_setting', reason: said);
        expect(intent!.args['setting'], 'wake_word_enabled');
        expect(intent.args['value'], 'false');
      });
    }

    test('and it can still be turned back on', () {
      final intent = LocalIntentMatcher.match('হেই অ্যান্ট চালু করো', AppLanguage.bangla);
      expect(intent?.args['value'], 'true');
    });

    test('a question about it is not a command', () {
      // Both polarities present, or neither, must not be guessed at.
      final intent = LocalIntentMatcher.match(
          'wake word on or off?', AppLanguage.english);
      expect(intent?.name, isNot('update_setting'));
    });
  });

  group('"nearest bathroom, nearest restaurant ... didnt route me"', () {
    // These went to a *name* geocoder, which cannot answer "what kind of
    // place is near me". Now recognised as categories and searched by
    // proximity — see `place_categories.dart`.
    const wanted = <String, String>{
      'take me to the nearest bathroom': 'toilet',
      'nearest restaurant': 'restaurant',
      'I need a restroom': 'toilet',
      'find me somewhere to eat': 'restaurant',
      'nearest pharmacy': 'pharmacy',
      'কাছের টয়লেট': 'toilet',
      'সবচেয়ে কাছের হাসপাতাল': 'hospital',
    };
    wanted.forEach((said, id) {
      test('"$said" resolves by proximity, not by name', () {
        expect(categoryFor(said)?.id, id);
      });
    });

    test('a real place name still goes to the geocoder', () {
      expect(categoryFor('Gulshan 2'), isNull);
      expect(categoryFor('ধানমন্ডি'), isNull);
    });
  });

  group('"scene description ... didnt give answers"', () {
    // The camera tool was not even offered for these, and the vision prompt
    // was built from a six-value enum that could not express them.
    const visual = [
      'what colour is the rabbit',
      'what is written on this file',
      'what does this paper say',
      'describe what you see',
      'what is in front of me',
    ];
    for (final said in visual) {
      test('"$said" can reach the camera', () {
        expect(GroqAssistantService.toolNamesFor(said), contains('look_around'));
      });
    }
  });

  group('"saying that there is a manhole in front of me, does nothing"', () {
    for (final said in [
      'there is a manhole in front of me',
      'there is an open manhole here',
      'the sidewalk is blocked',
      'the footpath is broken',
    ]) {
      test('"$said" can be reported', () {
        expect(GroqAssistantService.toolNamesFor(said), contains('open_hazard_report'));
      });
    }
  });

  group('"remove emergency contact, remove location commands didnt work"', () {
    const wanted = <String, String>{
      'remove Rahim from my emergency contacts': 'remove_emergency_contact',
      'delete my sister from emergency contacts': 'remove_emergency_contact',
      'remove the school from my saved places': 'remove_place',
      'delete my school location': 'remove_place',
    };
    wanted.forEach((said, tool) {
      test('"$said" can reach $tool', () {
        expect(GroqAssistantService.toolNamesFor(said), contains(tool));
      });
    });
  });

  group('"forget about me remember about me was inconsistent"', () {
    test('both saving and forgetting are always reachable', () {
      // One declaration since the tool merge — `remember_about_me` carries a
      // `forget` flag — so the assertion is on the capability, not the name.
      for (final said in ['what do you know about me', 'forget the stairs thing', 'yes']) {
        expect(GroqAssistantService.toolNamesFor(said), contains('remember_about_me'));
      }
      final remember = GroqAssistantService.allTools
          .firstWhere((t) => t['function']['name'] == 'remember_about_me');
      expect((remember['function']['parameters']['properties'] as Map).keys, contains('forget'));
    });
  });

  group('"open map did not work" / "doesnt auto open map"', () {
    test('the map tool is always reachable', () {
      // `open_map`/`close_map` merged into `set_map(visible)`.
      for (final said in ['show me the map', 'ম্যাপ দেখাও', 'map on koro']) {
        expect(GroqAssistantService.toolNamesFor(said), contains('set_map'));
      }
    });
  });

  group('"general questions get a im a navigation assistant reply"', () {
    test('an ordinary question still carries the full toolset', () {
      // Nothing is filtered out, so the model has no structural reason to
      // decline. The rest is the system prompt, which now says so outright.
      final tools = GroqAssistantService.toolNamesFor('how are you');
      expect(tools, hasLength(GroqAssistantService.allTools.length));
    });
  });
}
