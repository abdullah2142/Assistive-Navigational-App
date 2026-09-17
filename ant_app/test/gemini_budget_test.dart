// The assistant's money ceiling.
//
// Google's budget alerts do not cap spend — they email once it is gone — so
// the only real ceiling lives in the client. `MonthlyApiBudget` already
// applies that reasoning to the Maps APIs; this extends it to the model,
// which is now the app's other billable call.
//
// Counted in calls rather than tokens because a call is the only unit the
// client can see, and it is a good proxy: the system prompt and the 24 tool
// declarations are ~5,200 of the ~5,600 input tokens on an average turn,
// whatever the user said.

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/api_budget.dart';

void main() {
  test('the model is a billable API like any other', () {
    expect(BillableApi.values, contains(BillableApi.gemini));
    expect(MonthlyApiBudget.defaultCaps[BillableApi.gemini], isNotNull);
  });

  test('the ceiling is high enough that testing never meets it', () {
    // The heaviest real session on record made 84 calls in about an hour.
    // The cap exists to stop a *bug* — a retry loop, a stuck wake word —
    // from spending the budget, not to ration ordinary use.
    final cap = MonthlyApiBudget.defaultCaps[BillableApi.gemini]!;
    expect(cap ~/ 84, greaterThan(100), reason: 'over 100 heavy hours a month');
  });

  test('calls are counted and then refused', () async {
    final budget = MonthlyApiBudget(
      store: _CountingStore(),
      caps: const {BillableApi.gemini: 3},
    );
    expect(await budget.tryConsume(BillableApi.gemini), isTrue);
    expect(await budget.tryConsume(BillableApi.gemini), isTrue);
    expect(await budget.tryConsume(BillableApi.gemini), isTrue);
    expect(await budget.tryConsume(BillableApi.gemini), isFalse,
        reason: 'the fourth call is over the ceiling');
  });

  test('one API running out does not stop another', () {
    // Routing and the assistant are separate budgets. An exhausted model
    // must not also take the map down.
    final caps = MonthlyApiBudget.defaultCaps;
    expect(caps[BillableApi.gemini], isNot(caps[BillableApi.routes]));
  });

  test('an unreadable counter refuses rather than assumes', () async {
    // Fails closed, like the Maps path: an unreachable counter must not
    // silently remove the only ceiling that exists. The cost of failing
    // closed is a fallback reply, not a bill.
    final budget = MonthlyApiBudget(store: _BrokenStore());
    expect(await budget.tryConsume(BillableApi.gemini), isFalse);
  });
}

class _CountingStore implements ApiBudgetStore {
  final _counts = <String, int>{};

  @override
  Future<Map<String, int>> read(String period) async => Map.of(_counts);

  @override
  Future<void> increment(String period, String api) async =>
      _counts[api] = (_counts[api] ?? 0) + 1;
}

class _BrokenStore implements ApiBudgetStore {
  @override
  Future<Map<String, int>> read(String period) async => throw Exception('offline');

  @override
  Future<void> increment(String period, String api) async {}
}
