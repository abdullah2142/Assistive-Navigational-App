import 'package:ant_app/core/services/place_categories.dart';
import 'package:flutter_test/flutter_test.dart';

/// "nearest bathroom, nearest restaurant, anything like that didnt route me"
/// — 22 September session. Every destination was sent to a *name* geocoder,
/// and nothing in Dhaka is named "the nearest toilet".
void main() {
  group('a kind of place is recognised as a category', () {
    const cases = <String, String>{
      'the nearest bathroom': 'toilet',
      'nearest toilet': 'toilet',
      'I need a restroom': 'toilet',
      'find me a washroom': 'toilet',
      'nearest restaurant': 'restaurant',
      'somewhere to eat': 'restaurant',
      'I am hungry': 'restaurant',
      'nearest pharmacy': 'pharmacy',
      'a chemist': 'pharmacy',
      'closest hospital': 'hospital',
      'drinking water': 'water',
      'nearest mosque': 'mosque',
      'an atm': 'atm',
      'nearest bus stop': 'bus_stop',
      'a police station': 'police',
      'somewhere to sit': 'bench',
    };
    cases.forEach((query, id) {
      test('"$query" -> $id', () => expect(categoryFor(query)?.id, id));
    });
  });

  group('Bangla is matched through its suffixes', () {
    const cases = <String, String>{
      'কাছের টয়লেট': 'toilet',
      'টয়লেটে যেতে চাই': 'toilet',
      'সবচেয়ে কাছের হাসপাতাল': 'hospital',
      'একটা ফার্মেসি': 'pharmacy',
      'খাবার জায়গা': 'restaurant',
      'আমার খিদে পেয়েছে': 'restaurant',
      'কাছাকাছি মসজিদ': 'mosque',
      'বাস স্ট্যান্ড': 'bus_stop',
    };
    cases.forEach((query, id) {
      test('"$query" -> $id', () => expect(categoryFor(query)?.id, id));
    });
  });

  group('a named place is not mistaken for a category', () {
    // These must fall through to the geocoder. A false category hit would
    // route somebody to the nearest generic thing instead of the specific
    // place they asked for by name.
    for (final named in ['Gulshan 2', 'Dhanmondi', 'Mirpur 10', 'ধানমন্ডি', 'Bashundhara City']) {
      test('"$named" is not a category', () => expect(categoryFor(named), isNull));
    }
  });

  test('a category word inside a proper name still resolves by name first', () {
    // "Apollo Hospital" *does* hit the hospital category — that is accepted
    // and handled in `RoutePlanningService.plan`, which falls through to the
    // name search when the proximity search finds nothing. Asserted here so
    // the behaviour is deliberate rather than discovered.
    expect(categoryFor('Apollo Hospital')?.id, 'hospital');
  });

  test('empty input is not a category', () {
    expect(categoryFor(''), isNull);
    expect(categoryFor('   '), isNull);
  });

  group('every category is well formed', () {
    for (final category in placeCategories) {
      test('${category.id} has filters and vocabulary', () {
        expect(category.osmFilters, isNotEmpty);
        expect(category.latin, isNotEmpty);
        expect(category.bangla, isNotEmpty);
        // Overpass tag syntax — a malformed filter makes the query 400 and
        // the search silently returns nothing, which looks exactly like
        // "there is no toilet near you".
        for (final f in category.osmFilters) {
          expect(f, matches(RegExp(r'^"[a-z_:]+"="[a-z_:]+"$')), reason: f);
        }
      });
    }
  });

  test('category ids are unique', () {
    final ids = placeCategories.map((c) => c.id).toList();
    expect(ids.toSet().length, ids.length);
  });
}
