// Where the app sends someone who has just pressed the emergency button.
// The ranking is deliberately not "nearest" — these tests exist to stop
// somebody later "fixing" it into a distance sort.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:ant_app/core/localization/app_language.dart';
import 'package:ant_app/core/localization/dashboard_strings.dart';
import 'package:ant_app/core/services/safe_haven_finder.dart';
import 'package:ant_app/features/onboarding/models/saved_place.dart';

void main() {
  // Dhanmondi 27, roughly.
  const here = LatLng(23.7461, 90.3742);

  SavedPlace place(String label, SavedPlaceKind kind, double lat, double lng) =>
      SavedPlace(label: label, kind: kind, address: label, lat: lat, lng: lng);

  // ~600 m north, ~200 m north, ~2 km east.
  const near = LatLng(23.7479, 90.3742);
  const far = LatLng(23.7515, 90.3742);
  const veryFar = LatLng(23.7461, 90.3942);

  group('familiarity outranks proximity', () {
    test('a known home beats a nearer unknown hospital', () {
      // The whole point. Somebody frightened and blind does not want to
      // arrive alone at the gate of a hospital they have never been to.
      final best = SafeHavenFinder.best(
        origin: here,
        savedPlaces: [place('Home', SavedPlaceKind.home, far.latitude, far.longitude)],
        discovered: [
          const SafeHaven(label: 'City Hospital', source: HavenSource.discovered, location: near),
        ],
      );
      expect(best?.label, 'Home');
      expect(best?.source, HavenSource.savedPlace);
    });

    test('the stated safe place still beats a discovered one', () {
      final best = SafeHavenFinder.best(
        origin: here,
        savedPlaces: const [],
        statedSafePlace: 'Dhanmondi 27 pharmacy',
        discovered: [
          const SafeHaven(label: 'City Hospital', source: HavenSource.discovered, location: near),
        ],
      );
      expect(best?.source, HavenSource.statedSafePlace);
      expect(best?.label, 'Dhanmondi 27 pharmacy');
    });

    test('within a tier, distance decides', () {
      final best = SafeHavenFinder.best(
        origin: here,
        savedPlaces: [
          place('Home', SavedPlaceKind.home, far.latitude, far.longitude),
          place("Ma's house", SavedPlaceKind.family, near.latitude, near.longitude),
        ],
      );
      expect(best?.label, "Ma's house");
    });
  });

  group('what counts as a refuge', () {
    test('work and school are not refuges', () {
      // Places you go, not places you retreat to — and locked at 2am.
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: [
          place('Office', SavedPlaceKind.work, near.latitude, near.longitude),
          place('University', SavedPlaceKind.school, near.latitude, near.longitude),
          place('Home', SavedPlaceKind.home, far.latitude, far.longitude),
        ],
      );
      expect(ranked.map((h) => h.label), ['Home']);
    });

    test('a mosque is', () {
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: [place('Masjid', SavedPlaceKind.worship, near.latitude, near.longitude)],
      );
      expect(ranked.single.label, 'Masjid');
    });

    test('a saved place with only an address is kept, not crashed on', () {
      // isRoutable is true for coordinates OR an address, so it cannot be
      // used as a has-coordinates test. Reading lat! behind it threw a null
      // check — a crash in the middle of an emergency.
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: const [
          SavedPlace(label: 'Home', kind: SavedPlaceKind.home, address: 'Dhanmondi 27'),
        ],
      );
      expect(ranked.single.label, 'Home');
      expect(ranked.single.location, isNull);
      expect(ranked.single.address, 'Dhanmondi 27');
    });

    test('a place with coordinates outranks one with only an address', () {
      // Same familiarity, but one of them still works with no network.
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: [
          const SavedPlace(label: 'Ma', kind: SavedPlaceKind.family, address: 'Mirpur'),
          place('Home', SavedPlaceKind.home, far.latitude, far.longitude),
        ],
      );
      expect(ranked.map((h) => h.label), ['Home', 'Ma']);
    });

    test('a place with neither is dropped entirely', () {
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: const [SavedPlace(label: 'Nowhere', kind: SavedPlaceKind.home, address: '  ')],
      );
      expect(ranked, isEmpty);
    });
  });

  group('discovered places are bounded', () {
    test('anything past a kilometre is not offered', () {
      // Someone frightened is not walking 2 km to a place they do not know,
      // and offering it crowds out the honest answer: stay put.
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: const [],
        discovered: [
          const SafeHaven(label: 'Far Hospital', source: HavenSource.discovered, location: veryFar),
        ],
      );
      expect(ranked, isEmpty);
      expect(SafeHavenFinder.metresBetween(here, veryFar), greaterThan(1000));
    });

    test('inside the radius they are offered, nearest first', () {
      final ranked = SafeHavenFinder.rank(
        origin: here,
        savedPlaces: const [],
        discovered: [
          const SafeHaven(label: 'Further', source: HavenSource.discovered, location: far),
          const SafeHaven(label: 'Nearer', source: HavenSource.discovered, location: near),
        ],
      );
      expect(ranked.map((h) => h.label), ['Nearer', 'Further']);
    });
  });

  group('nowhere to go is a real answer', () {
    test('no places and nothing nearby returns null', () {
      // Inventing a destination would be worse than admitting there is
      // none — the contacts already know where they are.
      expect(
        SafeHavenFinder.best(origin: here, savedPlaces: const []),
        isNull,
      );
    });

    test('an empty stated place is not a haven', () {
      expect(
        SafeHavenFinder.best(origin: here, savedPlaces: const [], statedSafePlace: '   '),
        isNull,
      );
    });
  });

  group('the offline answer', () {
    test('bearings point the way you would expect', () {
      expect(SafeHavenFinder.bearingDegrees(here, far), closeTo(0, 1)); // due north
      expect(
        SafeHavenFinder.bearingDegrees(here, const LatLng(23.7461, 90.3842)),
        closeTo(90, 1), // due east
      );
    });

    test('compass index maps onto eight points, wrapping at north', () {
      expect(SafeHavenFinder.compassIndex(0), 0);
      expect(SafeHavenFinder.compassIndex(45), 1);
      expect(SafeHavenFinder.compassIndex(90), 2);
      expect(SafeHavenFinder.compassIndex(315), 7);
      // 350 degrees is north, not north-west — the wrap must not fall off.
      expect(SafeHavenFinder.compassIndex(350), 0);
      expect(SafeHavenFinder.compassIndex(359.9), 0);
    });

    test('every bearing has a name, in both languages', () {
      for (final language in AppLanguage.values) {
        final points = Dashboard.of(language).compassPoints;
        expect(points.length, 8, reason: '$language');
        for (var deg = 0.0; deg < 360; deg += 7.5) {
          final i = SafeHavenFinder.compassIndex(deg);
          expect(i, inInclusiveRange(0, 7), reason: '$deg in $language');
          expect(points[i].trim(), isNotEmpty);
        }
      }
    });

    test('Bangla compass points are Bangla', () {
      for (final p in Dashboard.of(AppLanguage.bangla).compassPoints) {
        expect(RegExp(r'[ঀ-৿]').hasMatch(p), isTrue, reason: p);
      }
    });
  });

  group('distances are real', () {
    test('a known separation comes out right', () {
      // 0.0018 degrees of latitude is ~200 m anywhere on earth.
      expect(SafeHavenFinder.metresBetween(here, near), closeTo(200, 15));
      expect(SafeHavenFinder.metresBetween(here, here), 0);
    });
  });
}
