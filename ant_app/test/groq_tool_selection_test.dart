// What Qwen is allowed to reach for on a given turn.
//
// This file used to test a **keyword filter** that chose a subset of tools
// per turn, to stay under Groq's input-token window. That filter is gone, and
// these tests now exist largely to stop it coming back.
//
// ## Why it was removed
//
// It decided what the assistant was *capable* of from a hand-written list of
// trigger words, and no such list can enumerate how people talk. It was
// patched twice for exactly that — the first version was Latin-only and
// dropped 100% of Bangla utterances to a three-tool fallback — and the
// 22 September device log shows the same failure again in new clothes:
//
//     tools=4   68 times   the single most common value in the session
//
// Measured straight off that log, by replaying the utterances through the
// filter:
//
//   "what colour is the rabbit"        4 tools, no look_around
//   "what is written on this file"     4 tools, no look_around
//   "what do you know about me"        4 tools, no remember/forget_about_me
//   "there is a manhole in front of me" 5 tools, no open_hazard_report
//   "হেই অ্যান্ট বন্ধ করো"              11 tools, no update_setting
//
// Every one of those is a user asking for something the app can do, and being
// told it cannot — which is the "worked in previous builds, no longer works"
// cluster in the report.
//
// ## Why sending all of them is also cheaper
//
// Groq bills the per-minute window on *uncached* prefix tokens. Tool
// declarations render into the head of the prompt, so a tool list that varies
// with the user's wording changes the prefix every turn and nothing behind it
// can be cached. Across 208 token lines in that session, every single one
// reads `cached=0`. A constant list makes the ~2,400-token head cacheable.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/groq_assistant_service.dart';

void main() {
  Set<String> toolsFor(String text) => GroqAssistantService.toolNamesFor(text);
  List<String> orderFor(String text) => GroqAssistantService.toolOrderFor(text);

  group('every tool is offered on every turn', () {
    // Taken verbatim from the 16-17 Sep and 22 Sep tester logs.
    const utterances = <String>[
      'ইবনে সিনার রাস্তা দেখাও',
      'ম্যাপ টা বন্ধ করো',
      'লেখারো বরো করো',
      'আমার বোনের নাম্বার টা আমাকে বলতো',
      'আমি যেখানে আছি',
      'বিপদজনক',
      'সবচেয়ে কাছের হাসপাতাল',
      'হেই অ্যান্ট বন্ধ করো',
      'what colour is the rabbit',
      'what is written on this file',
      'what do you know about me',
      'there is a manhole in front of me',
      'the sidewalk is blocked',
      'how are you',
      'yes',
      '',
    ];

    final total = GroqAssistantService.allTools.length;

    for (final said in utterances) {
      test('"$said" gets all $total', () {
        expect(toolsFor(said), hasLength(total));
      });
    }
  });

  group('the specific starvations from the 22 September log', () {
    // Each of these named a capability the user asked for and did not get.
    // Asserted individually rather than as "all tools" so a future change
    // that reintroduces filtering fails with the name of what it broke.
    const needed = <String, String>{
      'what colour is the rabbit': 'look_around',
      'what is written on this file': 'look_around',
      'what does this paper say': 'look_around',
      'what do you know about me': 'remember_about_me',
      'forget about the stairs thing': 'forget_about_me',
      'there is a manhole in front of me': 'open_hazard_report',
      'the sidewalk is blocked': 'open_hazard_report',
      'হেই অ্যান্ট বন্ধ করো': 'update_setting',
      'ওয়েক ওয়ার্ড বন্ধ করো': 'update_setting',
      'remove Rahim from my emergency contacts': 'remove_emergency_contact',
      'remove the school from my saved places': 'remove_place',
      'show me the map': 'open_map',
      'take me to the nearest bathroom': 'request_route',
    };

    needed.forEach((said, tool) {
      test('"$said" can still reach $tool', () {
        expect(toolsFor(said), contains(tool));
      });
    });
  });

  group('the prefix is stable, which is what makes it cacheable', () {
    test('two different turns serialise the tools identically', () {
      // The whole token argument rests on this. If the order or the content
      // differs between turns, the prefix differs, and `cached=0` comes back.
      final a = orderFor('show me the map');
      final b = orderFor('একদম অন্য কথা');
      expect(a, b);
    });

    test('an empty turn is the same as a full one', () {
      expect(orderFor(''), orderFor('take me to Gulshan'));
    });

    test('no tool is sent twice', () {
      final order = orderFor('বাঁচাও');
      expect(order.toSet().length, order.length);
    });
  });

  group('the emergency tools are present, as they always had to be', () {
    // These were the reason a fixed core existed at all: an emergency
    // phrased outside the keyword list used to reach a model that had no way
    // to act on it. Now nothing can be outside the list.
    for (final said in ['বাঁচাও', 'sahajjo', 'help me', 'I am scared', 'কিছু একটা']) {
      test('"$said" can trigger an emergency', () {
        expect(toolsFor(said), contains('trigger_emergency'));
        expect(toolsFor(said), contains('alert_caretaker'));
      });
    }
  });
}
