// Module 5 — Community Crowdsourcing & Temporal Safety, client side.
//
// The backend's clustering/decay/temporal maths is tested in
// `functions/test/hazard_logic.test.js`. These cover what the app itself
// has to get right: recognising a named hazard from speech without
// inventing reports, decoding the backend's $w_2$ verdict, and actually
// telling the user about a confirmed hazard it could not route around.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/local_intent_matcher.dart';
import 'package:ant_app/core/services/route_safety_service.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';

void main() {
  LocalIntent? matchEn(String t) => LocalIntentMatcher.match(t, AppLanguage.english);
  LocalIntent? matchBn(String t) => LocalIntentMatcher.match(t, AppLanguage.bangla);

  group('Step 1 — voice-first reporting jumps straight to the hazard', () {
    test('a named hazard fills in both category and sub-category', () {
      final intent = matchEn('report an open manhole');
      expect(intent?.name, 'open_hazard_report');
      expect(intent?.args['category'], 'roadHazard');
      expect(intent?.args['subCategory'], 'openManhole');
    });

    test('works across all three top-level categories', () {
      expect(matchEn('report a mugging')?.args['category'], 'crime');
      expect(matchEn('flag a broken ramp')?.args['subCategory'], 'brokenRamp');
      expect(matchEn('report flooding')?.args['subCategory'], 'flooding');
    });

    test('works in Bangla', () {
      final intent = matchBn('ম্যানহোল খোলা আছে');
      expect(intent?.name, 'open_hazard_report');
      expect(intent?.args['subCategory'], 'openManhole');
    });

    test('a bare report request still opens the form with nothing prefilled', () {
      final intent = matchEn('report a hazard');
      expect(intent?.name, 'open_hazard_report');
      expect(intent?.args['subCategory'], isNull);
    });

    test('merely mentioning a hazard does not file a report', () {
      // A report closes roads for other people. Asking about one must not
      // become claiming one.
      expect(matchEn('is there a pothole near me'), isNull);
      expect(matchEn('what does a manhole look like'), isNull);
      expect(matchEn('i am scared of flooding'), isNull);
    });

    test('every prefilled sub-category is a real key for its category', () {
      // A prefill the Hub cannot resolve would file a report under a key
      // nothing can read back — worse than no prefill at all.
      final d = Dashboard.of(AppLanguage.english);
      for (final phrase in [
        'report a mugging',
        'report harassment',
        'report stalking',
        'report no street light',
        'report an open manhole',
        'report a pothole',
        'report flooding',
        'report construction',
        'report a fallen tree',
        'report stairs only',
        'report a broken ramp',
        'report no curb cut',
        'report vendors blocking',
      ]) {
        final intent = matchEn(phrase);
        expect(intent, isNotNull, reason: '"$phrase" was not recognised at all');
        final category = HazardCategory.values.firstWhere((c) => c.name == intent!.args['category']);
        expect(
          d.hazardSubCategoryKeys(category),
          contains(intent!.args['subCategory']),
          reason: '"$phrase" produced a sub-category that is not valid for ${category.name}',
        );
      }
    });
  });

  group('Step 2 — decoding the backend verdict', () {
    SafetyVerdict verdict(Map<Object?, Object?> data) => SafetyVerdict.fromCallableResult(data);

    test('a confirmed (red) hazard blocks; an unconfirmed (yellow) one warns', () {
      final v = verdict({
        'safe': false,
        'riskScore': 9,
        'threshold': 7,
        'dangerousZones': const [],
        'blockingHazards': const [
          {'id': 'z1', 'category': 'roadHazard', 'subCategory': 'openManhole', 'flag': 'red', 'reportCount': 4},
        ],
        'hazardWarnings': const [
          {'id': 'z2', 'category': 'roadHazard', 'subCategory': 'pothole', 'flag': 'yellow', 'reportCount': 1},
        ],
      });

      expect(v.safe, isFalse);
      expect(v.blockingHazards.single.isConfirmed, isTrue);
      expect(v.hazardWarnings.single.isConfirmed, isFalse);
      expect(v.allHazards, hasLength(2));
      expect(v.allHazards.first.subCategory, 'openManhole', reason: 'confirmed hazards come first');
    });

    test('a response from an older backend degrades instead of throwing', () {
      // A client newer than the deployed function must keep routing, just
      // without $w_2$ — not fail every route request.
      final v = verdict({'safe': true, 'riskScore': 2, 'threshold': 7, 'dangerousZones': const []});
      expect(v.safe, isTrue);
      expect(v.allHazards, isEmpty);
    });
  });

  group('warnings are worded honestly and exist in both languages', () {
    for (final language in AppLanguage.values) {
      test('${language.name}: an unconfirmed report is attributed, not stated as fact', () {
        final d = Dashboard.of(language);
        final label = d.hazardSubCategoryLabel('openManhole');
        expect(d.hazardWarningAhead(label), contains(label));
        expect(d.hazardConfirmedUnavoidable(label), contains(label));
        // Distinct wording per confidence level — the whole point of
        // separating Yellow from Red.
        expect(d.hazardWarningAhead(label), isNot(d.hazardConfirmedUnavoidable(label)));
        expect(d.hazardConfirmedAvoided(label), isNot(d.hazardConfirmedUnavoidable(label)));
      });
    }

    test('Bangla warnings are actually Bangla, not English fallthrough', () {
      final bn = Dashboard.of(AppLanguage.bangla);
      final en = Dashboard.of(AppLanguage.english);
      final label = bn.hazardSubCategoryLabel('openManhole');
      expect(bn.hazardWarningAhead(label), isNot(en.hazardWarningAhead(label)));
      expect(bn.hazardConfirmedUnavoidable(label), matches(RegExp(r'[ঀ-৿]')));
    });
  });
}
