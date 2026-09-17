import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../config/routing_config.dart';

/// The Google APIs this app can be billed for.
///
/// The Maps SDK is absent on purpose: map loads are free and unlimited, so
/// counting them would be pure overhead.
///
/// [gemini] is counted in *calls*, not tokens, because a call is the only
/// unit the client can see — the SDK does not report token usage back. That
/// is fine here because the per-call cost barely varies: the system prompt
/// and the 24 tool declarations are roughly 5,200 tokens of the ~5,600 sent
/// on an average turn, whatever the user actually said. A call is therefore
/// a good proxy for a fixed slice of money.
enum BillableApi { geocoding, routes, places, gemini }

/// Decides whether one more billable Google call may be made.
///
/// An interface because there are two real answers — a counted monthly
/// budget, and "always yes" for builds where Google is switched off — and
/// `RoutingService` should not branch on which.
abstract class ApiBudget {
  /// Whether one call to [api] may be made, counting it if so.
  Future<bool> tryConsume(BillableApi api);

  /// Current counts, for display. Never throws.
  Future<Map<String, int>> usage();
}

/// Enforces the Google Maps Platform free tier.
///
/// ## Why this exists at all
///
/// Google offers no way to guarantee it. The intuitive control — cap requests
/// per day below the monthly allowance — is not available for these APIs;
/// Maps Platform exposes mainly *per-minute* quotas, and a per-minute cap
/// does not bound a month (1/minute is still ~44,000). Budget alerts only
/// email you after the money is spent. So the only place a real monthly
/// ceiling can live is in the client, which is here.
///
/// ## Why the count is project-wide, not per-device
///
/// The free tier is project-wide. Dividing it by an assumed number of
/// installs would be a guess that silently breaks the moment the app is
/// distributed more widely than planned — which is exactly the situation
/// where an overspend would be least expected and most annoying. A single
/// shared counter in Firestore has no such assumption in it.
///
/// It also happens to be the only usage figure anyone on this project can
/// actually see. The Cloud Console's own quota pages are near-unreadable for
/// these APIs, so `api_usage/{YYYY-MM}` doubles as the dashboard.
///
/// ## What it costs in accuracy
///
/// The counter is cached per session and incremented optimistically, so two
/// devices calling at the same instant can each believe they were first and
/// undercount by one. That is why the caps below sit ~10% under the real
/// allowance rather than exactly on it. Perfect accounting would need a
/// transaction per API call, which would add a round trip to every route
/// request to protect against a rounding error.
class MonthlyApiBudget implements ApiBudget {
  MonthlyApiBudget({
    required ApiBudgetStore store,
    DateTime Function()? now,
    Map<BillableApi, int>? caps,
  })  : _store = store,
        _now = now ?? DateTime.now,
        _caps = caps ?? defaultCaps;

  final ApiBudgetStore _store;
  final DateTime Function() _now;
  final Map<BillableApi, int> _caps;

  /// Monthly ceilings, set ~10% below Google's free tier.
  ///
  /// The headroom absorbs the optimistic-increment race above, plus any
  /// calls made outside this app — a console test, a colleague's build —
  /// that the counter cannot see.
  static const Map<BillableApi, int> defaultCaps = {
    // Free tier 10,000/month.
    BillableApi.geocoding: 9000,
    BillableApi.routes: 9000,
    // Free tier 5,000/month, and the dearest SKU by a wide margin.
    BillableApi.places: 4500,
    // Not a free-tier figure — a money figure, and the only hard $2 ceiling
    // that exists.
    //
    // Google's budget *alerts* do not cap anything; they email after the
    // money is spent, which is the same reason this class exists for Maps.
    // So the cap is computed here instead:
    //
    //   measured  ~5,600 input tokens + ~100 output per call
    //             (1,437 system prompt + 3,718 tool declarations + history)
    //   30,000 calls ≈ 168M input tokens
    //
    // At flash-tier input pricing that lands comfortably inside $2 — but the
    // rate is the one number here that is not measured from this codebase,
    // so **re-derive this cap from the current published price before
    // relying on it**, rather than trusting the arithmetic that produced it.
    //
    // For scale: the heaviest real tester session on record made 84 calls in
    // about an hour. 30,000 is roughly 350 such hours a month, which no
    // round of testing will approach — the ceiling is there to stop a bug
    // (a retry loop, a stuck wake word) from spending the budget, not to
    // ration ordinary use.
    BillableApi.gemini: 30000,
  };

  Map<String, int>? _cached;
  String? _cachedPeriod;

  /// `YYYY-MM`. Google's free tier resets on calendar months, so the counter
  /// has to as well — a rolling 30-day window would refuse calls in the first
  /// days of a month that Google is already billing as free.
  String get currentPeriod {
    final now = _now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  /// **Fails closed.** If the counter cannot be read — offline, Firestore
  /// down, rules misconfigured — this returns false and the caller uses
  /// OpenStreetMap. Failing open would mean an unreachable counter silently
  /// removes the only ceiling that exists, and the failure mode of failing
  /// closed is a worse route, not a bill.
  @override
  Future<bool> tryConsume(BillableApi api) async {
    final period = currentPeriod;
    try {
      if (_cachedPeriod != period || _cached == null) {
        _cached = await _store.read(period);
        _cachedPeriod = period;
      }
    } catch (e) {
      debugPrint('[ApiBudget] could not read usage; treating as exhausted: $e');
      return false;
    }

    final used = _cached![api.name] ?? 0;
    final cap = _caps[api] ?? 0;
    if (used >= cap) {
      debugPrint('[ApiBudget] ${api.name} at $used/$cap for $period — using OpenStreetMap');
      return false;
    }

    // Optimistic: the local count moves first so a burst inside one session
    // is bounded even if every write is still in flight.
    _cached![api.name] = used + 1;
    // Deliberately not awaited. A route request must not wait on a counter
    // write, and a lost increment costs one call out of a 10% margin.
    unawaited(_store.increment(period, api.name).catchError((Object e) {
      debugPrint('[ApiBudget] increment failed for ${api.name}: $e');
    }));
    return true;
  }

  @override
  Future<Map<String, int>> usage() async {
    try {
      return await _store.read(currentPeriod);
    } catch (_) {
      return const {};
    }
  }
}

/// Where the counters live. An interface so the budget logic can be tested
/// without Firestore, and so the backing store can change without touching
/// the rules above.
abstract class ApiBudgetStore {
  Future<Map<String, int>> read(String period);
  Future<void> increment(String period, String api);
}

/// `api_usage/{YYYY-MM}`, one integer field per API.
///
/// Uses `FieldValue.increment`, so concurrent writes from different devices
/// add up correctly on the server even though the local cache is optimistic.
class FirestoreApiBudgetStore implements ApiBudgetStore {
  FirestoreApiBudgetStore({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  @override
  Future<Map<String, int>> read(String period) async {
    final snap = await _db.collection('api_usage').doc(period).get();
    final data = snap.data();
    if (data == null) return {};
    return {
      for (final entry in data.entries)
        if (entry.value is num) entry.key: (entry.value as num).toInt(),
    };
  }

  @override
  Future<void> increment(String period, String api) {
    return _db.collection('api_usage').doc(period).set(
      {api: FieldValue.increment(1)},
      SetOptions(merge: true),
    );
  }
}

/// An always-allow budget.
///
/// The default, because it is what an OpenStreetMap-only build needs: with
/// `ROUTING_PREFER_GOOGLE` off, nothing billable is called and counting would
/// be a Firestore round trip in exchange for nothing. A Google build wires in
/// [MonthlyApiBudget] instead.
class UnlimitedApiBudget implements ApiBudget {
  const UnlimitedApiBudget();

  @override
  Future<bool> tryConsume(BillableApi api) async => true;

  @override
  Future<Map<String, int>> usage() async => const {};
}


ApiBudget? _shared;

/// The budget every [RoutingService] uses unless one is injected.
///
/// A singleton on purpose. `RoutePlanningService` and `EmergencyService` each
/// build their own `RoutingService`, and a per-instance budget would mean two
/// independent cached counts that could each spend the full allowance —
/// exactly the overshoot this class exists to prevent.
///
/// Resolves off the compile-time [RoutingConfig.preferGoogle] rather than an
/// injected backend, so an OpenStreetMap build never constructs a Firestore
/// handle and the test suite never reaches Firebase.
ApiBudget get defaultApiBudget => _shared ??= RoutingConfig.preferGoogle
    ? MonthlyApiBudget(store: FirestoreApiBudgetStore())
    : const UnlimitedApiBudget();

@visibleForTesting
set defaultApiBudget(ApiBudget budget) => _shared = budget;
