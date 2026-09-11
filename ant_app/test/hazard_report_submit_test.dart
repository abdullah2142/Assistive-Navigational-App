// Item 27 — "hazard report kothao save hocche na", reported twice by the same
// tester. The report is composed, the flow completes, and nothing lands.
//
// Two unbounded waits sat in front of the write, and the symptom of either is
// identical from the outside: the button spins and nothing else ever happens.
//
//   1. `Geolocator.getCurrentPosition()` with no `timeLimit` waits forever for
//      a fix that may never arrive — indoors, services off, a permission
//      dialog nobody answered. The `catch` around it only covered a *thrown*
//      error. A hang stalled the submit before the write was attempted at all.
//      `EmergencyService._position` already knew this; the hub did not.
//
//   2. Firestore acknowledges a write when the *server* has it. With offline
//      persistence on — the default — the document is applied locally at once
//      and synced later, but the future stays pending the whole time. So a
//      report filed on a bad connection is genuinely saved and the user is
//      told nothing, forever.
//
// The second is what this file covers: a timeout there is not a failure and
// must not be reported as one.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/models/hazard_report.dart';
import 'package:ant_app/features/dashboard/providers/dashboard_providers.dart';
import 'package:ant_app/features/dashboard/services/hazard_report_service.dart';
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';

void main() {
  final d = Dashboard.of(AppLanguage.english);

  /// Pumps past every bound in the submit path.
  ///
  /// Both matter here, and the location one is not a formality: with no
  /// plugin behind the channel, `Geolocator.getCurrentPosition` never
  /// completes *or* throws. `LocationSettings.timeLimit` does not save it —
  /// that is enforced by the platform plugin, which is the thing not
  /// answering. Only the Dart-side `.timeout` ends this wait, and without it
  /// the write below is never reached at all. Confirmed by running this file
  /// against the unbounded version: the spinner appears, and nothing else
  /// ever happens.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  /// Opens the hub and taps through to the final step: a category, then a
  /// sub-category that is not "Other" (so no description is required).
  Future<_RecordingTts> reachSubmitStep(WidgetTester tester, HazardReportService service) async {
    final tts = _RecordingTts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hazardReportServiceProvider.overrideWithValue(service),
          ttsServiceProvider.overrideWithValue(tts),
          sttServiceProvider.overrideWithValue(_SilentStt()),
        ],
        child: const MaterialApp(
          home: CrowdsourceReportingHub(
            reporterUid: 'u1',
            language: AppLanguage.english,
            // Off: this is about the write, and auto-listen would put a
            // narrate-and-listen loop across every pump in the test.
            voiceAutoListen: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(d.hazardCategoryLabel(HazardCategory.roadHazard)));
    await tester.pump();

    final firstSub = d
        .hazardSubCategoryKeys(HazardCategory.roadHazard)
        .firstWhere((k) => !d.isOtherSubCategoryKey(k));
    await tester.tap(find.text(d.hazardSubCategoryLabel(firstSub)));
    await tester.pump();

    expect(find.text(d.crowdsourceSubmitButton), findsOneWidget);
    // Each step narrates itself on the way here. Cleared so every assertion
    // below is about what submitting said, and nothing else.
    tts.spoken.clear();
    return tts;
  }

  testWidgets('a report that is acknowledged says so', (tester) async {
    final service = _FakeHazardReports();
    final tts = await reachSubmitStep(tester, service);

    await tester.tap(find.text(d.crowdsourceSubmitButton));
    await settle(tester);

    expect(service.submitted, hasLength(1));
    expect(service.submitted.single.reporterUid, 'u1');
    expect(service.submitted.single.category, HazardCategory.roadHazard);
    expect(tts.spoken, contains(d.crowdsourceSubmitSuccess));
  });

  testWidgets('a write that is never acknowledged still tells the user it is saved',
      (tester) async {
    // Offline. The document is in the local cache and will sync; only the
    // confirmation is missing. Before this, the hub waited on it forever.
    final service = _FakeHazardReports(neverCompletes: true);
    final tts = await reachSubmitStep(tester, service);

    await tester.tap(find.text(d.crowdsourceSubmitButton));
    await tester.pump();

    // Past the location bound, so the write has been made, but not yet past
    // the acknowledgement bound.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(service.submitted, hasLength(1));
    expect(tts.spoken, isEmpty, reason: 'the acknowledgement deserves a fair chance first');

    await settle(tester);

    expect(service.submitted, hasLength(1), reason: 'the write was made, and is not retracted');
    expect(tts.spoken, contains(d.crowdsourceSubmitQueued));
    expect(
      tts.spoken.any((s) => s.contains("Couldn't submit")),
      isFalse,
      reason: 'a late acknowledgement is not a failed report, and saying so would be false',
    );
  });

  testWidgets('a write that is rejected is reported as the failure it is', (tester) async {
    // The other half: a rules rejection must still be surfaced, not quietly
    // folded into "saved".
    final service = _FakeHazardReports(failWith: 'permission-denied');
    final tts = await reachSubmitStep(tester, service);

    await tester.tap(find.text(d.crowdsourceSubmitButton));
    await settle(tester);

    expect(tts.spoken, hasLength(1));
    expect(tts.spoken.single, contains('permission-denied'));
    expect(tts.spoken, isNot(contains(d.crowdsourceSubmitQueued)));
    expect(find.text(d.crowdsourceSubmitButton), findsOneWidget,
        reason: 'the hub stays open so the report can be tried again');
  });
}

class _FakeHazardReports implements HazardReportService {
  _FakeHazardReports({this.neverCompletes = false, this.failWith});

  /// Stands in for an offline write: applied locally, never acknowledged.
  final bool neverCompletes;
  final String? failWith;

  final List<HazardReport> submitted = [];

  @override
  Future<void> submitReport(HazardReport report) {
    submitted.add(report);
    if (failWith != null) return Future.error(StateError(failWith!));
    if (neverCompletes) return Completer<void>().future;
    return Future<void>.value();
  }
}

class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}

class _SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
  }) async {}

  @override
  Future<void> stop() async {}
}
