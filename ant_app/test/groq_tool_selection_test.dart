// Which tools Qwen is allowed to reach for on a given turn.
//
// Groq's free tier meters *input tokens per window*, so the declarations are
// filtered per turn to stay under it — and that filter silently decides what
// the assistant is *capable* of, which is why it needs tests of its own.
//
// Measured on the serialised request body: all tools ~2,027 tokens, a fixed
// core of four ~383, a typical filtered turn 383-1,093.
//
// The first version was Latin-only. Measured against the 119 real utterances
// in `ant-diagnostics-*.txt`:
//
//     Bangla script   76 utterances   100% fell to a 3-tool fallback
//     Latin           43 utterances    48% fell to a 3-tool fallback
//
// Every Bangla utterance got `describe_current_location`, `alert_caretaker`
// and `trigger_emergency` and nothing else — so on this app's primary language
// the model could not route, change a setting, save a place or open the map.
// Not because it misunderstood: the tools were never offered.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/groq_assistant_service.dart';

void main() {
  _core();

  Set<String> toolsFor(String text) => GroqAssistantService.toolNamesFor(text);

  group('Bangla reaches the same tools Latin does', () {
    const cases = <String, String>{
      // Taken verbatim from the 16-17 Sep tester logs.
      'ইবনে সিনার রাস্তা দেখাও': 'request_route',
      'ম্যাপ টা বন্ধ করো': 'close_map',
      'লেখারো বরো করো': 'update_setting',
      'আমার বোনের নাম্বার টা আমাকে বলতো': 'add_emergency_contact',
      'বোনের ফোন নাম্বারটা সেভ করো': 'save_place',
      'আমি যেখানে আছি': 'describe_current_location',
      'অন্য একটা রাস্তা দেখাও': 'request_alternative_route',
      'বিপদজনক': 'open_hazard_report',
      'আমার খিদে পেয়েছে': 'request_route',
      'সবচেয়ে কাছের হাসপাতাল': 'request_route',
    };
    cases.forEach((said, wanted) {
      test('"$said" offers $wanted', () {
        expect(toolsFor(said), contains(wanted));
      });
    });

    test('none of them land on the old fallback set', () {
      // The specific shape of the old bug: every Bangla utterance came back
      // as exactly these three, whatever it asked for. Note the assertion is
      // *not* "more than three tools" — `লেখারো বরো করো` correctly returns
      // just `update_setting` and `trigger_emergency`, and a tight selection
      // is the whole point of filtering.
      const oldFallback = {
        'describe_current_location',
        'alert_caretaker',
        'trigger_emergency',
      };
      for (final said in cases.keys) {
        expect(toolsFor(said), isNot(oldFallback), reason: said);
      }
    });
  });

  group('Module 6 — look_around reaches the model', () {
    // The local matcher catches the common phrasings first and never calls
    // Groq at all. This group is the other half: everything phrased outside
    // that list has to still arrive at a model that *has* the tool, or the
    // camera is unreachable for anyone who does not use one of the handful
    // of sentences `LocalIntentMatcher._lookAround` knows.
    for (final said in [
      'can you check whether the pavement ahead is dug up',
      'tell me what that board over there says',
      'am i about to walk into anything',
      'সামনের ফুটপাতটা কি ভাঙা',
      'বাসটা কোথায় যাচ্ছে বলতে পারবে',
      'ম্যানহোল খোলা আছে কিনা দেখো',
      'রিকশা আসছে কি',
    ]) {
      test('"$said" offers look_around', () {
        expect(toolsFor(said), contains('look_around'));
      });
    }

    test('ordinary routing talk does not drag the camera in', () {
      // Over-inclusion costs input tokens on a budget measured at 7,000 per
      // minute and shared with the conversation — but a scan is also a camera
      // open and a cloud call, so a spurious offer here is dearer than most.
      expect(toolsFor('change the theme to dark'), isNot(contains('look_around')));
      expect(toolsFor('save this place as home'), isNot(contains('look_around')));
    });
  });

  group('the emergency tool is never filtered out', () {
    // It used to be keyword-gated, so an emergency phrased in a way the
    // keywords missed reached a model that had no way to act on it. The local
    // matcher catches most of these first — but this is the fallback, and a
    // filter is the wrong place to lose one.
    for (final said in [
      'বাঁচাও',
      'bachao',
      'sahajjo koro',
      'help me',
      'what is the weather like',
      'yes',
      '',
    ]) {
      test('"$said" still offers trigger_emergency', () {
        expect(toolsFor(said), contains('trigger_emergency'));
      });
    }
  });

  group('Latin matching is whole-word', () {
    // The substring version fired `go` inside "mango", `add` inside "address"
    // and `set` inside "sunset" — the trap this codebase documents three times
    // over ("no" in "know", "male" in "female", না in নারায়ণগঞ্জ).
    // Asserted on `cancel_route` rather than `request_route`: the latter is
    // in `_coreTools` and is present on every turn by design, so it cannot
    // show whether a keyword fired. `cancel_route` rides the same routing
    // group but is filtered normally.
    test('"mango" does not drag in routing', () {
      expect(toolsFor('change the theme'), isNot(contains('cancel_route')));
      expect(toolsFor('change the mango theme'), isNot(contains('cancel_route')),
          reason: '"go" inside "mango" must not count');
    });

    test('"sunset" does not count as "set"', () {
      expect(toolsFor('take me to the sunset point'), isNot(contains('update_setting')));
    });

    test('but the real words still match', () {
      expect(toolsFor('take me to Gulshan'), contains('request_route'));
      expect(toolsFor('save this place'), contains('save_place'));
      expect(toolsFor('change the theme'), contains('update_setting'));
    });
  });

  group('the filter still earns its keep', () {
    test('a focused request does not drag in every tool', () {
      // If it returned all 24 every time there would be no point to it.
      expect(toolsFor('change the theme to dark').length, lessThan(12));
    });

    test('an utterance with no verb still gets something usable', () {
      // A bare "yes", a name, an answer to a question the assistant asked.
      final bare = toolsFor('yes');
      expect(bare, contains('request_route'));
      expect(bare, contains('describe_current_location'));
    });
  });
}

// The cached core — see `_coreTools`.
//
// Dynamic tool filtering and Groq's prompt caching pull against each other:
// caching keys on a shared request prefix, and a filter that changes the tool
// array every turn changes that prefix every turn. Splitting the list into a
// fixed core plus a sorted tail lets both work.
void _core() {
  List<String> orderFor(String text) =>
      GroqAssistantService.toolOrderFor(text);

  test('the same four lead every request, in the same order', () {
    const core = ['trigger_emergency', 'request_route', 'describe_current_location', 'alert_caretaker'];
    for (final said in ['ইবনে সিনার রাস্তা দেখাও', 'change the theme', 'yes', 'বাঁচাও']) {
      expect(orderFor(said).take(4), core, reason: said);
    }
  });

  test('the tail is ordered, so the same choice serialises the same way', () {
    // An unordered Set would emit two different prefixes for two turns that
    // picked identical tools — a cache miss for no reason at all.
    final a = orderFor('show me the map');
    final b = orderFor('open the map please');
    expect(a.toSet(), b.toSet(), reason: 'same tools chosen');
    expect(a, b, reason: 'and therefore the same order');
  });

  test('no tool is sent twice', () {
    for (final said in ['বাঁচাও', 'take me to Gulshan', 'save this place']) {
      final order = orderFor(said);
      expect(order.toSet().length, order.length, reason: said);
    }
  });
}
