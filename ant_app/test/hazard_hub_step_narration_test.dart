// Item 30 — the hazard hub reads the previous step's instructions on the
// next step.
//
// Tester D, with a repro at last: "Report a hazard er por crime jodi manually
// select kora hoy, tarpor toh 2nd page ashe. Ei page eo 1st page er
// instructions repeat hocche." Report a hazard, pick the category **by tap**,
// and the sub-category page reads the category page's instructions out.
//
// By tap is the whole point. Answering by *voice* means waiting for the
// prompt to finish — the hub narrates, then listens — so there is nothing
// left playing when the step changes. A tap can land in the middle of it.
//
// `_narrateAndListenForStep` bumped `_stepGeneration` and stopped the
// recognizer, but never the narrator. `TtsService` deliberately *queues*
// utterances rather than dropping them, so the interrupted category prompt
// kept its place at the head of the queue, played to the end, and the
// sub-category prompt came out behind it. The generation guard could not help:
// it gates what the *step logic* does next, not what the narrator has already
// accepted.

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
import 'package:ant_app/features/dashboard/widgets/crowdsource_reporting_hub.dart';

void main() {
  final d = Dashboard.of(AppLanguage.english);
  final categoryPrompt =
      d.crowdsourceCategoryPrompt(HazardCategory.values.map(d.hazardCategoryLabel).join(', '));

  Future<_QueueingTts> openHub(WidgetTester tester) async {
    final tts = _QueueingTts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ttsServiceProvider.overrideWithValue(tts),
          sttServiceProvider.overrideWithValue(_SilentStt()),
        ],
        child: const MaterialApp(
          home: CrowdsourceReportingHub(
            reporterUid: 'u1',
            language: AppLanguage.english,
            voiceAutoListen: true,
          ),
        ),
      ),
    );
    await tester.pump(); // runs the post-frame callback that starts narration
    return tts;
  }

  testWidgets('a category tapped mid-narration cuts that narration off', (tester) async {
    final tts = await openHub(tester);

    // Part-way through the category prompt — started, nowhere near done.
    await tester.pump(const Duration(milliseconds: 300));
    expect(tts.started, [categoryPrompt], reason: 'the first step narrates on open');
    expect(tts.finished, isEmpty, reason: 'and is still talking when the user taps');

    await tester.tap(find.text(d.hazardCategoryLabel(HazardCategory.crime)));
    await tester.pump();

    // Long enough for anything queued to have played several times over.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(
      tts.finished,
      isNot(contains(categoryPrompt)),
      reason: 'the category prompt must not play on to the end on the next page — '
          'that is the reported bug',
    );
  });

  testWidgets('the next step is what the user actually hears', (tester) async {
    final tts = await openHub(tester);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text(d.hazardCategoryLabel(HazardCategory.crime)));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    final subCategoryPrompt = d.crowdsourceSubCategoryPrompt(
      d.hazardCategoryLabel(HazardCategory.crime),
      d.hazardSubCategoryKeys(HazardCategory.crime).map(d.hazardSubCategoryLabel).join(', '),
    );
    expect(tts.finished, contains(subCategoryPrompt),
        reason: 'the step they moved to still has to introduce itself');
    // And it must not be queued behind the abandoned one.
    expect(tts.started.indexOf(subCategoryPrompt), greaterThan(tts.started.indexOf(categoryPrompt)));
  });

  testWidgets('narration that was left alone still plays in full', (tester) async {
    // The guard above must not turn into "never finish a sentence". With no
    // tap at all, the category prompt is heard to the end — which is what a
    // user answering by voice depends on.
    final tts = await openHub(tester);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tts.finished, contains(categoryPrompt));
  });
}

/// Models [TtsService]'s real queueing: utterances are chained, not dropped,
/// and `stop()` bumps a generation that abandons whatever is waiting behind
/// it. A fake that simply recorded `speak` calls would show nothing wrong
/// here — the hub *does* ask for the right text. What went wrong is what
/// reached the speaker, and in what order.
class _QueueingTts implements TtsService {
  /// How long an utterance takes to say. Real prompts here are option lists
  /// several seconds long, which is what makes the window wide enough to tap
  /// inside.
  static const _utterance = Duration(seconds: 2);

  final List<String> started = [];
  final List<String> finished = [];

  Future<void> _chain = Future<void>.value();
  int _generation = 0;

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) {
    final myGeneration = _generation;
    final next = _chain.then((_) async {
      if (myGeneration != _generation) return; // abandoned while queued
      started.add(text);
      await Future<void>.delayed(_utterance);
      if (myGeneration != _generation) return; // cut off mid-sentence
      finished.add(text);
    });
    _chain = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> stop() async => _generation++;

  @override
  void setVoiceId(String voiceId) {}
}

/// Never hears anything, so every listen window closes on its own and the
/// step only ever advances by tap.
class _SilentStt extends SttService {
  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
    List<String> phraseHints = const [],
  }) async {}

  @override
  Future<void> stop() async {}
}
