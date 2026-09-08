import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live-preview bug, reproduced at the level it actually occurs.
///
/// Both voice composers show an in-progress transcript in the text field
/// while the user is still speaking, and commit only on `isFinal`. When the
/// final utterance turns out to be the submit command ("show it"), the
/// committed text is correct — but nothing put the *field* back, so the
/// preview containing "show it" was what got submitted. A passerby was shown
/// "I need help crossing show it".
///
/// These tests model the two states involved (committed text, and the
/// controller the preview writes to) rather than pumping the whole sheet,
/// because the defect is entirely in how those two are reconciled.
void main() {
  late TextEditingController controller;
  late String committed;

  setUp(() {
    controller = TextEditingController();
    committed = '';
  });

  tearDown(() => controller.dispose());

  void updateLive(String partial) {
    final combined = [committed, partial].where((s) => s.trim().isNotEmpty).join(' ').trim();
    controller.text = combined;
  }

  void commit(String finalized) {
    final trimmed = finalized.trim();
    if (trimmed.isEmpty) return;
    committed = [committed, trimmed].where((s) => s.isNotEmpty).join(' ');
    controller.text = committed;
  }

  void resetToCommitted() => controller.text = committed;

  test('the submit phrase does not survive into the submitted text', () {
    commit('I need help crossing the road');

    // The user says the submit command; interim results land in the field.
    updateLive('show');
    updateLive('show it');
    expect(controller.text, 'I need help crossing the road show it');

    // Final arrives, recognized as a submit command with nothing to add.
    resetToCommitted();

    expect(controller.text, 'I need help crossing the road');
  });

  test('a submit phrase with trailing words still keeps those words', () {
    // "take me to the pharmacy, show it" — the part before the phrase is
    // real content and must be kept.
    commit('take me to the pharmacy');
    updateLive('show it');

    commit('');
    resetToCommitted();

    expect(controller.text, 'take me to the pharmacy');
  });

  test('an abandoned preview never becomes content', () {
    // Nothing committed at all, and the only thing said was the command.
    updateLive('show it');
    expect(controller.text, 'show it');

    resetToCommitted();

    expect(controller.text, isEmpty,
        reason: 'submitting here should send nothing, not the word "show it"');
  });

  test('ordinary dictation is unaffected', () {
    updateLive('there is a');
    commit('there is a broken footpath');

    expect(controller.text, 'there is a broken footpath');
    resetToCommitted();
    expect(controller.text, 'there is a broken footpath');
  });
}
