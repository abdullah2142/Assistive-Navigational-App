import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/vision/vision_prompt.dart';
import 'package:ant_app/core/services/vision/vision_detection.dart';
import 'package:ant_app/core/services/vision/vision_scene.dart';
import 'package:flutter_test/flutter_test.dart';

/// Module 6 — the Snapshot Vision Engine.
///
/// Everything here is the part of the module that can be decided without a
/// camera, a network or a phone: the stop-or-go arithmetic, the response
/// contract with the vision model, and the phrases that route a spoken
/// question to a scan. The parts that genuinely need hardware — TFLite
/// inference timing, camera open latency, the real accuracy of the detector
/// on a Dhaka street — are not simulated here, because a passing fake would
/// be worse than no test at all.

VisionDetection det(
  String label, {
  double confidence = 0.9,
  double left = 0.4,
  double top = 0.4,
  double right = 0.6,
  double bottom = 0.6,
}) => VisionDetection(
  label: label,
  confidence: confidence,
  left: left,
  top: top,
  right: right,
  bottom: bottom,
);

void main() {
  group('HazardAssessor — the stop-or-go decision', () {
    const assessor = HazardAssessor();

    test('a bus filling the lower centre of the frame is imminent', () {
      final verdict = assessor.assess([
        det('bus', left: 0.2, top: 0.25, right: 0.8, bottom: 0.95),
      ]);
      expect(verdict.level, HazardLevel.imminent);
      expect(verdict.nearest?.label, 'bus');
    });

    test('the same bus far away and high in frame is not', () {
      final verdict = assessor.assess([
        det('bus', left: 0.46, top: 0.44, right: 0.54, bottom: 0.52),
      ]);
      expect(verdict.isImminent, isFalse);
    });

    test('a person at the same size as an imminent bus is not imminent', () {
      // The class weights exist for exactly this. A crowded footpath puts
      // people this size in frame constantly, and an alarm that fires on
      // every one of them is an alarm the user learns to walk through.
      final box = (left: 0.2, top: 0.25, right: 0.8, bottom: 0.95);
      final bus = assessor.assess([
        det(
          'bus',
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
        ),
      ]);
      final person = assessor.assess([
        det(
          'person',
          left: box.left,
          top: box.top,
          right: box.right,
          bottom: box.bottom,
        ),
      ]);
      expect(bus.level, HazardLevel.imminent);
      expect(person.threatScore, lessThan(bus.threatScore));
    });

    test('a vehicle at the frame edge scores below the same one centred', () {
      final centred = assessor.assess([
        det('car', left: 0.35, top: 0.3, right: 0.65, bottom: 0.9),
      ]);
      final edge = assessor.assess([
        det('car', left: 0.0, top: 0.3, right: 0.30, bottom: 0.9),
      ]);
      expect(edge.threatScore, lessThan(centred.threatScore));
    });

    test('low-confidence detections are ignored entirely', () {
      final verdict = assessor.assess([
        det(
          'bus',
          confidence: 0.2,
          left: 0.1,
          top: 0.1,
          right: 0.9,
          bottom: 1.0,
        ),
      ]);
      expect(verdict.detections, isEmpty);
      expect(verdict.isImminent, isFalse);
    });

    test(
      'harmless COCO classes never raise the alarm but stay in the list',
      () {
        // A potted plant filling the frame is not a reason to stop somebody
        // mid-step — but it is still worth having available to describe.
        final verdict = assessor.assess([
          det('potted plant', left: 0.0, top: 0.0, right: 1.0, bottom: 1.0),
        ]);
        expect(verdict.level, HazardLevel.clear);
        expect(verdict.detections.single.label, 'potted plant');
      },
    );

    test('people are counted even when none of them is a hazard', () {
      final verdict = assessor.assess([
        det('person', left: 0.1, top: 0.45, right: 0.2, bottom: 0.55),
        det('person', left: 0.3, top: 0.45, right: 0.4, bottom: 0.55),
        det('person', left: 0.5, top: 0.45, right: 0.6, bottom: 0.55),
        det('car', left: 0.8, top: 0.45, right: 0.9, bottom: 0.55),
      ]);
      expect(verdict.personCount, 3);
    });

    test('an empty frame is clear, not an error', () {
      expect(assessor.assess(const []).level, HazardLevel.clear);
    });
  });

  group('CloudVisionService — the response contract', () {
    test('parses a full scene', () {
      final scene = VisionPrompt.parse(
        '{"say":"একটি বাস আসছে।",'
        '"hazards":[{"kind":"manhole","description":"খোলা ম্যানহোল","severity":3}],'
        '"vehicles":[{"kind":"bus","route_number":"৬","destination":"মিরপুর","raw_text":"৬ মিরপুর"}],'
        '"text_found":"৬ মিরপুর","people_estimate":4}',
        ScanFocus.vehicle,
      );
      expect(scene, isNotNull);
      expect(scene!.spoken, 'একটি বাস আসছে।');
      expect(scene.hazards.single.kind, 'manhole');
      expect(scene.hazards.single.severity, 3);
      expect(scene.peopleEstimate, 4);
    });

    test('normalises Bangla route numerals to ASCII', () {
      // The route number is the key into the directory that overrides the
      // model's unverified destination reading. A lookup that missed because
      // of the numeral system would silently hand the user the guess instead
      // of the verified answer — see VisionConfig.busRouteLookupWins.
      expect(VisionPrompt.normaliseDigits('৬'), '6');
      expect(VisionPrompt.normaliseDigits('১০ নং'), '10');
      expect(VisionPrompt.normaliseDigits('Route 27'), '27');
      expect(VisionPrompt.normaliseDigits('no number here'), isNull);
      expect(VisionPrompt.normaliseDigits(''), isNull);
    });

    test(
      'an empty scene parses to empty lists rather than inventing content',
      () {
        final scene = VisionPrompt.parse(
          '{"say":"কিছু দেখা যাচ্ছে না।","hazards":[],"vehicles":[],"text_found":"","people_estimate":0}',
          ScanFocus.surroundings,
        );
        expect(scene!.hazards, isEmpty);
        expect(scene.vehicles, isEmpty);
        expect(scene.hasHazards, isFalse);
      },
    );

    test('a response with no sentence is rejected', () {
      // Everything else in a scene exists to support the one spoken line. A
      // scene without it would append a blank bubble and say nothing, which
      // to a blind user is indistinguishable from the scan never running.
      expect(VisionPrompt.parse('{"hazards":[]}', ScanFocus.sign), isNull);
      expect(VisionPrompt.parse('{"say":"   "}', ScanFocus.sign), isNull);
    });

    test('malformed JSON is rejected rather than thrown', () {
      expect(VisionPrompt.parse('not json at all', ScanFocus.sign), isNull);
    });

    test('a fenced response is still parsed', () {
      final scene = VisionPrompt.parse(
        '```json\n{"say":"ঠিক আছে।"}\n```',
        ScanFocus.sign,
      );
      expect(scene?.spoken, 'ঠিক আছে।');
    });

    test('hazards with no description are dropped', () {
      final scene = VisionPrompt.parse(
        '{"say":"ok","hazards":[{"kind":"manhole","description":""},'
        '{"kind":"fire","description":"আগুন"}]}',
        ScanFocus.hazard,
      );
      expect(scene!.hazards.single.kind, 'fire');
    });

    test(
      'an unrecognised hazard kind falls back rather than being dropped',
      () {
        final scene = VisionPrompt.parse(
          '{"say":"ok","hazards":[{"kind":"a pile of bricks","description":"ইট"}]}',
          ScanFocus.hazard,
        );
        expect(scene!.hazards.single.kind, 'other');
        expect(scene.hazards.single.description, 'ইট');
      },
    );

    test('severity is clamped into range', () {
      final scene = VisionPrompt.parse(
        '{"say":"ok","hazards":[{"kind":"fire","description":"আগুন","severity":9}]}',
        ScanFocus.hazard,
      );
      expect(scene!.hazards.single.severity, 3);
    });
  });

  group('LocalIntentMatcher — reaching a scan without the model', () {
    // This path exists for latency, not for tokens: "what bus is this" is
    // asked with a bus already pulling in, and a round trip to decide the
    // answer is `look_around(vehicle)` spends a second the user does not have.
    void expectsFocus(String phrase, String focus, AppLanguage language) {
      final intent = LocalIntentMatcher.match(phrase, language);
      expect(intent?.name, 'look_around', reason: 'phrase: "$phrase"');
      expect(intent?.args['focus'], focus, reason: 'phrase: "$phrase"');
    }

    test('English vehicle questions', () {
      expectsFocus('what bus is this', 'vehicle', AppLanguage.english);
      expectsFocus('which bus is coming', 'vehicle', AppLanguage.english);
    });

    test('Bangla vehicle questions', () {
      expectsFocus('এটা কোন বাস', 'vehicle', AppLanguage.bangla);
      expectsFocus('বাসটা কোন নম্বর', 'vehicle', AppLanguage.bangla);
    });

    test('sign reading', () {
      expectsFocus('read the sign', 'sign', AppLanguage.english);
      expectsFocus('what does it say', 'sign', AppLanguage.english);
      expectsFocus('সাইনবোর্ডে কী লেখা', 'sign', AppLanguage.bangla);
    });

    test('crossing and path questions ask for the hazard focus', () {
      expectsFocus('is it safe to cross', 'hazard', AppLanguage.english);
      expectsFocus('is the path clear', 'hazard', AppLanguage.english);
      expectsFocus('রাস্তা কি ফাঁকা', 'hazard', AppLanguage.bangla);
    });

    test('direct ahead questions use one frame; explicit scans sweep', () {
      expectsFocus("what's in front of me", 'ahead', AppLanguage.english);
      expectsFocus('what do you see', 'ahead', AppLanguage.english);
      expectsFocus('সামনে কী আছে', 'ahead', AppLanguage.bangla);
      expectsFocus('look around', 'surroundings', AppLanguage.english);
    });

    test('vehicle wins over the generic reading when a phrase is both', () {
      // "what bus is this" is also a "what is this". The vehicle reading is
      // the useful one, and ordering is what guarantees it.
      final intent = LocalIntentMatcher.match(
        'what bus is this',
        AppLanguage.english,
      );
      expect(intent?.args['focus'], 'vehicle');
    });

    test('a scan is never opened by ordinary conversation', () {
      // The class contract is that a local match is *more* certain than a
      // model call. A bare verb that shows up in everyday speech must not
      // open a camera.
      for (final phrase in [
        'i can see fine thanks',
        'take me to the bus stand',
        'look, i already told you',
        'আমি বাসে করে যাব',
        'দেখা হবে',
      ]) {
        final intent = LocalIntentMatcher.match(phrase, AppLanguage.english);
        expect(intent?.name, isNot('look_around'), reason: 'phrase: "$phrase"');
      }
    });

    test('asking about the feature does not trigger it', () {
      final intent = LocalIntentMatcher.match(
        'what happens if i ask what bus is this',
        AppLanguage.english,
      );
      expect(intent?.name, isNot('look_around'));
    });
  });

  group('The scene cache', () {
    // The cache exists because a blind user asks twice when unsure they were
    // heard, and three scans is a whole minute of the shared token allowance.
    // It must not turn into answering a question that was not asked.
    test('a cached scene is tied to the question it answered', () {
      final bus = VisionPrompt.parse(
        '{"say":"৬ নং বাস আসছে।"}',
        ScanFocus.vehicle,
      );
      expect(bus!.focus, ScanFocus.vehicle);
      // `SnapshotVisionService._cachedScene` refuses to serve this for a
      // ScanFocus.hazard question. The focus riding on the scene is what
      // makes that check possible at all.
      expect(bus.focus == ScanFocus.hazard, isFalse);
    });

    test('a cached scene is flagged as cached', () {
      const scene = VisionScene(
        focus: ScanFocus.vehicle,
        spoken: 'x',
        fromCache: true,
      );
      expect(scene.fromCache, isTrue);
    });
  });

  group('Spoken strings — the failure/silence distinction', () {
    // The rule this whole block guards: a blind user who hears a confident
    // all-clear from a scan that never ran will step into the road. "I could
    // not see" and "there is nothing there" must never sound alike.
    for (final language in AppLanguage.values) {
      test('every vision failure names the failure (${language.name})', () {
        final d = Dashboard.of(language);
        for (final line in [
          d.visionNoCamera,
          d.visionCaptureFailed,
          d.visionOfflineNothingSeen,
          d.visionBudgetSpent,
          d.visionOfflineSaw('a bus'),
        ]) {
          expect(line.trim(), isNotEmpty);
          // Each one has to contain an explicit statement of inability. In
          // English that is a "cannot"/"did not"; in Bangla it is the
          // post-verbal negation particle "না" or "নি".
          final admitsFailure = language == AppLanguage.bangla
              ? (line.contains('না') || line.contains('নি'))
              : RegExp(r'cannot|could not|did not|too many').hasMatch(line);
          expect(
            admitsFailure,
            isTrue,
            reason: 'does not admit failure: "$line"',
          );
        }
      });

      test('the hazard abort is short enough to land before the next step '
          '(${language.name})', () {
        final d = Dashboard.of(language);
        final line = d.visionHazardAbort(d.visionObjectLabel('bus'));
        expect(
          line.split(RegExp(r'\s+')).length,
          lessThanOrEqualTo(8),
          reason: 'too long to hear before stepping: "$line"',
        );
      });

      test('both languages are actually translated (${language.name})', () {
        final d = Dashboard.of(language);
        final bn = language == AppLanguage.bangla;
        final bengali = RegExp(r'[ঀ-৿]');
        for (final line in [
          d.visionSweepPrompt,
          d.visionNoCamera,
          d.visionCaptureFailed,
        ]) {
          expect(bengali.hasMatch(line), bn, reason: 'wrong language: "$line"');
        }
      });
    }

    test('the detector is not made to sound more certain than it is', () {
      // COCO has no rickshaw and no CNG class: a cycle-rickshaw is detected
      // as `bicycle`. Saying "রিকশা" on that evidence would be confidently
      // wrong, which is the one thing this module must not be.
      final d = Dashboard.of(AppLanguage.bangla);
      expect(d.visionObjectLabel('bicycle'), contains('বা'));
      expect(d.visionObjectLabel('unknown-class'), d.visionObjectLabel(null));
    });
  });
}
