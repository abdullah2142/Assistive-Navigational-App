import 'dart:math' as math;

import '../localization/app_language.dart';
import 'routing_service.dart';
import 'voice_matching.dart';

/// A destination the assistant asked about and is waiting to hear more on.
///
/// ## Why this exists
///
/// A user who cannot see a map does not name places the way a geocoder
/// wants them named. They say "the eye hospital", "my daughter's school",
/// "that big mosque near the market" — and Dhaka's informal addressing
/// means even a real address frequently resolves to nothing. Before this,
/// all of that produced one dead-end sentence: *"I couldn't find that."*
/// The user had no idea whether the problem was the name, the recognizer,
/// or the map, and no way forward except guessing a different phrasing into
/// silence.
///
/// So an unresolved destination becomes a short conversation instead of a
/// failure. The assistant keeps what it already has, asks one focused
/// question, and combines the answer with the original — which is what
/// "triangulating" a place actually looks like when neither side can point
/// at a map.
class DestinationClarification {
  const DestinationClarification({
    required this.originalQuery,
    this.hints = const [],
    this.options = const [],
    this.attempts = 0,
  });

  /// What the user first called the place. Never discarded — every retry
  /// searches for this *plus* the hints, because the original name is the
  /// only part we know came from the user rather than from our own guessing.
  final String originalQuery;

  /// Extra detail gathered across turns ("near Dhanmondi 27", "it's in
  /// Mirpur"), oldest first.
  final List<String> hints;

  /// Candidate places currently being offered, when the problem is too many
  /// answers rather than none.
  final List<GeocodeCandidate> options;

  /// How many questions have been asked so far. Bounded — see
  /// [maxAttempts].
  final int attempts;

  /// After this many rounds the assistant stops asking and offers a
  /// different way through.
  ///
  /// A blind user standing on a footpath being interrogated about an
  /// address they have already described twice is not being helped, they
  /// are being trapped. Three is enough for a genuine misunderstanding and
  /// short enough not to become one.
  static const int maxAttempts = 3;

  bool get isOfferingOptions => options.isNotEmpty;
  bool get isExhausted => attempts >= maxAttempts;

  /// The search string to try next: the original name plus everything
  /// learned since.
  String get combinedQuery => [originalQuery, ...hints].join(', ');

  DestinationClarification withHint(String hint) => DestinationClarification(
        originalQuery: originalQuery,
        hints: [...hints, hint],
        attempts: attempts + 1,
      );

  DestinationClarification offering(List<GeocodeCandidate> candidates) => DestinationClarification(
        originalQuery: originalQuery,
        hints: hints,
        options: candidates,
        attempts: attempts + 1,
      );
}

/// What the user's follow-up turned out to mean.
sealed class ClarificationOutcome {
  const ClarificationOutcome();
}

/// They picked one of the offered places.
class ClarificationResolved extends ClarificationOutcome {
  const ClarificationResolved(this.candidate);
  final GeocodeCandidate candidate;
}

/// They added detail — search again with it.
class ClarificationRefined extends ClarificationOutcome {
  const ClarificationRefined(this.updated);
  final DestinationClarification updated;
}

/// They gave up, or changed the subject.
class ClarificationCancelled extends ClarificationOutcome {
  const ClarificationCancelled();
}

/// Nothing useful in the reply — ask the same question again rather than
/// treating noise as an answer.
class ClarificationUnclear extends ClarificationOutcome {
  const ClarificationUnclear();
}

/// Interprets a follow-up reply while a destination is being clarified.
///
/// Pure and synchronous, so the whole multi-turn conversation can be walked
/// through in a test without a network, a geocoder, or a microphone.
class DestinationClarifier {
  DestinationClarifier._();

  /// Ways of abandoning the question. Recognized in both languages, and
  /// deliberately generous: a user who wants out must always be able to get
  /// out, and there is no cost to over-recognizing this one.
  /// Shared with the place-save conversation, which needs the same "stop
  /// asking me" vocabulary and should not drift from this one.
  static bool isCancellation(String reply) => containsAny(voiceWords(reply), _cancelWords);

  static const _cancelWords = [
    'cancel', 'never mind', 'nevermind', 'forget it', 'forget about it', 'stop',
    'leave it', 'no thanks', 'no thank you', 'skip', 'drop it',
    'বাদ', 'থাক', 'বাদ দাও', 'দরকার নেই', 'লাগবে না', 'বন্ধ',
  ];

  /// Ordinal references to an offered option — "the first one", "number
  /// two". Listed because a user who cannot see a list cannot tap it, and
  /// repeating a long geocoder label back verbatim is unreasonable.
  ///
  /// Deliberately **no bare "one"/"two"/"three"**: "the one near my house"
  /// is a user narrowing the search, not picking option 1, and reading it
  /// as a choice sends them to a place they never selected. An ordinal has
  /// to be unmistakably ordinal — "first", "number two", or a bare digit.
  static const _ordinals = <List<String>>[
    ['first', '1', 'number one', 'প্রথম', '১', 'নম্বর এক'],
    ['second', '2', 'number two', 'দ্বিতীয়', '২', 'নম্বর দুই'],
    ['third', '3', 'number three', 'তৃতীয়', '৩', 'নম্বর তিন'],
  ];

  /// Bare cardinals — "two", "দুই". Accepted **only when the reply is
  /// essentially nothing else**.
  ///
  /// Alone, "two" can only be a choice. Inside a sentence it is almost
  /// never one: "two roads down", "দুই নম্বর গেটের কাছে" are landmark
  /// hints, and reading either as picking option 2 walks the user to a
  /// place they never chose. Length is what separates the two readings, and
  /// it matters for Bangla especially — a `bn-BD` recognizer transcribes a
  /// spoken numeral as "দুই" far more often than as "২", so refusing bare
  /// cardinals outright would leave Bangla users no way to pick at all.
  static const _bareCardinals = <List<String>>[
    ['one', 'এক'],
    ['two', 'দুই'],
    ['three', 'তিন'],
  ];

  /// At most this many words for a reply to count as "just the number".
  /// Two, so "two please" and "দুই নম্বর" still work.
  static const int _terseReplyWords = 2;

  /// Two candidates closer together than this are the same place described
  /// twice, not a real choice — geocoders routinely return a building and
  /// its own entrance as separate rows, and asking a user to choose between
  /// them is asking a question with no meaningful answer.
  static const double sameePlaceMeters = 150;

  static ClarificationOutcome interpret({
    required String reply,
    required DestinationClarification pending,
    required AppLanguage language,
  }) {
    final trimmed = reply.trim();
    if (trimmed.isEmpty) return const ClarificationUnclear();
    final words = voiceWords(trimmed);
    if (containsAny(words, _cancelWords)) return const ClarificationCancelled();

    if (pending.isOfferingOptions) {
      final picked = _pickOption(words, trimmed, pending.options);
      if (picked != null) return ClarificationResolved(picked);
      // Not one of the options, and not a cancel — treat it as more detail
      // rather than as a failed choice. Someone who answers "no, the one in
      // Mirpur" is refining, not picking.
    }

    // Anything else is taken as added detail. Deliberately permissive: the
    // user is answering a question we asked, so the default reading of
    // whatever they said is "this is the answer", not "I didn't understand".
    if (pending.isExhausted) return const ClarificationUnclear();
    return ClarificationRefined(pending.withHint(trimmed));
  }

  static GeocodeCandidate? _pickOption(
    List<String> words,
    String raw,
    List<GeocodeCandidate> options,
  ) {
    // By position: "the second one".
    for (var i = 0; i < options.length && i < _ordinals.length; i++) {
      if (containsAny(words, _ordinals[i])) return options[i];
    }
    // A bare cardinal, but only in a reply short enough that it cannot be
    // anything else — see [_bareCardinals].
    if (words.length <= _terseReplyWords) {
      for (var i = 0; i < options.length && i < _bareCardinals.length; i++) {
        if (containsAny(words, _bareCardinals[i])) return options[i];
      }
    }
    // By name — but only on words that actually distinguish one option
    // from the others. Every candidate for "the hospital" contains the
    // word "hospital", so matching on it picks whichever happened to be
    // listed first while looking like a real answer. Only a word unique to
    // a single option is evidence of which one was meant.
    final occurrences = <String, int>{};
    for (final option in options) {
      for (final word in voiceWords(option.spokenLabel).where((w) => w.length > 3).toSet()) {
        occurrences[word] = (occurrences[word] ?? 0) + 1;
      }
    }
    for (final option in options) {
      final distinctive = voiceWords(option.spokenLabel)
          .where((w) => w.length > 3 && occurrences[w] == 1);
      if (distinctive.any((w) => containsTermInflected(words, w))) return option;
    }
    return null;
  }

  /// Collapses candidates that are really the same place, and caps how many
  /// are offered.
  ///
  /// Three at most: a spoken list is held in working memory, and a blind
  /// user asked to choose between six read-aloud addresses has been given a
  /// memory test, not a choice.
  static List<GeocodeCandidate> distinctOptions(List<GeocodeCandidate> raw, {int max = 3}) {
    final kept = <GeocodeCandidate>[];
    for (final candidate in raw) {
      final duplicate = kept.any((k) => _metersBetween(k, candidate) < sameePlaceMeters);
      if (duplicate) continue;
      kept.add(candidate);
      if (kept.length == max) break;
    }
    return kept;
  }

  static double _metersBetween(GeocodeCandidate a, GeocodeCandidate b) {
    const earthRadius = 6371008.8;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(b.location.latitude - a.location.latitude);
    final dLng = rad(b.location.longitude - a.location.longitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.sin(dLng / 2) *
            math.sin(dLng / 2) *
            math.cos(rad(a.location.latitude)) *
            math.cos(rad(b.location.latitude));
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }
}
