// The multi-turn "where is that, exactly?" conversation.
//
// A user who cannot see a map does not name places the way a geocoder
// wants them named — "the eye hospital", "my daughter's school" — and
// Dhaka's informal addressing means even a real address often resolves to
// nothing. Before this, all of that produced one dead-end sentence. These
// tests walk the conversation that replaced it.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/destination_clarifier.dart';
import 'package:ant_app/core/services/routing_service.dart';

GeocodeCandidate place(String label, {double lat = 23.75, double lng = 90.38}) =>
    GeocodeCandidate(label: label, location: LatLng(lat, lng));

void main() {
  DestinationClarification pendingFor(String q) => DestinationClarification(originalQuery: q);

  ClarificationOutcome reply(
    String said,
    DestinationClarification pending, {
    AppLanguage language = AppLanguage.english,
  }) =>
      DestinationClarifier.interpret(reply: said, pending: pending, language: language);

  group('the original name is never thrown away', () {
    test('hints accumulate onto it across turns', () {
      var pending = pendingFor('the eye hospital');
      pending = pending.withHint('it is in Mirpur');
      pending = pending.withHint('near the big market');

      expect(pending.originalQuery, 'the eye hospital');
      expect(pending.combinedQuery, 'the eye hospital, it is in Mirpur, near the big market');
      expect(pending.attempts, 2);
    });
  });

  group('interpreting the follow-up', () {
    test('anything descriptive is taken as the answer to the question asked', () {
      // The default reading has to be "this is the answer" — the assistant
      // just asked, so treating a reply as unparseable is almost always
      // wrong.
      final outcome = reply('it is in Mirpur', pendingFor('the clinic'));
      expect(outcome, isA<ClarificationRefined>());
      expect((outcome as ClarificationRefined).updated.combinedQuery, 'the clinic, it is in Mirpur');
    });

    test('the user can always get out', () {
      for (final said in ['cancel', 'never mind', 'forget it', 'stop', 'বাদ দাও', 'থাক']) {
        expect(reply(said, pendingFor('x')), isA<ClarificationCancelled>(), reason: '"$said"');
      }
    });

    test('an empty reply is not treated as an answer', () {
      expect(reply('   ', pendingFor('x')), isA<ClarificationUnclear>());
    });

    test('once attempts run out it stops refining', () {
      var pending = pendingFor('somewhere');
      for (var i = 0; i < DestinationClarification.maxAttempts; i++) {
        pending = pending.withHint('more detail');
      }
      expect(pending.isExhausted, isTrue);
      expect(reply('and more detail', pending), isA<ClarificationUnclear>());
    });
  });

  group('choosing between offered places', () {
    final options = [
      place('Ibn Sina Hospital, Dhanmondi, Dhaka', lat: 23.74),
      place('Square Hospital, Panthapath, Dhaka', lat: 23.75),
      place('Popular Diagnostic, Shyamoli, Dhaka', lat: 23.77),
    ];
    final offering = pendingFor('the hospital').offering(options);

    test('by position, because a spoken list cannot be tapped', () {
      expect((reply('the first one', offering) as ClarificationResolved).candidate.label,
          startsWith('Ibn Sina'));
      expect((reply('number two', offering) as ClarificationResolved).candidate.label,
          startsWith('Square'));
      expect((reply('third', offering) as ClarificationResolved).candidate.label,
          startsWith('Popular'));
    });

    test('by name', () {
      expect((reply('square hospital', offering) as ClarificationResolved).candidate.label,
          startsWith('Square'));
      expect((reply('the one in shyamoli', offering) as ClarificationResolved).candidate.label,
          startsWith('Popular'));
    });

    test('Bangla numerals pick an option', () {
      // A bn-BD recognizer transcribes a spoken numeral as "দুই" far more
      // often than as "২", so a bare cardinal has to work.
      for (final said in ['দুই', '২', 'দ্বিতীয়', 'নম্বর দুই']) {
        expect(
          (reply(said, offering, language: AppLanguage.bangla) as ClarificationResolved)
              .candidate.label,
          startsWith('Square'),
          reason: '"$said"',
        );
      }
    });

    test('a bare cardinal alone chooses, but inside a sentence it does not', () {
      // "two" on its own can only be a choice. "two roads down from the
      // market" is a landmark hint, and reading it as option 2 walks the
      // user somewhere they never chose.
      expect((reply('two', offering) as ClarificationResolved).candidate.label,
          startsWith('Square'));
      expect(reply('two roads down from the market', offering), isA<ClarificationRefined>());
      expect(reply('দুই নম্বর গেটের কাছে', offering, language: AppLanguage.bangla),
          isA<ClarificationRefined>());
    });

    test('a reply that matches nothing refines instead of failing', () {
      // "No, the one near my house" is the user narrowing, not choosing.
      final outcome = reply('no, the one near my house', offering);
      expect(outcome, isA<ClarificationRefined>());
    });
  });

  group('offering options', () {
    test('the same place returned twice is not a choice', () {
      // Geocoders routinely return a building and its own entrance as
      // separate rows; asking the user to choose between them is asking a
      // question with no meaningful answer.
      final collapsed = DestinationClarifier.distinctOptions([
        place('Square Hospital', lat: 23.7500, lng: 90.3800),
        place('Square Hospital main gate', lat: 23.7501, lng: 90.3801),
        place('Ibn Sina Hospital', lat: 23.7400, lng: 90.3700),
      ]);
      expect(collapsed, hasLength(2));
    });

    test('never offers more than three', () {
      final many = [
        for (var i = 0; i < 8; i++) place('Place $i', lat: 23.70 + i * 0.01),
      ];
      expect(DestinationClarifier.distinctOptions(many), hasLength(3));
    });

    test('spoken labels are shortened to something listenable', () {
      // Geocoders return long hierarchies; reading the whole chain aloud
      // for each of three options is unusable.
      final long = place('Ibn Sina Hospital, Road 9/A, Dhanmondi, Dhaka, 1209, Bangladesh');
      expect(long.spokenLabel, 'Ibn Sina Hospital, Road 9/A');
    });
  });

  group('what the assistant actually says', () {
    for (final language in AppLanguage.values) {
      final d = Dashboard.of(language);

      test('${language.name}: each round asks for a different kind of clue', () {
        // A user who could answer "where is it?" would have answered it the
        // first time. Repeating the same question is how this becomes a trap.
        expect(d.clarifyAskArea('the clinic'), isNot(d.clarifyAskLandmark('the clinic')));
        expect(d.clarifyAskArea('the clinic'), contains('the clinic'));
        expect(d.clarifyAskLandmark('the clinic'), contains('the clinic'));
      });

      test('${language.name}: options are numbered so they can be chosen by voice', () {
        final asked = d.clarifyChooseOption(['Ibn Sina', 'Square', 'Popular']);
        expect(asked, contains('Ibn Sina'));
        expect(asked, contains('Square'));
        expect(asked, contains('Popular'));
      });

      test('${language.name}: giving up ends with something the user can do', () {
        // "Sorry, I failed" is worthless to someone standing on a footpath.
        final text = d.clarifyGaveUp('the clinic');
        expect(text.length, greaterThan(60));
        expect(text, contains('the clinic'));
      });
    }

    test('Bangla clarification is actually Bangla', () {
      final bn = Dashboard.of(AppLanguage.bangla);
      expect(bn.clarifyAskArea('x'), matches(RegExp(r'[ঀ-৿]')));
      expect(bn.clarifyAskLandmark('x'), matches(RegExp(r'[ঀ-৿]')));
      expect(bn.clarifyGaveUp('x'), matches(RegExp(r'[ঀ-৿]')));
      expect(bn.clarifyChooseOption(['a', 'b']), matches(RegExp(r'[ঀ-৿]')));
    });
  });

  test('a full three-round conversation converges or gives up cleanly', () {
    var pending = pendingFor('the eye hospital');
    expect(pending.isExhausted, isFalse);

    // Round 1: user names an area.
    pending = (reply('Mirpur', pending) as ClarificationRefined).updated;
    expect(pending.combinedQuery, 'the eye hospital, Mirpur');
    expect(pending.isExhausted, isFalse);

    // Round 2: user names a landmark.
    pending = (reply('near Mirpur 10 roundabout', pending) as ClarificationRefined).updated;
    expect(pending.combinedQuery, contains('roundabout'));

    // Round 3: still nothing — this is the last question.
    pending = (reply('it is a white building', pending) as ClarificationRefined).updated;
    expect(pending.isExhausted, isTrue);

    // Anything further stops the conversation rather than looping forever.
    expect(reply('are you sure', pending), isA<ClarificationUnclear>());
  });
}
