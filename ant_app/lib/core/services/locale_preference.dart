/// Which regional variant of a language to ask the device for.
///
/// ## The bug this exists to stop happening twice
///
/// Android reports its installed locales and voices in an order that is
/// alphabetical, or simply unspecified. Taking the first entry whose
/// language matches therefore looks harmless and is not: on the Redmi 10C
/// this was found on, the recognizer list begins `en_AU, en_CA, en_IN, …`
/// and the voice list begins `en-AU-language`. So every English-speaking
/// user in Dhaka was being **listened to** by an Australian English model
/// and **spoken to** in an Australian English voice.
///
/// Both bugs are the same bug, written twice, which is why the ordering
/// lives here rather than in either service. A fix applied to one and not
/// the other is worse than no fix, because it makes the remaining half
/// harder to notice.
///
/// ## Why this order
///
/// Bangladeshi English is South Asian in its vowels and rhythm, so `en_IN`
/// is by a wide margin the closest available model, and the most
/// intelligible voice to listen to for hours. `en_GB` comes next —
/// Bangladeshi English is British-derived and Dhaka place names are
/// romanised on British conventions — ahead of the American and Antipodean
/// variants.
///
/// This matters more here than in most apps. Every command is spoken, the
/// users cannot see a mistranscription in order to correct it, and the
/// words most likely to be mangled are Dhaka place names — the exact input
/// that has to be right for routing to work at all.
library;

/// Regional subtags to prefer, best first, keyed by language subtag.
const Map<String, List<String>> kRegionPreference = {
  'en': ['in', 'gb', 'us', 'bd'],
  // Bangladeshi Bangla first, then Indian Bangla — different enough in
  // vocabulary and pronunciation to be worth ordering, and close enough
  // that either beats falling back to the system default.
  'bn': ['bd', 'in'],
};

/// `en_AU`, `en-AU` and `EN-au` all normalise to `en_au`.
String normaliseLocaleId(String id) => id.toLowerCase().replaceAll('-', '_').trim();

/// The language subtag of [id] — `en` for `en_AU`.
String languageOf(String id) => normaliseLocaleId(id).split('_').first;

/// The region subtag of [id], or empty when it has none.
String regionOf(String id) {
  final parts = normaliseLocaleId(id).split('_');
  return parts.length > 1 ? parts[1] : '';
}

/// The best id in [available] for [prefix], or null if none match.
///
/// Falls back to the first id of the right language when no preferred
/// region is present — any Bangla at all beats no Bangla, and an
/// unrecognised English region beats the system default. Ids are returned
/// **verbatim**, not normalised, because the platform has to be handed back
/// the exact string it gave us.
String? pickPreferredLocale(List<String> available, String prefix) {
  final language = languageOf(prefix);
  final wanted = kRegionPreference[language] ?? const [];

  for (final region in wanted) {
    for (final id in available) {
      if (languageOf(id) == language && regionOf(id) == region) return id;
    }
  }
  for (final id in available) {
    if (languageOf(id) == language) return id;
  }
  return null;
}
