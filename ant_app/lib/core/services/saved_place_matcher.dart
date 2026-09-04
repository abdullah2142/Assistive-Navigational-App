import '../../features/onboarding/models/saved_place.dart';
import 'voice_matching.dart';

/// Resolves a spoken destination against the user's own saved places.
///
/// This is the single biggest latency win available in the whole routing
/// path, and it is worth being precise about why. "Take me to work"
/// normally costs a Gemini round trip to extract the destination, then a
/// Nominatim geocode to turn "work" into coordinates — which, for a word
/// like "work", cannot succeed anyway. Resolved from a saved place it costs
/// nothing: no network, no model, no follow-up question, and it works with
/// the radio off.
///
/// It is also the only thing that makes a whole class of destination
/// reachable at all. "My sister's house" is not a geocodable string; no
/// amount of clever prompting turns it into a coordinate. Saved once, it
/// becomes the easiest destination in the app.
class SavedPlaceMatcher {
  SavedPlaceMatcher._();

  /// Words that mean each kind of place, beyond whatever the user named it.
  ///
  /// So someone who saved their workplace as "the office" is still
  /// understood when they say "take me to work", and vice versa — people do
  /// not reliably repeat their own label back verbatim, especially not
  /// weeks later, and being told "I don't know where that is" about a place
  /// you personally saved is a particularly bad way for this to fail.
  static const Map<SavedPlaceKind, List<String>> kindSynonyms = {
    SavedPlaceKind.home: ['home', 'house', 'my place', 'বাসা', 'বাড়ি', 'ঘর'],
    SavedPlaceKind.work: ['work', 'office', 'workplace', 'job', 'অফিস', 'কাজ', 'কর্মস্থল'],
    SavedPlaceKind.school: [
      'school',
      'college',
      'university',
      'campus',
      'class',
      'স্কুল',
      'কলেজ',
      'ইউনিভার্সিটি',
      'বিশ্ববিদ্যালয়',
      'ক্লাস',
    ],
    SavedPlaceKind.family: [
      'family',
      'relative',
      'relatives',
      'mother',
      'father',
      'sister',
      'brother',
      'aunt',
      'uncle',
      'আত্মীয়',
      'মা',
      'বাবা',
      'বোন',
      'ভাই',
      'খালা',
      'চাচা',
    ],
    SavedPlaceKind.medical: [
      'doctor',
      'clinic',
      'hospital',
      'therapy',
      'ডাক্তার',
      'ক্লিনিক',
      'হাসপাতাল',
    ],
    SavedPlaceKind.worship: ['mosque', 'masjid', 'temple', 'church', 'মসজিদ', 'মন্দির', 'গির্জা'],
    SavedPlaceKind.other: [],
  };

  /// The saved place [spoken] refers to, or null.
  ///
  /// Returns null on an ambiguous reference rather than picking one. If a
  /// user has saved "Ma's house" and "Bhai's house" and says "take me to
  /// the house", quietly choosing either one and starting to walk them
  /// there is far worse than asking which — they may not notice they are
  /// going to the wrong place until they arrive.
  static SavedPlace? resolve(String spoken, List<SavedPlace> places) {
    final matches = candidates(spoken, places);
    return matches.length == 1 ? matches.first : null;
  }

  /// Every saved place [spoken] could plausibly mean, best evidence first.
  ///
  /// Exposed separately from [resolve] so the assistant can *use* an
  /// ambiguous result — "did you mean Ma's house or Bhai's house?" is a
  /// much better answer than either silence or a coin flip.
  static List<SavedPlace> candidates(String spoken, List<SavedPlace> places) {
    if (places.isEmpty) return const [];
    final words = voiceWords(spoken);
    if (words.isEmpty) return const [];

    // A label match is stronger evidence than a kind-synonym match: the
    // label is what this specific user chose to call this specific place,
    // whereas a synonym is the app guessing at a category. So an exact
    // label hit wins outright and short-circuits the rest — "take me to
    // school" lands on the place actually labelled "school" even if a
    // second place is also of kind `school`.
    final byLabel = places.where((p) => containsTermInflected(words, p.label)).toList();
    if (byLabel.isNotEmpty) return byLabel;

    // Then any individual distinctive word of the label ("Ma's house" ->
    // "ma"), so a user who shortens their own label is still understood.
    final byLabelWord = places.where((p) {
      final labelWords = voiceWords(p.label).where((w) => w.length > 2).toList();
      return labelWords.any((lw) => containsTermInflected(words, lw));
    }).toList();
    if (byLabelWord.isNotEmpty) return byLabelWord;

    return places.where((p) => containsAnyInflected(words, kindSynonyms[p.kind] ?? const [])).toList();
  }

  /// Default spoken suggestions for the onboarding step, so a blind user
  /// hears concrete examples rather than an open-ended "name a place".
  static List<SavedPlaceKind> get suggestedKinds => const [
        SavedPlaceKind.work,
        SavedPlaceKind.school,
        SavedPlaceKind.family,
        SavedPlaceKind.medical,
      ];
}
