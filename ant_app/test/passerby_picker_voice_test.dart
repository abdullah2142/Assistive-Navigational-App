// Show Screen's voice flow: say what the screen is for, then open the mic —
// and never leave "show it" with nowhere to go.
//
// Both reported from the device on 10 September. The sheet opened the
// microphone immediately and narrated nothing, so the user heard a listening
// buzz with no idea what to say into it — and the chat's own "Showing your
// screen now." was still playing, which ducked the recorder that had just
// opened:
//
//   02:19:13.467  [CloudStt] continuous listening started
//   02:19:13.545  audioplayers requestAudioFocus req=3
//   02:19:13.564  onAudioFocusChange(-3) -> record
//
// `record` treats a duck as a full focus loss and its default mode pauses
// without resuming, so the message spoken into that session never arrived.
// With nothing committed, saying "show it" submitted nothing and the loop
// replayed the identical prompt — "it loops on, telling me it got it and i
// should say show it".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/providers/ai_assistant_providers.dart';
import 'package:ant_app/core/providers/tts_providers.dart';
import 'package:ant_app/core/services/stt_service.dart';
import 'package:ant_app/core/services/tts_service.dart';
import 'package:ant_app/features/dashboard/widgets/passerby_message_picker.dart';

void main() {
  final d = Dashboard.of(AppLanguage.english);

  /// Opens the picker with a scripted set of spoken utterances, one per
  /// listen session.
  Future<_Recorder> openPicker(WidgetTester tester, List<String> utterances) async {
    final rec = _Recorder(utterances);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sttServiceProvider.overrideWithValue(rec.stt),
          ttsServiceProvider.overrideWithValue(rec.tts),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => PasserbyMessagePicker.show(
                  context,
                  messages: const ['I need help crossing the road'],
                  strings: d,
                  language: AppLanguage.english,
                  autoListen: true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Each turn of the loop waits out `SttService.narrationSettle` before
    // opening the microphone — a real timer, which `pumpAndSettle` does not
    // advance on its own. Pump through enough of them for the whole script.
    for (var i = 0; i < 8; i++) {
      await tester.pump(SttService.narrationSettle);
      await tester.pumpAndSettle();
    }
    return rec;
  }

  testWidgets('says what the screen is for before opening the microphone', (tester) async {
    final rec = await openPicker(tester, ['I need help crossing the road', 'show it']);

    // The intro has to be the first thing that happens, and it has to be
    // finished before the recorder opens — otherwise it ducks it.
    expect(rec.events.first, 'speak: ${d.passerbyPickerIntroSpoken}');
    final firstListen = rec.events.indexWhere((e) => e.startsWith('listen'));
    final intro = rec.events.indexOf('speak: ${d.passerbyPickerIntroSpoken}');
    expect(intro, lessThan(firstListen), reason: 'narrate first, listen second');
  });

  testWidgets('the intro says both what it does and what to say', (tester) async {
    // A user who cannot see the sheet has no other way to find out.
    expect(d.passerbyPickerIntroSpoken, contains('read it'));
    expect(d.passerbyPickerIntroSpoken, contains('show it'));
    await openPicker(tester, ['hello', 'show it']);
  });

  testWidgets('"show it" with nothing dictated says what is missing, once', (tester) async {
    // The reported loop: submit phrase recognized, nothing to submit, and
    // the identical prompt replayed forever.
    final rec = await openPicker(tester, ['show it', 'show it', 'hello there', 'show it']);

    final spoken = rec.events.where((e) => e.startsWith('speak: ')).toList();
    expect(
      spoken.where((e) => e.contains(d.passerbyPickerNothingToShowSpoken)),
      isNotEmpty,
      reason: 'it has to say what is actually missing',
    );

    // And not stack the generic prompt on top of it in the same turn.
    final nothingAt = spoken.indexWhere((e) => e.contains(d.passerbyPickerNothingToShowSpoken));
    expect(
      spoken[nothingAt + 1].contains(d.passerbyPickerContinueOrShowSpoken),
      isFalse,
      reason: 'two instructions for one turn is how the loop read',
    );
  });

  testWidgets('a dictated message followed by "show it" actually shows it', (tester) async {
    final rec = await openPicker(tester, ['I need help crossing the road', 'show it']);

    // Submitting reads the message back with a cancel window before it goes
    // full-screen — so the message appearing in what is spoken *after* the
    // submit phrase is the evidence that it was accepted.
    final spoken = rec.events.where((e) => e.startsWith('speak: ')).toList();
    expect(
      spoken.last,
      allOf(contains('I need help crossing the road'), contains('cancel')),
      reason: 'the dictated message has to reach the read-back, not the submit phrase',
    );
    // And "show it" must not be part of the message itself.
    expect(spoken.last.toLowerCase(), isNot(contains('road. show it')));
  });
}

/// Records the ordering of every spoken utterance and listen session, and
/// feeds the picker a scripted transcript per session.
class _Recorder {
  _Recorder(this._utterances) {
    stt = _ScriptedStt(this);
    tts = _RecordingTts(this);
  }

  final List<String> _utterances;
  final List<String> events = [];
  late final _ScriptedStt stt;
  late final _RecordingTts tts;
  int _next = 0;

  String? take() => _next < _utterances.length ? _utterances[_next++] : null;
}

class _ScriptedStt extends SttService {
  _ScriptedStt(this._rec);
  final _Recorder _rec;

  @override
  Future<bool> ensureAvailable() async => true;

  @override
  Future<void> listenOnce({
    required AppLanguage language,
    required void Function(String text, bool isFinal) onResult,
    Duration pauseFor = const Duration(seconds: 3),
    Duration listenFor = const Duration(minutes: 5),
  }) async {
    final utterance = _rec.take();
    _rec.events.add('listen: ${utterance ?? "<silence>"}');
    if (utterance == null) return;
    onResult(utterance, true);
  }

  @override
  Future<void> stop() async {}
}

class _RecordingTts implements TtsService {
  _RecordingTts(this._rec);
  final _Recorder _rec;

  @override
  Future<void> speak(String text, {AppLanguage language = AppLanguage.english}) async {
    _rec.events.add('speak: $text');
  }

  @override
  Future<void> stop() async {}

  @override
  void setVoiceId(String voiceId) {}
}
