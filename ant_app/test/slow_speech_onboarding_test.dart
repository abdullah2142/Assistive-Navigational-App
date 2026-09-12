// "Sometimes speaking fast works, but being too slow turns the mic off."
//
// Reported against Part 1, answering the onboarding interview in Bangla once
// quickly and once slowly with long pauses mid-sentence — which the test plan
// itself describes as "how real people under stress talk", and which is the
// way this app's users are most likely to talk all the time.
//
// Both recognizer paths end a session on a mid-sentence pause, and it is worth
// being precise about why, because the obvious fix does not work:
//
//   - Cloud STT runs with `singleUtterance: false`, so it finalizes a
//     *segment* once the speaker stops. `SttService` treats the first
//     `isFinal: true` as the whole utterance and closes the session.
//   - The on-device recognizer hits its own `pauseFor`.
//
// Raising `pauseFor` cannot fix the cloud half: the server finalizes the
// fragment before that timer is ever reached. So "আমি ... একাই হাঁটি" said with
// a beat in the middle arrived as "আমি", matched nothing, and the screen
// apologised over the top of somebody who was still answering.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/onboarding/widgets/onboarding_voice.dart';

void main() {
  /// Drives `listenForVoiceChoice` against a script of utterances, one per
  /// listen session, and reports which choice was picked.
  Future<_Run> answer(List<String> utterances, {int maxAttempts = 8}) async {
    final stt = _ScriptedStt(utterances);
    final tts = _RecordingTts();
    String? picked;
    var attempts = 0;

    await listenForVoiceChoice(
      stt: stt,
      tts: tts,
      language: AppLanguage.bangla,
      retryHint: 'দুঃখিত, আবার বলুন',
      helpText: 'বিকল্পগুলি হল',
      choices: [
        OnboardingVoiceChoice(label: 'সাদা ছড়ি', synonyms: const ['ছড়ি'], onSelect: () => picked = 'whiteCane'),
        OnboardingVoiceChoice(label: 'হুইলচেয়ার', synonyms: const ['চেয়ার'], onSelect: () => picked = 'wheelchair'),
        OnboardingVoiceChoice(
          label: 'আমি সাহায্য ছাড়াই হাঁটি',
          synonyms: const ['একা', 'একাই', 'নিজে হাঁটি'],
          onSelect: () => picked = 'unassisted',
        ),
      ],
      // Bounded so a run that never matches still ends instead of looping.
      isCancelled: () => picked != null || ++attempts > maxAttempts,
    );

    return _Run(picked: picked, spoken: tts.spoken, sessions: stt.sessions);
  }

  test('a sentence broken by a pause is still one answer', () async {
    // The reported case. The recognizer finalizes "আমি" when the speaker
    // pauses, then "একাই হাঁটি" when they resume.
    final run = await answer(['আমি', 'একাই হাঁটি']);

    expect(run.picked, 'unassisted');
    expect(
      run.spoken,
      isEmpty,
      reason: 'it must not talk over somebody who is still part-way through '
          'their answer — that is what "turns the mic off" felt like',
    );
  });

  test('it listens on rather than apologising, and says so only when it gives up', () async {
    // Three fragments: two carried, and by then it has to speak.
    final run = await answer(['আমি', 'তো', 'জানি না ভাই', 'একাই হাঁটি']);
    expect(run.spoken, isNotEmpty, reason: 'past two continuations the user needs telling');
  });

  test('a fast, complete answer is not slowed down by any of this', () async {
    final run = await answer(['আমি একাই হাঁটি']);

    expect(run.picked, 'unassisted');
    expect(run.sessions, 1, reason: 'one listen, matched, done — no continuation window');
    expect(run.spoken, isEmpty);
  });

  test('silence is still answered with a prompt, not more silence', () async {
    // Nothing heard at all is not somebody mid-sentence — they need the
    // retry hint immediately, which is the behaviour testers confirmed works.
    final run = await answer(['', '', '']);
    expect(run.spoken, isNotEmpty);
    expect(run.picked, isNull);
  });

  test('a continuation listen does not sit through the full start-of-speech wait',
      () async {
    // Eight seconds is right for somebody gathering their thoughts before
    // answering. After they have already spoken it is just silence they wait
    // in before being told anything.
    final stt = _ScriptedStt(['আমি', 'একাই হাঁটি']);
    String? picked;
    var attempts = 0;
    await listenForVoiceChoice(
      stt: stt,
      tts: _RecordingTts(),
      language: AppLanguage.bangla,
      retryHint: 'আবার বলুন',
      choices: [
        OnboardingVoiceChoice(
            label: 'আমি সাহায্য ছাড়াই হাঁটি', synonyms: const ['একাই'], onSelect: () => picked = 'unassisted'),
      ],
      isCancelled: () => picked != null || ++attempts > 6,
    );

    expect(picked, 'unassisted');
    expect(stt.initialSilences.first, isNull, reason: 'the first listen keeps the generous default');
    expect(stt.initialSilences[1], isNotNull, reason: 'the continuation asks for a shorter one');
    expect(stt.initialSilences[1]!, lessThan(const Duration(seconds: 8)));
  });

  test('the fragments are joined in the order they were said', () async {
    // Stitched backwards this matches nothing, and worse, could match a
    // different option on some other question.
    final run = await answer(['নিজে', 'হাঁটি']);
    expect(run.picked, 'unassisted');
  });
}

class _Run {
  _Run({required this.picked, required this.spoken, required this.sessions});
  final String? picked;
  final List<String> spoken;
  final int sessions;
}

class _ScriptedStt extends SttService {
  _ScriptedStt(this._utterances);
  final List<String> _utterances;

  int sessions = 0;

  /// What each session was asked to wait for before any speech — the thing
  /// that decides how long a user sits in silence after a fragment.
  final List<Duration?> initialSilences = [];

  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
    Duration? initialSilence,
  }) async {
    initialSilences.add(initialSilence);
    if (sessions >= _utterances.length) {
      sessions++;
      return; // the script ran dry — a session that hears nothing
    }
    final utterance = _utterances[sessions++];
    onResult(utterance, true);
  }

  @override
  Future<void> stop() async {}
}

class _RecordingTts implements TtsService {
  final List<String> spoken = [];

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async => spoken.add(text);

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}
