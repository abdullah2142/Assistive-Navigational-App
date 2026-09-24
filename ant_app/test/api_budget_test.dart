import 'package:ant_app/core/config/routing_config.dart';
import 'package:ant_app/core/services/api_budget.dart';
import 'package:ant_app/core/services/routing_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory stand-in for the Firestore counter.
class FakeBudgetStore implements ApiBudgetStore {
  FakeBudgetStore([Map<String, Map<String, int>>? seed]) : _data = seed ?? {};

  final Map<String, Map<String, int>> _data;
  bool failReads = false;
  int writes = 0;

  @override
  Future<Map<String, int>> read(String period) async {
    if (failReads) throw Exception('firestore unreachable');
    return Map<String, int>.from(_data[period] ?? const {});
  }

  @override
  Future<void> increment(String period, String api) async {
    writes++;
    final month = _data.putIfAbsent(period, () => {});
    month[api] = (month[api] ?? 0) + 1;
  }
}

void main() {
  group('monthly ceiling', () {
    test('allows calls under the cap', () async {
      final budget = MonthlyApiBudget(
        store: FakeBudgetStore(),
        caps: const {BillableApi.routes: 3},
        now: () => DateTime(2026, 9, 7),
      );

      expect(await budget.tryConsume(BillableApi.routes), isTrue);
      expect(await budget.tryConsume(BillableApi.routes), isTrue);
      expect(await budget.tryConsume(BillableApi.routes), isTrue);
    });

    test('refuses the call that would cross the cap', () async {
      final budget = MonthlyApiBudget(
        store: FakeBudgetStore(),
        caps: const {BillableApi.routes: 2},
        now: () => DateTime(2026, 9, 7),
      );

      await budget.tryConsume(BillableApi.routes);
      await budget.tryConsume(BillableApi.routes);

      expect(await budget.tryConsume(BillableApi.routes), isFalse);
    });

    test('counts each API separately', () async {
      // They are separate SKUs with separate allowances. Exhausting the cheap
      // geocoding budget must not disable the emergency Places lookup.
      final budget = MonthlyApiBudget(
        store: FakeBudgetStore(),
        caps: const {BillableApi.geocoding: 1, BillableApi.places: 1},
        now: () => DateTime(2026, 9, 7),
      );

      await budget.tryConsume(BillableApi.geocoding);

      expect(await budget.tryConsume(BillableApi.geocoding), isFalse);
      expect(await budget.tryConsume(BillableApi.places), isTrue);
    });

    test('picks up usage another device already recorded', () async {
      // The whole point of a shared counter: five testers draw down one
      // project-wide allowance, not five private ones.
      final store = FakeBudgetStore({
        '2026-09': {'routes': 9000},
      });
      final budget = MonthlyApiBudget(
        store: store,
        now: () => DateTime(2026, 9, 7),
      );

      expect(await budget.tryConsume(BillableApi.routes), isFalse);
    });

    test('resets on a calendar month, matching how Google resets', () async {
      final store = FakeBudgetStore({
        '2026-09': {'routes': 9000},
      });
      var day = DateTime(2026, 9, 30);
      final budget = MonthlyApiBudget(store: store, now: () => day);

      expect(await budget.tryConsume(BillableApi.routes), isFalse);

      day = DateTime(2026, 10, 1);

      // A rolling 30-day window would still be refusing here, on a day
      // Google is already billing as free.
      expect(await budget.tryConsume(BillableApi.routes), isTrue);
    });

    test(
      'bounds a burst within one session without waiting for writes',
      () async {
        // The local count moves first, so a retry loop is stopped immediately
        // rather than after every increment has round-tripped.
        final budget = MonthlyApiBudget(
          store: FakeBudgetStore(),
          caps: const {BillableApi.routes: 5},
          now: () => DateTime(2026, 9, 7),
        );

        var allowed = 0;
        for (var i = 0; i < 100; i++) {
          if (await budget.tryConsume(BillableApi.routes)) allowed++;
        }

        expect(allowed, 5);
      },
    );
  });

  group('failure behaviour', () {
    test('fails CLOSED when the counter cannot be read', () async {
      // Failing open would mean an unreachable Firestore silently removes the
      // only monthly ceiling that exists. The cost of failing closed is a
      // worse route; the cost of failing open is a bill.
      final store = FakeBudgetStore()..failReads = true;
      final budget = MonthlyApiBudget(
        store: store,
        now: () => DateTime(2026, 9, 7),
      );

      expect(await budget.tryConsume(BillableApi.routes), isFalse);
    });

    test('a failed increment does not throw into the caller', () async {
      final budget = MonthlyApiBudget(
        store: _ThrowingIncrementStore(),
        now: () => DateTime(2026, 9, 7),
      );

      expect(await budget.tryConsume(BillableApi.routes), isTrue);
    });

    test('usage() reports empty rather than throwing', () async {
      final store = FakeBudgetStore()..failReads = true;
      final budget = MonthlyApiBudget(
        store: store,
        now: () => DateTime(2026, 9, 7),
      );

      expect(await budget.usage(), isEmpty);
    });
  });

  group('wired into RoutingService', () {
    const dhaka = LatLng(23.7509, 90.3891);
    const gulshan = LatLng(23.7925, 90.4078);

    final googleOk = http.Response(
      '{"routes":[{"distanceMeters":1053,"duration":"900s",'
      '"polyline":{"encodedPolyline":"_p~iF~ps|U_ulLnnqC"},"legs":[]}]}',
      200,
    );
    final osrmOk = http.Response(
      '{"code":"Ok","routes":[{"geometry":"_p~iF~ps|U_ulLnnqC",'
      '"distance":900.0,"duration":300.0,"legs":[]}]}',
      200,
    );

    MockClient byHost() => MockClient((request) async {
      if (request.url.host.contains('routes.googleapis.com')) return googleOk;
      if (request.url.host.contains('osrm')) return osrmOk;
      return http.Response('unexpected ${request.url.host}', 500);
    });

    test('spends budget on a Google route request', () async {
      final store = FakeBudgetStore();
      final service = RoutingService(
        backend: RoutingBackend.google,
        budget: MonthlyApiBudget(store: store, now: () => DateTime(2026, 9, 7)),
        client: byHost(),
      );

      final routes = await service.walkingRoutes(
        origin: dhaka,
        destination: gulshan,
      );

      expect(routes.first.distanceMeters, 1053);
      expect(store.writes, 1);
    });

    test('an exhausted budget silently uses OpenStreetMap', () async {
      // Not an error, not a message to the user. From the caller's side an
      // exhausted allowance and an unreachable Google are the same event, and
      // the correct response to both is a free route.
      final store = FakeBudgetStore({
        '2026-09': {'routes': 9000},
      });
      final service = RoutingService(
        backend: RoutingBackend.google,
        budget: MonthlyApiBudget(store: store, now: () => DateTime(2026, 9, 7)),
        client: byHost(),
      );

      final routes = await service.walkingRoutes(
        origin: dhaka,
        destination: gulshan,
      );

      expect(
        routes,
        isNotEmpty,
        reason: 'running out of free tier must not end navigation',
      );
      expect(routes.first.distanceMeters, 900);
      expect(
        routes.first.isPedestrianProfile,
        isFalse,
        reason: 'the OSM route is still a car profile and must say so',
      );
    });

    test('never touches the budget when Google is switched off', () async {
      final store = FakeBudgetStore();
      final service = RoutingService(
        backend: RoutingBackend.openStreetMap,
        budget: MonthlyApiBudget(store: store, now: () => DateTime(2026, 9, 7)),
        client: byHost(),
      );

      await service.walkingRoutes(origin: dhaka, destination: gulshan);

      expect(store.writes, 0);
    });
  });

  group('default caps', () {
    test('sit under Google\'s published free tier', () {
      // 10,000 / 10,000 / 5,000. The gap absorbs the optimistic-increment
      // race and any calls made outside the app.
      expect(
        MonthlyApiBudget.defaultCaps[BillableApi.geocoding]!,
        lessThan(10000),
      );
      expect(
        MonthlyApiBudget.defaultCaps[BillableApi.routes]!,
        lessThan(10000),
      );
      expect(
        MonthlyApiBudget.defaultCaps[BillableApi.routesPro]!,
        lessThan(5000),
      );
      expect(MonthlyApiBudget.defaultCaps[BillableApi.places]!, lessThan(5000));
    });

    test(
      'an OpenStreetMap build gets an unlimited budget and no Firestore',
      () {
        // Guards the test suite as much as the app: resolving the real budget
        // would construct a Firestore handle with no Firebase initialised.
        expect(RoutingConfig.preferGoogle, isFalse);
        expect(defaultApiBudget, isA<UnlimitedApiBudget>());
      },
    );
  });
}

class _ThrowingIncrementStore implements ApiBudgetStore {
  @override
  Future<Map<String, int>> read(String period) async => {};

  @override
  Future<void> increment(String period, String api) async =>
      throw Exception('write failed');
}
