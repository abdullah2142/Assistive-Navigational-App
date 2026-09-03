import '../localization/app_language.dart';

/// A function call [LocalIntentMatcher] is confident enough about to run
/// without ever asking Gemini — same shape `FunctionCallExecutor.execute`
/// already expects (see `GeminiAssistantService`'s function-calling `_tools`
/// for what each `name` means and what `args` it needs).
class LocalIntent {
  const LocalIntent(this.name, this.args);
  final String name;
  final Map<String, Object?> args;
}

/// Recognizes the common, high-frequency settings-change and trigger
/// commands locally — entirely offline pattern matching, no network call —
/// so `ChatController` can execute them directly through
/// `FunctionCallExecutor` and skip the Gemini round trip for the cases that
/// don't need a language model's judgment at all. Saves both the latency of
/// a network call and the tokens Gemini would've spent on it, which matters
/// for a chat surface a blind user leans on constantly for routine things
/// like "switch to dark mode" or "show my screen".
///
/// Deliberately conservative: every trigger here is a specific multi-word
/// phrase or an unambiguous pattern (a 6-digit code, a "take me to X"
/// shape), never a single bare word — free-form chat has far more room for
/// an innocent sentence to collide with a bare keyword than the closed
/// option lists onboarding's `OnboardingVoiceChoice.synonyms` matches
/// against (a passing remark like "it's getting dark outside" must never
/// flip the theme). Still generous *within* that — many phrasings per
/// intent, in both languages, mirroring the "wiggle room" already built for
/// onboarding's voice choices — just anchored to phrases that only really
/// come up when that's what's actually meant.
///
/// Returns `null` on anything not confidently matched — including every
/// `add_emergency_contact`/`remove_emergency_contact`/
/// `add_passerby_message`/`remove_passerby_message` request, deliberately
/// never handled locally at all: those need free-text name/phone/message
/// content pulled out of an arbitrary sentence, where a wrong local guess
/// would silently corrupt real contact/message data. Gemini handles those,
/// and anything else this doesn't recognize, exactly as before — this is
/// purely an optional shortcut, not a replacement.
class LocalIntentMatcher {
  LocalIntentMatcher._();

  static LocalIntent? match(String rawText, AppLanguage language) {
    final text = rawText.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    final bn = language == AppLanguage.bangla;

    return _matchPairing(text) ??
        _matchOverlay(lower, text, bn) ??
        _matchBooleanSetting(lower, text) ??
        _matchTheme(lower, text) ??
        _matchLanguage(lower, text) ??
        _matchVerbosity(lower, text) ??
        _matchTextSize(lower, text) ??
        _matchRoute(lower, text, bn);
  }

  // ---- pair_with_caretaker --------------------------------------------

  static final _sixDigits = RegExp(r'(?<!\d)(\d{6})(?!\d)');
  // Deliberately specific, multi-word or otherwise-unambiguous phrases —
  // bare "code" or "pair" alone is too generic (a PIN code, a "pair of
  // shoes" mentioned in passing) and would false-positive on an unrelated
  // 6-digit number in the same message.
  static const _pairingWordsEn = ['pairing code', 'caretaker', 'pair with', 'link up with', 'link with'];
  static const _pairingWordsBn = ['পেয়ারিং কোড', 'দেখাশোনাকারী', 'যুক্ত করো'];

  /// A bare 6-digit number alone isn't enough (could be anything) — also
  /// requires a pairing-flavored word in the same message. Bangladeshi
  /// phone numbers are 10-11 digits, so this doesn't collide with someone
  /// dictating a phone number for a contact.
  static LocalIntent? _matchPairing(String text) {
    final digitsMatch = _sixDigits.firstMatch(text);
    if (digitsMatch == null) return null;
    final lower = text.toLowerCase();
    final hasPairingWord = _pairingWordsEn.any(lower.contains) || _pairingWordsBn.any(text.contains);
    if (!hasPairingWord) return null;
    return LocalIntent('pair_with_caretaker', {'code': digitsMatch.group(1)});
  }

  // ---- open_passerby_helper / open_hazard_report ------------------------

  static const _showScreenEn = [
    'show my screen',
    'show screen',
    'show this to',
    'display my screen',
    'show them my screen',
  ];
  static const _showScreenBn = [
    'স্ক্রিন দেখাও',
    'স্ক্রীন দেখাও',
    'আমার স্ক্রিন দেখাও',
    'স্ক্রিন দেখান',
  ];
  static const _hazardEn = [
    'report a hazard',
    'report hazard',
    'report danger',
    'report an unsafe',
    'report this hazard',
    'report a problem',
  ];
  static const _hazardBn = [
    'বিপদ জানাও',
    'বিপদ রিপোর্ট করো',
    'বিপদের কথা জানাও',
    'সমস্যা জানাও',
  ];

  static LocalIntent? _matchOverlay(String lower, String text, bool bn) {
    if (_showScreenEn.any(lower.contains) || _showScreenBn.any(text.contains)) {
      return const LocalIntent('open_passerby_helper', {});
    }
    if (_hazardEn.any(lower.contains) || _hazardBn.any(text.contains)) {
      return const LocalIntent('open_hazard_report', {});
    }
    return null;
  }

  // ---- boolean update_setting (wake word, auto-listen, deaf/hearing,
  // crowded/complex sensitivity) -----------------------------------------

  /// `(settingKey, onPhrasesEn, onPhrasesBn, offPhrasesEn, offPhrasesBn)`
  /// tuples — every boolean setting shares the same "turn on X" / "turn off
  /// X" shape, so one table drives all of them instead of near-duplicate
  /// per-setting matchers.
  static final _booleanSettings = <({
    String setting,
    List<String> onEn,
    List<String> onBn,
    List<String> offEn,
    List<String> offBn,
  })>[
    (
      setting: 'wake_word_enabled',
      onEn: ['turn on hey ant', 'enable wake word', 'activate hey ant', 'enable hey ant', 'turn on the wake word'],
      onBn: ['হে অ্যান্ট চালু করো', 'ওয়েক ওয়ার্ড চালু করো', 'হে অ্যান্ট চালু কর'],
      offEn: ['turn off hey ant', 'disable wake word', 'deactivate hey ant', 'disable hey ant', 'turn off the wake word'],
      offBn: ['হে অ্যান্ট বন্ধ করো', 'ওয়েক ওয়ার্ড বন্ধ করো', 'হে অ্যান্ট বন্ধ কর'],
    ),
    (
      setting: 'voice_auto_listen',
      onEn: ['turn on auto listen', 'enable auto listen', 'listen automatically', 'auto listen on'],
      onBn: ['অটো লিসেন চালু করো', 'নিজে থেকে শোনা চালু করো'],
      offEn: ['turn off auto listen', 'disable auto listen', 'stop listening automatically', 'auto listen off'],
      offBn: ['অটো লিসেন বন্ধ করো', 'নিজে থেকে শোনা বন্ধ করো'],
    ),
    (
      setting: 'crowded_places_anxious',
      onEn: ['crowded places make me anxious', 'i get anxious in crowds', 'i am anxious in crowded places'],
      onBn: ['ভিড়ে আমার অস্বস্তি লাগে', 'ভিড়ে অস্বস্তি হয়'],
      offEn: ["crowded places don't bother me", 'i am fine in crowds', "crowds don't make me anxious"],
      offBn: ['ভিড়ে অস্বস্তি লাগে না', 'ভিড়ে সমস্যা নেই'],
    ),
    (
      setting: 'complex_instructions_hard',
      onEn: ['complex instructions are hard', 'simple instructions please', 'keep instructions simple'],
      onBn: ['জটিল নির্দেশ বুঝতে কষ্ট হয়', 'সহজ করে বলো'],
      offEn: ['complex instructions are fine', 'i can follow complex instructions'],
      offBn: ['জটিল নির্দেশ বুঝতে পারি', 'কোনো সমস্যা নেই নির্দেশে'],
    ),
    (
      setting: 'deaf_hearing_mode',
      onEn: ["i can't hear well", 'i am hard of hearing', 'i am deaf', 'switch to text mode'],
      onBn: ['কানে শুনি না', 'কম শুনি', 'লেখা মোডে দাও'],
      offEn: ['i can hear fine', 'my hearing is fine', 'i hear normally'],
      offBn: ['শুনতে পাই', 'শোনায় সমস্যা নেই'],
    ),
  ];

  static LocalIntent? _matchBooleanSetting(String lower, String text) {
    for (final s in _booleanSettings) {
      if (s.onEn.any(lower.contains) || s.onBn.any(text.contains)) {
        return LocalIntent('update_setting', {'setting': s.setting, 'value': 'true'});
      }
      if (s.offEn.any(lower.contains) || s.offBn.any(text.contains)) {
        return LocalIntent('update_setting', {'setting': s.setting, 'value': 'false'});
      }
    }
    return null;
  }

  // ---- theme -------------------------------------------------------------

  static const _darkEn = ['dark mode', 'dark theme', 'switch to dark', 'turn on dark', 'make it dark', 'go dark', 'enable dark mode'];
  static const _darkBn = ['ডার্ক মোড', 'গাঢ় থিম', 'গাঢ় করে দাও', 'গাঢ় করো', 'কালো থিম', 'অন্ধকার মোড'];
  static const _lightEn = ['light mode', 'light theme', 'switch to light', 'turn on light', 'make it light', 'enable light mode'];
  static const _lightBn = ['লাইট মোড', 'হালকা থিম', 'হালকা করে দাও', 'হালকা করো'];

  static LocalIntent? _matchTheme(String lower, String text) {
    if (_darkEn.any(lower.contains) || _darkBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'theme', 'value': 'dark'});
    }
    if (_lightEn.any(lower.contains) || _lightBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'theme', 'value': 'light'});
    }
    return null;
  }

  // ---- language ------------------------------------------------------

  static const _toBanglaEn = ['switch to bangla', 'speak bangla', 'change language to bangla', 'speak in bangla', 'reply in bangla'];
  static const _toBanglaBn = ['বাংলায় বলো', 'বাংলা ভাষা করো', 'ভাষা বাংলা করো', 'বাংলায় কথা বলো'];
  static const _toEnglishEn = ['switch to english', 'speak english', 'change language to english', 'speak in english', 'reply in english'];
  static const _toEnglishBn = ['ইংরেজি বলো', 'ইংরেজিতে বলো', 'ভাষা ইংরেজি করো', 'ইংরেজিতে কথা বলো'];

  static LocalIntent? _matchLanguage(String lower, String text) {
    if (_toBanglaEn.any(lower.contains) || _toBanglaBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'language', 'value': 'bangla'});
    }
    if (_toEnglishEn.any(lower.contains) || _toEnglishBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'language', 'value': 'english'});
    }
    return null;
  }

  // ---- verbosity -------------------------------------------------------

  static const _minimalistEn = ['keep it short', 'be brief', 'short answers', 'less talking', 'be more minimal', 'shorter replies'];
  static const _minimalistBn = ['সংক্ষেপে বলো', 'কম কথা বলো', 'ছোট করে বলো', 'সংক্ষিপ্ত করো'];
  static const _descriptiveEn = ['more detail', 'explain more', 'be more descriptive', 'give me detail', 'talk more', 'longer replies'];
  static const _descriptiveBn = ['বিস্তারিত বলো', 'বেশি করে বলো', 'খুলে বলো', 'বিস্তারিত করো'];

  static LocalIntent? _matchVerbosity(String lower, String text) {
    if (_minimalistEn.any(lower.contains) || _minimalistBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'verbosity', 'value': 'minimalist'});
    }
    if (_descriptiveEn.any(lower.contains) || _descriptiveBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'verbosity', 'value': 'descriptive'});
    }
    return null;
  }

  // ---- text size (relative bump, not an absolute value — this matcher
  // never knows the current profile's fontScale, so it can't compute one;
  // `ChatController` resolves the actual new number from the live profile
  // before calling the executor) ------------------------------------------

  static const _biggerEn = ['bigger text', 'increase text size', 'make text bigger', 'larger text', 'text size up', 'make the text bigger'];
  static const _biggerBn = ['লেখা বড় করো', 'লেখার আকার বাড়াও', 'লেখা বড় কর'];
  static const _smallerEn = ['smaller text', 'decrease text size', 'make text smaller', 'text size down', 'make the text smaller'];
  static const _smallerBn = ['লেখা ছোট করো', 'লেখার আকার কমাও', 'লেখা ছোট কর'];

  static LocalIntent? _matchTextSize(String lower, String text) {
    if (_biggerEn.any(lower.contains) || _biggerBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'text_size', 'value': '_bigger'});
    }
    if (_smallerEn.any(lower.contains) || _smallerBn.any(text.contains)) {
      return const LocalIntent('update_setting', {'setting': 'text_size', 'value': '_smaller'});
    }
    return null;
  }

  // ---- request_route -----------------------------------------------------

  static final _routeEnPattern = RegExp(
    r'\b(?:take me to|route me to|route to|navigate to|directions? to|walk me to|guide me to|i want to go to|i need to go to)\s+(.+)',
    caseSensitive: false,
  );

  /// Bangla place names commonly carry the destination postposition
  /// attached (গুলশানে, ধানমন্ডিতে) right before a "go" verb — captured
  /// with the postposition still attached rather than trying to strip it,
  /// since `RoutingService`'s Nominatim geocoding is itself forgiving of
  /// that (fuzzy place-name search), and stripping it wrong risks mangling
  /// the actual place name. Only the affirmative "going" verbs — not "নিয়ে
  /// চলো/যাও" ("take this/them"), which is ambiguous with "take this
  /// object somewhere" and isn't reliably about *the user* travelling.
  static final _routeBnPattern = RegExp(r'(.+?)\s*(?:যেতে চাই|যাব|যাবো)');

  /// "আমি অফিসে যাব না" (I will *not* go to the office) must not trigger a
  /// route request — a bare "না" (not/no) anywhere close to the go-verb is
  /// treated as negation and the whole message is skipped rather than
  /// risking routing somewhere the user just said they're *not* going.
  static bool _isNegatedBn(String text) => text.contains('না');

  static LocalIntent? _matchRoute(String lower, String text, bool bn) {
    final enMatch = _routeEnPattern.firstMatch(text);
    if (enMatch != null) {
      final destination = enMatch.group(1)!.trim();
      if (destination.isNotEmpty) return LocalIntent('request_route', {'destination': destination});
    }
    if (bn && !_isNegatedBn(text)) {
      final bnMatch = _routeBnPattern.firstMatch(text);
      if (bnMatch != null) {
        final destination = bnMatch.group(1)!.trim();
        if (destination.isNotEmpty && destination.length <= 40) {
          return LocalIntent('request_route', {'destination': destination});
        }
      }
    }
    return null;
  }
}
