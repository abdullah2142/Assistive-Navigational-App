// Working out which Dhaka bus the camera is looking at.
//
// This file exists because the first design was wrong in a way no test would
// have caught, since it was built against a signboard I invented. Checked
// against a real dataset of 156 Dhaka operators: **7 have a number in the
// name, 149 do not.** The signboard says `আছিম পরিবহন`, not `6`.
//
// So the identifier is Bangla conjunct text — precisely what OCR corrupts,
// measured on this project as `গুলশান` -> `ঠানশান` — with no digit to fall
// back on. Every test below is about whether a *misread* name still lands on
// the right operator.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/vision/bus_route_directory.dart';

/// A slice of the real directory, names copied verbatim from the dataset.
///
/// Real names rather than invented ones on purpose: the whole question is
/// whether 156 *actual* Dhaka operator names are far enough apart in edit
/// distance to tell apart after OCR damage, and made-up names would quietly
/// answer an easier question.
final _directory = [
  const BusRoute(
    id: 'achim-paribahan',
    nameEn: 'Achim Paribahan',
    nameBn: 'আছিম পরিবহন',
    stops: ['Gabtoli', 'Technical', 'Mirpur 1', 'Mirpur 10', 'Kalshi', 'Badda', 'Banasree'],
  ),
  const BusRoute(
    id: 'agradut',
    nameEn: 'Agradut',
    nameBn: 'অগ্রদূত',
    stops: ['Mirpur 12', 'Mirpur 10', 'Farmgate', 'Motijheel'],
  ),
  const BusRoute(
    id: 'akash-enterprise',
    nameEn: 'Akash Enterprise',
    nameBn: 'আকাশ বাস',
    stops: ['Uttara', 'Airport', 'Banani', 'Gulshan 1'],
  ),
  const BusRoute(
    id: 'akik',
    nameEn: 'Akik',
    nameBn: 'আকিক বাস',
    stops: ['Savar', 'Gabtoli', 'Farmgate'],
  ),
  const BusRoute(
    id: '6-no-dhaka',
    nameEn: '6 No. Dhaka',
    nameBn: '৬নং বাস',
    routeNumber: '6',
    stops: ['Mirpur 10', 'Farmgate', 'Gulshan 2'],
  ),
];

BusRouteDirectory _dir() => BusRouteDirectory(seed: _directory);

void main() {
  group('a number, when the bus actually has one', () {
    test('matches outright', () async {
      final m = await _dir().identify(routeNumber: '6');
      expect(m?.route.id, '6-no-dhaka');
      expect(m?.why, 'number');
      expect(m?.score, 1);
    });

    test('a Bangla numeral reaches the same route', () async {
      // `VisionPrompt.normaliseDigits` folds ৬ to 6 before this is called;
      // this pins that the directory agrees about what it is given.
      final m = await _dir().identify(routeNumber: '6', readText: '৬নং বাস');
      expect(m?.route.id, '6-no-dhaka');
    });

    test('a number two operators share falls through to the name', () async {
      // Real in the dataset: `6 No. Dhaka` and `6 No. Motijheel Banani
      // Transport Dhaka` both carry 6 and share all eighteen stops. Picking
      // the first would speak the wrong name half the time.
      final shared = BusRouteDirectory(seed: [
        ..._directory,
        const BusRoute(
          id: '6-no-motijheel-banani',
          nameEn: '6 No. Motijheel Banani Transport Dhaka',
          nameBn: '৬নং মতিঝিল বনানী ট্রান্সপোর্ট বাস',
          routeNumber: '6',
          stops: ['Mirpur 10', 'Farmgate', 'Gulshan 2'],
        ),
      ]);
      final m = await shared.identify(
        routeNumber: '6',
        readText: '৬নং মতিঝিল বনানী ট্রান্সপোর্ট বাস',
      );
      expect(m?.route.id, '6-no-motijheel-banani');
      expect(m?.why, isNot('number'), reason: 'the number could not decide it');
    });

    test('a number nobody runs does not become a wrong bus', () async {
      // Falls through to name matching, finds nothing like it, says nothing.
      // Naming the wrong bus to someone who cannot read the board is how they
      // end up on it.
      final m = await _dir().identify(routeNumber: '99');
      expect(m, isNull);
    });
  });

  group('names, read perfectly', () {
    test('Bangla name matches', () async {
      final m = await _dir().identify(readText: 'আছিম পরিবহন');
      expect(m?.route.id, 'achim-paribahan');
    });

    test('English name matches', () async {
      final m = await _dir().identify(readText: 'Achim Paribahan');
      expect(m?.route.id, 'achim-paribahan');
    });

    test('a name embedded in a full signboard read matches', () async {
      // What a real board looks like: the operator name surrounded by places.
      final m = await _dir().identify(
        readText: 'আছিম পরিবহন গাবতলী মিরপুর ১০ বাড্ডা',
      );
      expect(m?.route.id, 'achim-paribahan');
    });
  });

  group('names, read badly — the case this exists for', () {
    test('a one-character slip still lands on the right operator', () async {
      // The exact damage measured on this project: one Bangla character
      // replaced by a visually similar one.
      final m = await _dir().identify(readText: 'আছিন পরিবহন');
      expect(m?.route.id, 'achim-paribahan');
    });

    test('a two-character slip still lands', () async {
      final m = await _dir().identify(readText: 'আছিন পরিবহণ');
      expect(m?.route.id, 'achim-paribahan');
    });

    test('a damaged name plus a correct stop is stronger than either', () async {
      final m = await _dir().identify(
        readText: 'আছিন পরিবহন',
        readStops: ['Mirpur 10', 'Badda'],
      );
      expect(m?.route.id, 'achim-paribahan');
      expect(m?.why, 'name+stops',
          reason: 'two independent signals agreeing is the point');
    });

    test('a badly damaged English name still lands', () async {
      final m = await _dir().identify(readText: 'Akash Enterprize');
      expect(m?.route.id, 'akash-enterprise');
    });
  });

  group('refusing to guess', () {
    test('text resembling no operator returns nothing', () async {
      final m = await _dir().identify(readText: 'ঢাকা মেট্রো রেল স্টেশন');
      expect(m, isNull, reason: 'silence beats naming a bus that is not there');
    });

    test('empty input returns nothing', () async {
      expect(await _dir().identify(readText: ''), isNull);
      expect(await _dir().identify(), isNull);
    });

    test('an empty directory returns nothing rather than throwing', () async {
      // The live state until `busRoutes` is seeded. It must degrade to "I
      // read this text" rather than taking the scan down.
      final empty = BusRouteDirectory(seed: const []);
      expect(await empty.identify(readText: 'আছিম পরিবহন'), isNull);
    });

    test('two similar operators do not silently swap', () async {
      // `আকাশ বাস` and `আকিক বাস` share a word and differ by two characters —
      // the tightest pair in this sample, and the one most likely to be
      // confused. Whichever wins must be the one actually read.
      final akash = await _dir().identify(readText: 'আকাশ বাস');
      final akik = await _dir().identify(readText: 'আকিক বাস');
      expect(akash?.route.id, 'akash-enterprise');
      expect(akik?.route.id, 'akik');
    });
  });

  group('ambiguity is reported, not guessed away', () {
    // The dataset carries nine documents named `বি আর টিসি বাস`, running
    // corridors from Madanpur-Savar to Motijheel-Tongi. The name on the board
    // cannot separate them.
    final brtc = BusRouteDirectory(seed: [
      const BusRoute(
        id: 'brtc-1', nameEn: 'BRTC', nameBn: 'বি আর টিসি বাস',
        stops: ['Madanpur', 'Jatrabari', 'Savar'],
      ),
      const BusRoute(
        id: 'brtc-2', nameEn: 'BRTC', nameBn: 'বি আর টিসি বাস',
        stops: ['Motijheel', 'Farmgate', 'Tongi'],
      ),
      ..._directory,
    ]);

    test('a name shared by several corridors is matched but not trusted '
        'for a destination', () async {
      final m = await brtc.identify(readText: 'বি আর টিসি বাস');
      expect(m, isNotNull);
      expect(m!.route.nameBn, 'বি আর টিসি বাস', reason: 'the operator is known');
      expect(m.destinationCertain, isFalse,
          reason: 'which BRTC route this is cannot be known from the name');
    });

    test('a read destination picks the right corridor and restores certainty',
        () async {
      final m = await brtc.identify(
        readText: 'বি আর টিসি বাস',
        readStops: ['Motijheel', 'Tongi'],
      );
      expect(m?.route.id, 'brtc-2');
      expect(m?.destinationCertain, isTrue);
    });

    test('stops alone do not promote an operator that serves the same road',
        () async {
      // Dozens of Dhaka operators serve Mirpur 10. A shared stop must not
      // outweigh the name, or every scan near Mirpur names the wrong bus.
      final m = await _dir().identify(
        readText: 'আছিম পরিবহন',
        readStops: ['Mirpur 10'],
      );
      expect(m?.route.id, 'achim-paribahan');
    });
  });

  group('normalisation', () {
    test('folds Bangla digits to ASCII', () {
      expect(BusRouteDirectory.normalise('৬নং'), contains('6'));
    });

    test('strips punctuation and collapses whitespace', () {
      expect(BusRouteDirectory.normalise('  Achim,   Paribahan!  '),
          'achim paribahan');
    });

    test('keeps Bangla letterforms intact', () {
      expect(BusRouteDirectory.normalise('আছিম পরিবহন'), 'আছিম পরিবহন');
    });
  });
}
