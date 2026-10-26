// Regression coverage for behaviours verified while probing area intent_local
// (voice command understanding: local intent matcher, Banglish, STT garble).
// Offline and deterministic: no network, no keys. Every assertion here passed
// against the code as it stood when the probe was written; the bugs found are
// in probe_bugs/intent_local_bugs_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/offline_intent_matcher.dart';
import 'package:ant_app/core/services/place_categories.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:ant_app/core/services/saved_place_matcher.dart';
import 'package:ant_app/core/services/voice_cancel_window.dart';
import 'package:ant_app/core/services/voice_matching.dart';
import 'package:ant_app/core/services/voice_memo_command.dart';
import 'package:ant_app/core/utils/spoken_text.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';
import 'package:ant_app/features/onboarding/widgets/spoken_digits.dart';

LocalIntent? en(String t, {String? recent}) =>
    LocalIntentMatcher.match(t, AppLanguage.english, recentSetting: recent);
LocalIntent? bn(String t) => LocalIntentMatcher.match(t, AppLanguage.bangla);

void main() {
  group('emergency: reassurance and refusal never raise an alarm', () {
    for (final p in [
      'I am fine, do not call anyone',
      'it is not an emergency',
      'I am not scared',
      'tell my caretaker I am okay',
      'I am not in danger',
      "i'm not in danger",
      'no I\'m not in danger',
      'I do not need help',
      'I dont need help i am ok',
      'help! false alarm',
      'sorry false alarm',
      'what is the emergency number',
      'is this an emergency',
      'I fell but I am okay',
      "I don't need an ambulance",
      "don't call the police",
      'no help needed thanks',
      "I'm fine thanks for the help",
      'tell my caretaker i am okay',
      'let my caretaker know I am safe',
      'emergency contacts',
      'show emergency contacts',
      'sahajjo lagbe na',
      'ami thik achi',
      'ami thik achi help lagbe na',
      'আমি ঠিক আছি',
      'আমি ঠিক আছি সাহায্য লাগবে না',
      'আমার সাহায্য লাগবে না',
      'আপনার সাহায্য দরকার নেই',
      'আমি ভয় পাচ্ছি না',
      'আমার কিছু হয়নি',
      'আমি পড়ে গেছি কিন্তু ঠিক আছি',
      'ami bipode nei',
    ]) {
      test('"$p" is not an SOS', () {
        expect(en(p)?.name, isNot('trigger_emergency'));
        expect(bn(p)?.name, isNot('trigger_emergency'));
      });
    }
  });

  group('emergency: direct cries are raised in every script', () {
    for (final p in [
      'help',
      'help me',
      'help me please',
      'somebody help',
      'someone help',
      'please help',
      'hey jarvis help me',
      'I am in danger',
      'sos',
      'SOS',
      'save me',
      'I cannot get up',
      'i might faint',
      'bachao',
      'bachao bachao',
      'amake bachao',
      'bachaw',
      'sahajjo koro',
      'amake ektu sahajjo koro',
      'ami bipode achi',
      'ami bipode porechi',
      'joruri obostha',
      'বাঁচাও',
      'বাঁচাও বাঁচাও',
      'আমাকে বাঁচাও',
      'আমাকে বাঁচান',
      'সাহায্য',
      'সাহায্য করো',
      'আমাকে সাহায্য করো',
      'আমাকে সাহায্য করুন',
      'হেল্প',
      'আমি বিপদে পড়েছি',
      'জরুরি অবস্থা',
      'আমি উঠতে পারছি না',
      'কেউ আমার পিছু নিচ্ছে আমি ভয় পাচ্ছি',
      'someone is following me and i am scared',
      'bhai help',
      'ভাই সাহায্য করুন',
      'help I fell and can not get up',
      'help someone grabbed my bag',
      'help my wheelchair is stuck',
      'help a man is following me',
      'help I am lost',
      'বাঁচাও আমি ঠিক নেই',
      'আমি পড়ে গেছি সাহায্য করুন',
    ]) {
      test('"$p" raises the SOS', () {
        expect(en(p)?.name, 'trigger_emergency');
      });
    }

    test('an SOS beats a pending text-size follow-up ("help me again")', () {
      expect(en('help me again', recent: 'text_size')?.name, 'trigger_emergency');
      expect(en('help more', recent: 'text_size')?.name, 'trigger_emergency');
    });

    test('Banglish "koro" is stripped on the second pass: "help koro", "amake help koro"', () {
      expect(en('help koro')?.name, 'trigger_emergency');
      expect(en('amake help koro')?.name, 'trigger_emergency');
    });
  });

  group('emergency: errands and questions about the feature stay out', () {
    for (final p in [
      'can you help me find a pharmacy',
      'help me find a pharmacy',
      'help me cross the road',
      'help me get home',
      'help the old lady cross',
      'excuse me can you help me',
      'আমাকে রাস্তা পার হতে সাহায্য করুন',
      'রাস্তা পার হতে সাহায্য করো',
      'what happens if I say help',
    ]) {
      test('"$p" is not an SOS', () {
        expect(en(p)?.name, isNot('trigger_emergency'));
        expect(bn(p)?.name, isNot('trigger_emergency'));
      });
    }

    test('place names made of command words route as destinations', () {
      for (final p in [
        'take me to Cancel Road',
        'take me to Help Pharmacy',
        'take me to Stop & Shop',
        'take me to Stop and Shop',
        'take me to SOS Hospital',
        'take me to Emergency Road',
        'take me to the emergency room',
        'go to Cancel Road',
        'navigate to Help Pharmacy',
      ]) {
        expect(en(p)?.name, 'request_route', reason: p);
      }
      expect(en('take me to Cancel Road')?.args['destination'], 'Cancel Road');
      expect(en('take me to Stop & Shop')?.args['destination'], 'Stop & Shop');
    });

    test('the lab/ল্যাব boundary: a fall at the lab is still an SOS, a lab destination routes', () {
      expect(bn('আমি ল্যাবে পড়ে গেছি, উঠতে পারছি না')?.name, 'trigger_emergency');
      expect(bn('ধানমন্ডি ল্যাব এইড যেতে চাই')?.args['destination'], 'ধানমন্ডি ল্যাব এইড');
      expect(bn('ল্যাব এইড যেতে চাই')?.args['destination'], 'ল্যাব এইড');
    });
  });

  group('routing', () {
    test('plain English requests', () {
      expect(en('take me to gulshan')?.args['destination'], 'gulshan');
      expect(en('navigate to azimpur')?.args['destination'], 'azimpur');
      expect(en('take me home')?.args['destination'], 'home');
      expect(en('go home')?.args['destination'], 'home');
      expect(en('I want to go home')?.args['destination'], 'home');
      expect(en('take me to labaid please')?.args['destination'], 'labaid');
      expect(en('take me to labaid thanks')?.args['destination'], 'labaid');
      expect(en('um take me to labaid')?.args['destination'], 'labaid');
      expect(en('take me to gulshan 2 circle')?.args['destination'], 'gulshan 2 circle');
      expect(en('take me to work')?.args['destination'], 'work');
    });

    test('refusals and vague destinations do not route', () {
      for (final p in [
        "don't want to go to gulshan",
        "I don't want to go home",
        'take me somewhere',
        'take me',
        'I am going home',
        'should I go to gulshan',
        'how far is it to go to uttara',
        'this is not my workplace',
        'can you take me somewhere else',
        'azimpur e jabo na',
        'ami azimpur jabo na',
        'jabo',
        'niye chalo',
      ]) {
        expect(en(p)?.name, isNot('request_route'), reason: p);
      }
      expect(bn('আমি অফিসে যাব না')?.name, isNot('request_route'));
      expect(bn('গুলশানে যেতে চাই না')?.name, isNot('request_route'));
    });

    test('Banglish destination-then-verb and carry-me shapes', () {
      expect(en('farmgate jabo')?.args['destination'], 'farmgate');
      expect(en('farmgate e jabo')?.args['destination'], 'farmgate');
      expect(en('farmgate jete chai')?.args['destination'], 'farmgate');
      expect(en('amake farmgate niye chalo')?.args['destination'], 'farmgate');
      expect(en('amake farmgate niye jao')?.args['destination'], 'farmgate');
      expect(en('hospital e jete chai')?.args['destination'], 'hospital');
    });

    test('Bangla verbs-last requests, with place names that start with না', () {
      expect(bn('গুলশানে যেতে চাই')?.args['destination'], 'গুলশানে');
      expect(bn('আমি ফার্মগেট যেতে চাই')?.args['destination'], 'ফার্মগেট');
      expect(bn('নারায়ণগঞ্জ যাব')?.args['destination'], 'নারায়ণগঞ্জ');
      expect(bn('নাখালপাড়া যেতে চাই')?.args['destination'], 'নাখালপাড়া');
      expect(bn('আমি বাসায় যেতে চাই')?.args['destination'], 'বাসায়');
    });

    test('nearest-category requests resolve locally', () {
      expect(en('I need to use the bathroom')?.args['destination'], 'nearest toilet');
      expect(en('I need to poop')?.args['destination'], 'nearest toilet');
      expect(en('I am hungry')?.args['destination'], 'nearest restaurant');
      expect(en('take me to the nearest hospital')?.name, 'request_route');
    });

    test('change-of-route and commute phrases', () {
      expect(en('give me a different route')?.name, 'request_alternative_route');
      expect(en('another way to gulshan')?.name, isNot('request_alternative_route'));
      expect(en('reroute')?.name, 'replan_route');
      expect(en('bus route to farmgate')?.args['destination'], 'farmgate');
      expect(en('transport options for gulshan')?.args['destination'], 'gulshan');
    });
  });

  group('cancel, map and stop vocabulary', () {
    test('cancelling a trip', () {
      for (final p in [
        'cancel the trip',
        'cancel my trip',
        'stop the route',
        'trip cancel koro',
        'trip bondho koro',
        'end navigation',
      ]) {
        expect(en(p)?.name, 'cancel_route', reason: p);
      }
      expect(bn('ট্রিপ বাতিল')?.name, 'cancel_route');
      expect(bn('ট্রিপটা ক্যানসেল করে দাও')?.name, 'cancel_route');
    });

    test('bare cancel/stop/yes/no are left to the pending-question state, not matched', () {
      for (final p in [
        'cancel', 'stop', 'yes', 'no', 'okay', 'ok', 'haan', 'na', 'হ্যাঁ', 'না', 'ঠিক আছে',
        'cancel the alarm', 'cancel the message', 'cancel alarm',
      ]) {
        expect(en(p), isNull, reason: p);
      }
    });

    test('map show/hide, including the "close the map" ordering trap', () {
      expect(en('show map')?.name, 'open_map');
      expect(en('show the map')?.name, 'open_map');
      expect(en('map dekhao')?.name, 'open_map');
      expect(en('map on')?.name, 'open_map');
      expect(en('hide map')?.name, 'close_map');
      expect(en('close the map')?.name, 'close_map');
      expect(en('map off')?.name, 'close_map');
      expect(en('map bondho koro')?.name, 'close_map');
      expect(bn('ম্যাপ দেখাও')?.name, 'open_map');
      expect(en('map'), isNull);
      expect(en('show'), isNull);
    });

    test('compound: take me + show map / cancel + show map resolve to one clear intent', () {
      expect(en('take me to gulshan and cancel the trip')?.name, 'cancel_route');
    });
  });

  group('settings (verified correct)', () {
    test('theme', () {
      expect(en('dark mode')?.args['value'], 'dark');
      expect(en('light mode')?.args['value'], 'light');
      expect(en('black background')?.args['value'], 'dark');
      expect(en('white background')?.args['value'], 'light');
      expect(en("it's getting dark outside"), isNull);
      expect(en('the street is dark'), isNull);
      expect(en('it is dark here'), isNull);
      expect(bn('অন্ধকার মোড চালু করো')?.args['value'], 'dark');
    });

    test('text size, English, Banglish and Bangla', () {
      expect(en('make the text bigger')?.args['value'], '_bigger');
      expect(en('make the text smaller')?.args['value'], '_smaller');
      expect(en('lekha boro koro')?.args['value'], '_bigger');
      expect(en('lekha choto koro')?.args['value'], '_smaller');
      expect(en('font ta choto kore dao')?.args['value'], '_smaller');
      expect(bn('লেখা বড় করো')?.args['value'], '_bigger');
      expect(en('text is too big make it smaller'), isNull);
    });

    test('follow-ups lean on the most recent setting only', () {
      expect(en('bigger', recent: 'text_size')?.args['value'], '_bigger');
      expect(en('even bigger', recent: 'text_size')?.args['value'], '_bigger');
      expect(en('a bit less', recent: 'text_size')?.args['value'], '_smaller');
      expect(en('bigger', recent: null), isNull);
      expect(en('bigger or smaller', recent: 'text_size'), isNull);
      expect(en('not bigger', recent: 'text_size'), isNull);
      expect(en('that is enough', recent: 'text_size'), isNull);
    });

    test('deaf / hearing statements keep their polarity (apart from "not deaf", see bugs)', () {
      expect(en('i am deaf')?.args['value'], 'true');
      expect(en('i cannot hear')?.args['value'], 'true');
      expect(en("i can't hear well")?.args['value'], 'true');
      expect(en('i can hear fine')?.args['value'], 'false');
      expect(bn('আমি শুনতে পাই')?.args['value'], 'false');
      expect(bn('আমি শুনতে পাই না')?.args['value'], 'true');
      expect(bn('আমি কানে কম শুনি')?.args['value'], 'true');
      expect(en('i am blind'), isNull);
    });

    test('language and verbosity', () {
      expect(en('speak bangla')?.args['value'], 'bangla');
      expect(en('speak in english')?.args['value'], 'english');
      expect(bn('বাংলায় বলো')?.args['value'], 'bangla');
      expect(bn('ইংরেজিতে বলো')?.args['value'], 'english');
      expect(en('bangla'), isNull);
      expect(en('talk less')?.args['value'], 'minimalist');
      expect(en('tell me more')?.args['value'], 'descriptive');
      expect(bn('সংক্ষেপে বলো')?.args['value'], 'minimalist');
      expect(bn('বিস্তারিত বলো')?.args['value'], 'descriptive');
    });

    test('wake word and auto listen toggles', () {
      expect(en('turn off hey jarvis')?.args['value'], 'false');
      expect(en('turn on hey jarvis')?.args['value'], 'true');
      expect(en('disable wake word')?.args['setting'], 'wake_word_enabled');
      expect(en('turn off auto listen')?.args['setting'], 'voice_auto_listen');
      expect(en('hey jarvis'), isNull);
      expect(en('jarvis'), isNull);
    });
  });

  group('hazards and camera', () {
    test('reports need a report verb; questions and "no X" do not file one', () {
      expect(en('there is a pothole')?.args['subCategory'], 'pothole');
      expect(en('report an open manhole')?.args['subCategory'], 'openManhole');
      expect(en('report a mugging')?.args['subCategory'], 'mugging');
      expect(en('is there a pothole'), isNull);
      expect(en('is there a pothole ahead'), isNull);
      expect(en('there is no pothole'), isNull);
      expect(en('no pothole'), isNull);
      expect(en('i see a dog'), isNull);
      expect(bn('গর্ত নেই'), isNull);
      expect(bn('ম্যানহোল খোলা আছে')?.args['subCategory'], 'openManhole');
    });

    test('resolution phrases', () {
      expect(en('the pothole is fixed')?.name, 'resolve_hazard');
      expect(bn('গর্ত ঠিক হয়ে গেছে')?.name, 'resolve_hazard');
      for (final p in [
        'is it fixed', 'is the ramp fixed', 'was the pothole fixed', 'the ramp is not fixed',
        "the ramp isn't fixed", 'the manhole is not fixed', 'ঠিক হয়নি', 'সারানো হয়নি',
      ]) {
        expect(en(p)?.name, isNot('resolve_hazard'), reason: p);
      }
    });

    test('camera questions pick the right focus', () {
      expect(en('what bus is this')?.args['focus'], 'vehicle');
      expect(en('which bus is this')?.args['focus'], 'vehicle');
      expect(en('read the sign')?.args['focus'], 'sign');
      expect(en('is it safe to cross')?.args['focus'], 'hazard');
      expect(en("what's in front of me")?.args['focus'], 'ahead');
      expect(en('what is around me')?.args['focus'], 'surroundings');
      expect(en('open camera')?.name, 'open_camera');
      expect(en('what happens if I say what bus is this'), isNull);
      expect(en('send a photo of what is in front of me to my caretaker')?.name,
          isNot('trigger_emergency'));
    });

    test('where am I, caretaker alerts and capabilities', () {
      expect(en('where am i')?.name, 'describe_current_location');
      expect(en('ami kothay achi')?.name, 'describe_current_location');
      expect(bn('আমি কোথায়')?.name, 'describe_current_location');
      expect(en('alert my caretaker')?.name, 'alert_caretaker');
      expect(en('tell my caretaker where I am')?.name, 'alert_caretaker');
      expect(en('send my location to my caretaker')?.name, 'alert_caretaker');
      expect(en('caretaker ke janao')?.name, 'alert_caretaker');
      expect(en('tell my caretaker I am late'), isNull);
      expect(en('alert my caretaker I am fine'), isNull);
      expect(en('what can you do')?.name, 'describe_capabilities');
      expect(en('how do I call for help')?.name, 'describe_capabilities');
    });

    test('pairing needs a code and a pairing word', () {
      expect(en('my pairing code is 123456')?.args['code'], '123456');
      expect(en('the bus number was 123456'), isNull);
      expect(bn('পেয়ারিং কোড ১২৩৪৫৬')?.args['code'], isNull,
          reason: 'Bengali digits are not read by the pairing matcher (see not_testable/notes)');
    });
  });

  group('wake-word residue that does survive', () {
    test('"hey jarvis" in front of ordinary commands', () {
      expect(en('hey jarvis take me to gulshan')?.name, 'request_route');
      expect(en('hey jarvis show the map')?.name, 'open_map');
      expect(en('hey jarvis cancel the trip')?.name, 'cancel_route');
      expect(en('hey jarvis go home')?.name, 'request_route');
      expect(en('hey jarvis open camera')?.name, 'open_camera');
    });
  });

  group('SOS cancel window vocabulary', () {
    test('narrow list: shouted words do not abort the alarm', () {
      expect(VoiceCancelWindow.cancelsEmergency('cancel'), isTrue);
      expect(VoiceCancelWindow.cancelsEmergency('cancel it'), isTrue);
      expect(VoiceCancelWindow.cancelsEmergency('বাতিল'), isTrue);
      expect(VoiceCancelWindow.cancelsEmergency('ক্যান্সেল'), isTrue);
      expect(VoiceCancelWindow.cancelsEmergency('stop'), isFalse);
      expect(VoiceCancelWindow.cancelsEmergency('Stop! Get away from me!'), isFalse);
      expect(VoiceCancelWindow.cancelsEmergency('he is pushing me against the wall'), isFalse);
      expect(VoiceCancelWindow.cancelsEmergency('no'), isFalse);
      expect(VoiceCancelWindow.cancelsEmergency('help me'), isFalse);
    });

    test('dictation window: cancel/edit classification', () {
      expect(VoiceCancelWindow.classify('cancel'), CancelWindowOutcome.cancelled);
      expect(VoiceCancelWindow.classify('বাতিল'), CancelWindowOutcome.cancelled);
      expect(VoiceCancelWindow.classify('ক্যানসেল'), CancelWindowOutcome.cancelled);
      expect(VoiceCancelWindow.classify('change it'), CancelWindowOutcome.edit);
      expect(VoiceCancelWindow.classify('that is wrong cancel'), CancelWindowOutcome.edit);
      expect(VoiceCancelWindow.classify('no'), isNull);
      expect(VoiceCancelWindow.classify(''), isNull);
    });

    test('voice memo controls', () {
      expect(voiceMemoCommand('send'), VoiceMemoCommand.send);
      expect(voiceMemoCommand('Send it!'), VoiceMemoCommand.send);
      expect(voiceMemoCommand('stop'), VoiceMemoCommand.send);
      expect(voiceMemoCommand('cancel'), VoiceMemoCommand.cancel);
      expect(voiceMemoCommand('বাতিল'), VoiceMemoCommand.cancel);
      expect(voiceMemoCommand('send help'), isNull);
      expect(voiceMemoCommand("don't send"), isNull);
    });
  });

  group('offline matcher', () {
    test('safety keywords get a canned reply in both languages', () {
      expect(OfflineIntentMatcher.match('emergency', AppLanguage.english), contains('Magic Button'));
      expect(OfflineIntentMatcher.match('বাঁচাও', AppLanguage.bangla), contains('ম্যাজিক বাটন'));
      expect(OfflineIntentMatcher.match('ami bachao', AppLanguage.english), contains('Magic Button'));
      expect(OfflineIntentMatcher.match('where am i', AppLanguage.english), contains('location'));
      expect(OfflineIntentMatcher.match('hello', AppLanguage.english), isNull);
    });
  });

  group('saved places, ordinals and categories', () {
    const places = [
      SavedPlace(label: 'Home', kind: SavedPlaceKind.home, address: 'x'),
      SavedPlace(label: 'Office', kind: SavedPlaceKind.work, address: 'x'),
      SavedPlace(label: "Ma's house", kind: SavedPlaceKind.family, address: 'x'),
      SavedPlace(label: "Bhai's house", kind: SavedPlaceKind.family, address: 'x'),
      SavedPlace(label: 'Labaid', kind: SavedPlaceKind.medical, address: 'x'),
    ];
    List<String> sp(String s) => SavedPlaceMatcher.candidates(s, places).map((p) => p.label).toList();

    test('label, kind synonym and Bangla inflection', () {
      expect(sp('Labaid Hospital Uttara'), ['Labaid']);
      expect(sp('বাসা'), ['Home']);
      expect(sp('বাসায়'), ['Home']);
      expect(sp('আমার বাসা'), ['Home']);
      expect(sp('Mohakhali bus station'), isEmpty);
      expect(sp('Baitul Mukarram Mosque'), isEmpty);
      expect(sp('marketplace'), isEmpty);
      expect(sp('ma'), isEmpty);
    });

    test('an ambiguous reference returns every candidate instead of picking one', () {
      expect(sp('my sisters house'), unorderedEquals(["Ma's house", "Bhai's house"]));
      expect(SavedPlaceMatcher.resolve('my sisters house', places), isNull);
    });

    final options = [
      const GeocodeCandidate(label: 'Labaid Hospital, Dhanmondi, Dhaka', location: LatLng(23.74, 90.37)),
      const GeocodeCandidate(label: 'Labaid Hospital, Gulshan, Dhaka', location: LatLng(23.79, 90.41)),
      const GeocodeCandidate(label: 'Labaid Hospital, Uttara, Dhaka', location: LatLng(23.87, 90.40)),
    ];
    final pending = DestinationClarification(originalQuery: 'labaid', options: options);
    ClarificationOutcome ask(String r) =>
        DestinationClarifier.interpret(reply: r, pending: pending, language: AppLanguage.english);
    String picked(String r) {
      final o = ask(r);
      return o is ClarificationResolved ? o.candidate.label : o.runtimeType.toString();
    }

    test('picking by ordinal, digit, Bangla numeral and distinctive word', () {
      expect(picked('second'), contains('Gulshan'));
      expect(picked('2'), contains('Gulshan'));
      expect(picked('number three'), contains('Uttara'));
      expect(picked('দুই'), contains('Gulshan'));
      expect(picked('২'), contains('Gulshan'));
      expect(picked('তিন নম্বর'), contains('Uttara'));
      expect(picked('uttara'), contains('Uttara'));
      expect(picked('the one in uttara'), contains('Uttara'));
      expect(picked('labaid gulshan'), contains('Gulshan'));
    });

    test('cancelling and refining', () {
      expect(ask('cancel'), isA<ClarificationCancelled>());
      expect(ask('never mind'), isA<ClarificationCancelled>());
      expect(ask('থাক'), isA<ClarificationCancelled>());
      expect(ask('no thanks'), isA<ClarificationCancelled>());
      expect(ask('the one near the school'), isA<ClarificationRefined>());
      expect(ask(''), isA<ClarificationUnclear>());
    });

    test('placeholders and nearest markers', () {
      expect(DestinationClarifier.isPlaceholder('somewhere'), isTrue);
      expect(DestinationClarifier.isPlaceholder('অন্য জায়গা'), isTrue);
      expect(DestinationClarifier.isPlaceholder('Gulshan'), isFalse);
      expect(DestinationClarifier.wantsNearest('nearest hospital'), isTrue);
      expect(DestinationClarifier.wantsNearest('Ibn Sina Hospital'), isFalse);
    });

    test('categories', () {
      expect(categoryFor('the nearest bathroom')?.id, 'toilet');
      expect(categoryFor('কাছের টয়লেট')?.id, 'toilet');
      expect(categoryFor('Gulshan 2'), isNull);
      expect(categoryFor('Waterloo'), isNull);
      expect(categoryFor('a'), isNull);
    });
  });

  group('yes/no classification (verified correct)', () {
    bool? yn(String s) => classifyTraitYesNo(s, presentPhrases: const [], absentPhrases: const []);
    test('plain answers', () {
      expect(yn('yes'), isTrue);
      expect(yn('yeah'), isTrue);
      expect(yn('হ্যাঁ'), isTrue);
      expect(yn('no'), isFalse);
      expect(yn('না'), isFalse);
      expect(yn('nope'), isFalse);
      expect(yn('Know.'), isFalse, reason: 'documented STT homophone of "no"');
      expect(yn('maybe'), isNull);
      expect(yn('okay'), isNull);
      expect(yn(''), isNull);
    });
    test('help requests', () {
      for (final p in ['repeat', 'say again', 'আবার বলো', 'what are the options', "I don't understand", 'pardon']) {
        expect(isHelpRequest(p), isTrue, reason: p);
      }
    });
  });

  group('spoken digits and speech sanitiser', () {
    test('digit words, Bengali numerals and double/triple', () {
      expect(spokenTextToDigits('zero one seven one two three four five six seven eight'), '01712345678');
      expect(spokenTextToDigits('০১৭১২৩৪৫৬৭৮'), '01712345678');
      expect(spokenTextToDigits('শূন্য এক সাত এক দুই তিন চার পাঁচ ছয় সাত আট'), '01712345678');
      expect(spokenTextToDigits('oh one seven one'), '0171');
      expect(spokenTextToDigits('double three'), '33');
      expect(spokenTextToDigits('triple five'), '555');
      expect(spokenTextToDigits('ডাবল তিন'), '33');
      expect(spokenTextToDigits('01712-345678'), '01712345678');
      expect(spokenTextToDigits(''), '');
    });

    test('forSpeech strips markdown and keeps digits', () {
      expect(forSpeech('**Labaid** is 400m away'), 'Labaid is 400m away');
      expect(forSpeech(''), '');
      expect(forSpeech('Turn left at the **mosque**.'), 'Turn left at the mosque.');
    });
  });

  group('never crash on hostile input', () {
    final inputs = <String>[
      '', ' ', '   \n\t  ', '!!!???...', '।।।', '😀😀😀', '🆘', '‏‎‮ abc',
      'a‍b‌c', 'help\u0000me', '\u0000', '১২৩৪৫৬ 123456', 'pairing code ১২৩৪৫৬',
      'x' * 800, ' ' * 800, 'a ' * 200, 'আ' * 800, 'আমি ' * 200, 'take me to ' + 'a' * 800,
      'go to ' * 100, 'help ' * 100, 'cancel ' * 100, 'নিয়ে ' * 100, 'যাব ' * 100,
      'ami ' * 100 + 'jabo', 'koro ' * 100, 'please ' * 100, 'করে ' * 100, 'ু' * 500,
      '্' * 500, 'ক্' * 300, 'ঁ' * 300, '\uD83D', '\uDE00', 'a\uD83Db',
      'following ' + 'x' * 500 + ' scared', 'cancel the ' + 'trip ' * 100 + 'close',
    ];
    test('every public entry point returns without throwing', () {
      for (final t in inputs) {
        for (final lang in AppLanguage.values) {
          LocalIntentMatcher.match(t, lang);
          LocalIntentMatcher.match(t, lang, recentSetting: 'text_size');
          OfflineIntentMatcher.match(t, lang);
        }
        voiceMemoCommand(t);
        VoiceCancelWindow.classify(t);
        VoiceCancelWindow.cancelsEmergency(t);
        spokenTextToDigits(t);
        forSpeech(t);
        voiceWords(t);
        categoryFor(t);
        DestinationClarifier.wantsNearest(t);
        DestinationClarifier.isPlaceholder(t);
        DestinationClarifier.isCancellation(t);
        isHelpRequest(t);
        classifyTraitYesNo(t, presentPhrases: const ['deaf'], absentPhrases: const ['hear fine']);
        fuzzyMatchScore(t, 'no vision');
        LocalIntentMatcher.containsBnWord(t, 'যাব');
        SavedPlaceMatcher.candidates(t, const [SavedPlace(label: 'Home', kind: SavedPlaceKind.home)]);
      }
    });
  });
}
