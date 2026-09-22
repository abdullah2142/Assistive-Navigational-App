import 'dart:async';

// The `awaitAuth` seam below is named for the caller while the field is
// private, which is this codebase's convention.
// ignore_for_file: prefer_initializing_formals

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../localization/app_language.dart';

/// One known Dhaka bus operator.
///
/// Called an operator rather than a route because that is what Dhaka
/// actually has: `আছিম পরিবহন` runs one long corridor, and its signboard
/// carries the company name and a list of places, not a number.
class BusRoute {
  const BusRoute({
    required this.id,
    required this.nameEn,
    required this.nameBn,
    this.routeNumber,
    this.stops = const [],
    this.serviceType = '',
  });

  final String id;
  final String nameEn;
  final String nameBn;

  /// Present for **7 of 156 operators**. See [BusRouteDirectory] for why that
  /// number reshaped this whole class.
  final String? routeNumber;

  /// Stops in order along the corridor.
  final List<String> stops;
  final String serviceType;

  String get origin => stops.isEmpty ? '' : stops.first;
  String get destination => stops.isEmpty ? '' : stops.last;

  String nameFor(AppLanguage language) =>
      language == AppLanguage.bangla && nameBn.isNotEmpty ? nameBn : nameEn;

  /// Where this bus goes, phrased for speech.
  String destinationFor(AppLanguage language) => destination;

  static BusRoute? fromSnapshot(String id, Map<String, dynamic>? data) {
    if (data == null) return null;
    final en = (data['nameEn'] as String?)?.trim() ?? '';
    final bn = (data['nameBn'] as String?)?.trim() ?? '';
    if (en.isEmpty && bn.isEmpty) return null;
    return BusRoute(
      id: id,
      nameEn: en,
      nameBn: bn,
      routeNumber: (data['routeNumber'] as String?)?.trim(),
      stops: [
        for (final s in (data['stops'] as List<dynamic>? ?? const []))
          if (s is String && s.trim().isNotEmpty) s.trim(),
      ],
      serviceType: (data['serviceType'] as String?)?.trim() ?? '',
    );
  }
}

/// How confident a match is, and what produced it.
class BusRouteMatch {
  const BusRouteMatch({
    required this.route,
    required this.score,
    required this.why,
    this.destinationCertain = true,
  });

  final BusRoute route;

  /// False when several operators tie and this one was picked from among
  /// them — the *name* is trustworthy, the destination is not.
  ///
  /// This is the BRTC case, and it is not an edge case: the dataset carries
  /// **nine** documents named `বি আর টিসি বাস`, running corridors as
  /// different as Madanpur-Savar and Motijheel-Tongi. The signboard name
  /// cannot separate them, so saying "this BRTC bus goes to Savar" is a coin
  /// flip presented as a fact — to somebody who will board on the strength
  /// of it. Saying "this is a BRTC bus" is true, useful, and all we know.
  final bool destinationCertain;

  /// 0-1. See [BusRouteDirectory.minConfidence] for where the line sits.
  final double score;

  /// `number`, `name`, `stops`, or `name+stops` — for logs, and because a
  /// match found two different ways is worth more than one found once.
  final String why;
}

/// Plan Step 3.3: works out which bus the camera is looking at.
///
/// ## Why this is name-matching and not a number lookup
///
/// It was a number lookup, and that was built on a made-up test image. Checked
/// against a real dataset of 156 Dhaka operators: **7 have a number in the
/// name. 149 do not.** Real signboards say `আছিম পরিবহন`, `অগ্রদূত`,
/// `আকাশ বাস`.
///
/// That inverts the problem. The thing a blind user needs read off the board
/// is Bangla conjunct text — exactly what OCR degrades on, measured here as
/// `গুলশান` -> `ঠানশান` — and there is no digit to fall back to, because
/// digits are what survive blur and 96% of these buses do not have one.
///
/// ## Why fuzzy matching makes that better rather than worse
///
/// Matching corrupted text against *nothing* is hopeless. Matching it against
/// a **closed list of 156 names** is easy: a one- or two-character slip still
/// lands nearest its true entry, because no other operator is that close.
///
/// And the signboard gives a second, independent signal. It lists places, and
/// those place names are checked against the operator's own stop list — so a
/// board read as `আছিন পরিবহন ... মিরপুর ১০ ... বাড্ডা` matches on the name
/// *and* on two stops, and the agreement of two noisy signals is far stronger
/// than either alone. That is what [BusRouteMatch.why] records.
class BusRouteDirectory {
  BusRouteDirectory({
    FirebaseFirestore? firestore,
    List<BusRoute>? seed,
    @visibleForTesting Future<void> Function()? awaitAuth,
  })  : _injectedDb = firestore,
        _awaitAuth = awaitAuth,
        _all = seed == null ? null : List.unmodifiable(seed);

  final FirebaseFirestore? _injectedDb;

  /// Overridable so a test can resolve immediately without a Firebase app.
  final Future<void> Function()? _awaitAuth;

  /// Built lazily: `FirebaseFirestore.instance` throws when no Firebase app
  /// is initialized, which would make this class unconstructible in tests
  /// that never touch the network.
  late final FirebaseFirestore _db = _injectedDb ?? FirebaseFirestore.instance;

  List<BusRoute>? _all;
  Future<List<BusRoute>>? _loading;

  static const String collection = 'busRoutes';

  /// Below this, say nothing rather than name a bus.
  ///
  /// Naming the wrong bus to somebody who cannot read the board is worse than
  /// admitting uncertainty: they get on it. So the default is silence, and
  /// the app falls back to reading out whatever text was actually seen.
  ///
  /// 0.62 is a starting point chosen so a two-character slip in a
  /// twelve-character Bangla name still clears it, not a measured figure.
  /// Re-tune against real signboard photographs.
  static const double minConfidence = 0.62;

  /// The whole directory, cached for the session.
  ///
  /// 156 documents is small enough to hold entirely, and fuzzy matching needs
  /// every candidate anyway — there is no query that narrows it, because the
  /// input is misspelt by definition. One read per session, then free.
  /// Blocks until Firebase Auth has a user, so the read is made as one.
  ///
  /// `busRoutes` is `allow read: if request.auth != null`, and this class is
  /// first asked for a match by a camera scan that can happen within seconds
  /// of launch — before anonymous sign-in has resolved. On 22 September that
  /// produced, at 35 seconds in:
  ///
  ///     [BusRoutes] load failed: [cloud_firestore/permission-denied]
  ///
  /// which is not a permissions problem at all. The rule is right; the read
  /// was simply early. The symptom is the worst kind for this feature — no
  /// crash, no retry prompt, just an empty directory, so every bus for the
  /// rest of that session was identified by the vision model's unverified
  /// reading with nothing to correct it against. That is precisely the
  /// failure `VisionConfig.busRouteLookupWins` exists to prevent.
  ///
  /// Bounded, because waiting forever would be a worse failure than the one
  /// being fixed: a scan that never answers. On timeout the read is attempted
  /// anyway — if auth did land, it succeeds; if not, `catchError` clears
  /// `_loading` and the next scan tries again.
  Future<void> _waitForAuth() async {
    final override = _awaitAuth;
    if (override != null) return override();
    try {
      if (FirebaseAuth.instance.currentUser != null) return;
      await FirebaseAuth.instance
          .authStateChanges()
          .firstWhere((user) => user != null)
          .timeout(_authWait);
    } catch (e) {
      debugPrint('[BusRoutes] proceeding without a confirmed sign-in: $e');
    }
  }

  static const Duration _authWait = Duration(seconds: 8);

  Future<List<BusRoute>> _load() {
    final cached = _all;
    if (cached != null) return Future.value(cached);
    return _loading ??=
        _waitForAuth().then((_) => _db.collection(collection).get()).then((snap) {
      final routes = [
        for (final doc in snap.docs) ?BusRoute.fromSnapshot(doc.id, doc.data()),
      ];
      _all = List.unmodifiable(routes);
      debugPrint('[BusRoutes] directory loaded: ${routes.length} operators');
      return _all!;
    }).catchError((Object e) {
      // Never throws. An unreachable directory means the model's own reading
      // is used unverified, which is where this feature started — whereas an
      // exception here would lose the whole scan.
      debugPrint('[BusRoutes] load failed: $e');
      _loading = null;
      return <BusRoute>[];
    });
  }

  /// Identifies the bus from whatever the camera read.
  ///
  /// [readText] is the raw signboard text, misspellings and all.
  /// [routeNumber] is the digits if any were read — still used first, because
  /// when a number *is* present it is the most reliable signal there is.
  /// [readStops] are place names the model listed, used as corroboration.
  Future<BusRouteMatch?> identify({
    String? routeNumber,
    String readText = '',
    List<String> readStops = const [],
  }) async {
    final all = await _load();
    if (all.isEmpty) return null;

    // 1. A number, when there is one and only one operator runs it.
    //
    // Not unambiguous, which the dataset itself proves: `6 No. Dhaka` and
    // `6 No. Motijheel Banani Transport Dhaka` are both numbered 6 and share
    // the same eighteen stops. Returning whichever came first would speak a
    // name that is wrong half the time — so a contested number falls through
    // to name matching, which is the only thing that can separate them.
    final number = routeNumber?.trim();
    if (number != null && number.isNotEmpty) {
      final byNumber = all.where((r) => r.routeNumber == number).toList();
      if (byNumber.length == 1) {
        debugPrint('[BusRoutes] matched $number by number -> ${byNumber.first.nameEn}');
        return BusRouteMatch(route: byNumber.first, score: 1, why: 'number');
      }
      if (byNumber.length > 1) {
        debugPrint('[BusRoutes] $number is run by ${byNumber.length} operators '
            '— falling through to the name');
      }
    }

    // 2. Name similarity, plus how many read stops appear on each candidate.
    final haystack = normalise('$readText ${readStops.join(' ')}');
    if (haystack.isEmpty) return null;

    final scored = <({BusRoute route, double name, int stops, double total})>[];
    for (final r in all) {
      final nameScore = [
        _similarity(haystack, normalise(r.nameBn)),
        _similarity(haystack, normalise(r.nameEn)),
      ].reduce((a, b) => a > b ? a : b);

      final stopHits = readStops.isEmpty
          ? 0
          : readStops
              .where((s) => r.stops
                  .any((k) => _similarity(normalise(s), normalise(k)) > 0.85))
              .length;

      scored.add((route: r, name: nameScore, stops: stopHits, total: nameScore));
    }
    scored.sort((a, b) => b.total.compareTo(a.total));

    final top = scored.first;
    if (top.total < minConfidence) {
      debugPrint('[BusRoutes] no confident match for "$readText" '
          '(best ${top.route.nameEn} at ${top.total.toStringAsFixed(2)})');
      return null;
    }

    // Everything within a whisker of the leader. Scoring on the name alone
    // first and *then* breaking ties on stops is deliberate: folding stops
    // into one blended score made accuracy worse, because dozens of
    // operators serve Mirpur 10 and the shared stop lifted every one of them.
    // Stops are a tie-breaker, not evidence of identity.
    final tied = scored.where((e) => e.total >= top.total - _tieWindow).toList();

    if (tied.length > 1) {
      // Prefer whichever candidate the read destinations actually corroborate.
      tied.sort((a, b) => b.stops.compareTo(a.stops));
      final bestStops = tied.first.stops;
      final stillTied = tied.where((e) => e.stops == bestStops).toList();
      final names = stillTied.map((e) => e.route.nameBn).toSet();

      if (stillTied.length > 1) {
        final winner = stillTied.first;
        debugPrint('[BusRoutes] "${readText.trim()}" -> ${winner.route.nameEn} '
            '(${stillTied.length} candidates tied, ${names.length} distinct names)');
        return BusRouteMatch(
          route: winner.route,
          // One name across several corridors is a *known* operator with an
          // unknown destination. Several names is a genuinely uncertain read,
          // and scores lower so the caller can choose to say nothing.
          score: names.length == 1 ? top.total : top.total * 0.8,
          why: names.length == 1 ? 'name (route ambiguous)' : 'ambiguous',
          destinationCertain: false,
        );
      }
    }

    final winner = tied.first;
    debugPrint('[BusRoutes] matched "${readText.trim()}" -> ${winner.route.nameEn} '
        '(${winner.total.toStringAsFixed(2)}, stops=${winner.stops})');
    return BusRouteMatch(
      route: winner.route,
      score: winner.total,
      why: winner.stops > 0 ? 'name+stops' : 'name',
    );
  }

  /// How close a rival has to be to count as tied.
  ///
  /// Small, because these scores are normalised edit distances over short
  /// strings and a genuine second-place name is usually far below the
  /// leader. It exists to catch exact duplicates and near-identical names,
  /// not to widen the field.
  static const double _tieWindow = 0.02;

  /// Lowercase, strip punctuation, collapse whitespace, and fold Bangla
  /// digits to ASCII so `৬` and `6` compare equal.
  @visibleForTesting
  static String normalise(String input) {
    final buffer = StringBuffer();
    for (final rune in input.toLowerCase().runes) {
      if (rune >= 0x09E6 && rune <= 0x09EF) {
        buffer.writeCharCode(0x30 + (rune - 0x09E6));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer
        .toString()
        .replaceAll(RegExp(r'[^ঀ-৿ a-z0-9]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 0-1 similarity.
  ///
  /// When [needle] appears inside [haystack] this is 1 — the common case, and
  /// the cheap one: a signboard read carries the operator name surrounded by
  /// destinations, so an exact name is a substring rather than the whole
  /// string. Otherwise it is the best normalised edit distance between the
  /// needle and any window of the haystack its own length, which is what
  /// tolerates the one- and two-character OCR slips this exists for.
  static double _similarity(String haystack, String needle) {
    if (needle.isEmpty || haystack.isEmpty) return 0;
    if (haystack.contains(needle)) return 1;
    if (needle.length > haystack.length) {
      return _windowBest(needle, haystack);
    }
    return _windowBest(haystack, needle);
  }

  static double _windowBest(String long, String short) {
    final n = short.length;
    var best = 0.0;
    // Step by one, but only over a bounded number of windows — a 40-character
    // haystack against 156 operators is 6,000 comparisons, which is fine, and
    // this keeps a pathological input from becoming quadratic on the path of
    // a scan the user is standing in the road for.
    final limit = long.length - n;
    for (var i = 0; i <= limit && i < 80; i++) {
      final d = _editDistance(long.substring(i, i + n), short);
      final sim = 1 - d / n;
      if (sim > best) best = sim;
      if (best == 1) break;
    }
    return best.clamp(0.0, 1.0);
  }

  /// Levenshtein, two-row. Bangla is compared by code unit rather than by
  /// grapheme cluster — imprecise for conjuncts, but consistently so on both
  /// sides of the comparison, which is what a similarity ranking needs.
  static int _editDistance(String a, String b) {
    if (a == b) return 0;
    var prev = List<int>.generate(b.length + 1, (i) => i);
    var cur = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = cur[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        cur[j] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
      }
      final swap = prev;
      prev = cur;
      cur = swap;
    }
    return prev[b.length];
  }
}
