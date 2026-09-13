import '../localization/app_language.dart';
import 'voice_matching.dart';

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

  /// Bangla negation particles, as *whole words*.
  ///
  /// Bangla negates after the verb ("যাব না" — "will go not"), so a
  /// negation particle sits at the end of the very phrase being matched,
  /// where a plain `contains` check cannot see it: "শুনতে পাই" ("I can
  /// hear") is a literal prefix of "শুনতে পাই না" ("I cannot hear"), so
  /// the affirmative phrase list matched the negative sentence and set the
  /// setting to the exact opposite of what was said. English negates
  /// *before* the verb ("i am not deaf" does not contain "i am deaf"), so
  /// it is naturally immune to this and needs no equivalent handling.
  static const _bnNegationParticles = {'না', 'নাই', 'নেই', 'নয়', 'নি'};

  /// Whole *word*, never a substring. "না" is also the first two characters
  /// of a great many ordinary Bangla words — including real Dhaka-area
  /// place names a user will absolutely ask to be routed to (নারায়ণগঞ্জ /
  /// Narayanganj, নাখালপাড়া / Nakhalpara, নারিন্দা / Narinda). Treating a
  /// bare substring as negation silently swallowed every one of those route
  /// requests. Same lesson as `fuzzyVoiceMatch`'s "male" inside "female".
  static final _tokenSplit = RegExp(r'\s+');
  static final _stripPunctuation = RegExp(r'[।?!.,;:\u0964\u0965"\u2018\u2019\u201c\u201d]');

  static Iterable<String> _words(String text) =>
      text.split(_tokenSplit).map((w) => w.replaceAll(_stripPunctuation, '')).where((w) => w.isNotEmpty);

  /// [recentSetting] is the setting the user most recently changed, if any.
  ///
  /// It exists so a follow-up can lean on the conversation instead of
  /// repeating itself. "Make the text bigger" then "even bigger" is how
  /// people actually adjust things — but the second sentence has no word
  /// naming *what* to enlarge, so the context requirement that stops
  /// "it's getting dark outside" from flipping the theme also rejected it,
  /// and the user was told nothing had been understood.
  ///
  /// Reported from real use. The relaxation is narrow on purpose: it only
  /// applies to the one setting that was just changed, so a bare
  /// comparative can never reach a setting the user was not already
  /// talking about.
  static LocalIntent? match(String rawText, AppLanguage language, {String? recentSetting}) {
    final text = rawText.trim();
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();
    final bn = language == AppLanguage.bangla;

    // Emergency genuinely first. This used to sit below `_matchFollowUp`,
    // which contradicted its own comment and meant that after any text-size
    // change "help me again" resized the font instead of sending an SOS —
    // 'again' is in the follow-up vocabulary.
    final sos = _matchEmergency(lower, text);
    if (sos != null) return sos;

    final followUp = _matchFollowUp(text, recentSetting);
    if (followUp != null) return followUp;

    // Checked before everything else. An emergency phrase must not be able
    // to lose a race to some other matcher that happens to share a word,
    // and it is the one intent where a slower answer is a worse answer.
    return _matchPairing(text) ??
        _matchResolveHazard(lower, text) ??
        _matchOverlay(lower, text, bn) ??
        _matchBooleanSetting(lower, text) ??
        _matchTheme(lower, text) ??
        _matchLanguage(lower, text) ??
        _matchVerbosity(lower, text) ??
        _matchTextSize(lower, text) ??
        // Before `_matchRoute`: "show me a different route" contains
        // "route", and answering it by planning a fresh journey to nowhere
        // is not what was asked.
        // Before `_matchRouteChange`: "cancel the route" contains "the
        // route", and before `_matchRoute` for the same reason.
        _matchCancelRoute(lower, text) ??
        _matchRouteChange(lower, text) ??
        _matchRoute(lower, text, bn);
  }

  // ---- pair_with_caretaker --------------------------------------------

  // ---- emergency (Module 9) -------------------------------------------

  /// Phrases that mean an emergency on their own, wherever they appear.
  ///
  /// Both languages are always live, because someone frightened does not
  /// reliably reach for the language their app is set to, and a `bn-BD`
  /// recognizer transcribes a shouted English "help" in Bangla script —
  /// hence `হেল্প` alongside `help`.
  static const _emergencyStrong = [
    'emergency', 'sos', 'save me', 'help help', 'i am in danger', "i'm in danger",
    'বাঁচাও', 'বাঁচান', 'বিপদে পড়েছি', 'জরুরি অবস্থা', 'হেল্প হেল্প',
  ];

  /// Phrases that mean an emergency *only* in the right company.
  ///
  /// "Help me" is the most common opening line to any voice assistant —
  /// "can you help me", "help me put on my shoes", "help me with the
  /// volume" — and firing an SOS on it would message and telephone the
  /// user's family because they asked for something ordinary. It is also
  /// exactly what someone shouts when they are in trouble. The word cannot
  /// carry the decision alone.
  static const _emergencyWeak = [
    'help me', 'i need help', 'need help', 'call for help', 'help',
    'সাহায্য করো', 'সাহায্য করুন', 'সাহায্য', 'হেল্প',
  ];

  /// A weak phrase counts when the whole utterance is barely more than it.
  ///
  /// "Help me" and "help me please" are cries. "Can you help me" is four
  /// words and a question. Three is the line between them.
  static const int _maxBareCryWords = 3;

  /// Words that do not make a cry any less of a cry.
  ///
  /// Reported from the device: *"sentence er moddhe help me thakle trigger
  /// korche na"* — a call for help inside a sentence does not fire. Measured,
  /// and the cases that missed were not sentences at all, they were the same
  /// two-word cry wearing politeness:
  ///
  ///   `কেউ আমাকে সাহায্য করো`   somebody help me      — 4 words, missed
  ///   `আমাকে একটু সাহায্য করো`  help me a little      — 4 words, missed
  ///
  /// English hides this because "help me" already contains its pronoun and
  /// "please" was inside the cap. Bangla puts the pronoun and the softener in
  /// separate words, so ordinary politeness pushed every one of these over a
  /// line drawn against *errands*, which they are not.
  ///
  /// Stripped before counting rather than raising the cap, because the cap is
  /// doing real work: `সাহায্য করো গুলশান যেতে` ("help me get to Gulshan") and
  /// "help me find a pharmacy" are both four content words and both must stay
  /// out. Politeness is not content.
  /// Politeness and vocatives only — deliberately no pronouns and no
  /// articles. "Help me find a pharmacy" is an errand, and it survives the
  /// cap only because `me` and `a` are counted: drop those and an errand
  /// becomes a three-word cry. `আমাকে` stays counted for the same reason.
  static const _cryFiller = {
    'please', 'plz', 'someone', 'somebody', 'anyone', 'anybody', 'kindly',
    'just', 'oh', 'hey', 'ant',
    'একটু', 'কেউ', 'কেউই', 'একজন', 'দয়া', 'করে', 'প্লিজ',
  };

  /// How long the cry is once politeness is taken out of it.
  static int _cryLength(Iterable<String> spoken) =>
      spoken.where((w) => !_cryFiller.contains(w)).length;

  /// Or when something else in the sentence says this is not an errand.
  ///
  /// Overwhelmingly these are statements about what the speaker *cannot*
  /// do — which is why negation cannot be used to veto an emergency, and
  /// is closer to evidence for one.
  static const _distressContext = [
    "can't", 'cant', 'cannot', 'unable', 'stuck', 'trapped', 'lost',
    'hurt', 'hurts', 'bleeding', 'blood', 'fell', 'fallen', 'broken',
    'attacked', 'attacking', 'following', 'followed', 'chasing', 'grabbed',
    'danger', 'dangerous', 'scared', 'afraid', 'someone', 'somebody',
    'breathe', 'breathing', 'dizzy', 'faint', 'pain', 'police', 'ambulance',
    // Being taken. Safe to treat as distress even though it shares words
    // with routing, because 'take me to' is an errand phrase and is
    // checked before this — so "take me to Gulshan" never reaches here,
    // and "they are trying to take me" does.
    'take me', 'taking me', 'trying to', 'pulling me', 'dragging',
    // Lost and frightened. A blind user who does not know where they are is
    // the specific case this app exists for, and it was silent.
    'know where', 'where i am', 'where am i', 'no idea where',
    'পারছি না', 'পাচ্ছি না', 'বিপদ', 'ভয়', 'পড়ে গেছি', 'আটকে', 'রক্ত',
    'ব্যথা', 'পিছু', 'ধরেছে', 'মারছে', 'পুলিশ', 'অ্যাম্বুলেন্স', 'কেউ নেই',
    'নিয়ে যাচ্ছে', 'টানছে', 'কোথায় আছি', 'হারিয়ে', 'জানি না কোথায়',
  ];

  /// Explicit refusals of help — the only negation that vetoes.
  ///
  /// The previous veto was any negation anywhere in the sentence, which
  /// silently killed the most common distress sentences in both languages:
  /// "help me I can't breathe" and `বাঁচাও আমি নড়তে পারছি না` ("save me, I
  /// can't move") both returned nothing at all. Bangla marks negation
  /// post-verbally, so the particle this code was carefully taught to find
  /// sits at the end of precisely the sentences that matter most.
  ///
  /// Refusing help is a narrow, specific thing to say, so it is matched
  /// narrowly and specifically.
  static const _emergencyRefusals = [
    "don't need help", 'do not need help', 'dont need help', 'no help needed',
    "don't need any help", 'not an emergency', 'no emergency', 'false alarm',
    "i'm fine", 'im fine', 'i am fine', "i'm okay", 'i am okay', 'im ok',
    'সাহায্য লাগবে না', 'সাহায্য দরকার নেই', 'দরকার নেই', 'বিপদ নেই', 'ঠিক আছি',
  ];

  /// Ways of asking *about* the feature rather than using it.
  static const _emergencyQuestionBlockers = [
    'what happens', 'what if', 'if i say', 'when i say', 'is this', 'is that',
    'how do i', 'how does', 'what does', 'supposed to', 'for testing',
    'কী হবে', 'কি হবে', 'বললে কী', 'বললে কি',
  ];

  /// Words that make the utterance an errand or a settings change.
  ///
  /// Note what is absent: 'take me', which was here to catch "take me to
  /// Gulshan" and also suppressed "help me they are trying to take me".
  /// The destination words below catch the routing case on their own, and
  /// being taken somewhere against your will is the thing this feature is
  /// for.
  static const _emergencyErrandWords = [
    'volume', 'shoes', 'settings', 'setting', 'font', 'text', 'theme',
    'ordering', 'order', 'read', 'spell', 'remind', 'reminder',
    'add', 'remove', 'delete', 'edit', 'setup', 'card',
    'সেটিং', 'লেখা', 'ফন্ট', 'যোগ', 'মুছে',
  ];

  static const _emergencyErrandPhrases = [
    'get to', 'go to', 'route to', 'directions', 'navigate', 'take me to',
    'save my', 'save this', 'save as', 'set up', 'change my', 'turn off',
    'turn on', 'switch off', 'switch on', 'message saying', 'emergency contact',
    'যেতে চাই', 'যাব', 'যাবো',
  ];

  /// True when [text] is a call for help rather than a mention of one.
  static LocalIntent? _matchEmergency(String lower, String text) {
    final strong = _emergencyStrong.any(lower.contains) || _emergencyStrong.any(text.contains);
    final weak = _emergencyWeak.any(lower.contains) || _emergencyWeak.any(text.contains);
    if (!strong && !weak) return null;

    if (_emergencyRefusals.any(lower.contains) || _emergencyRefusals.any(text.contains)) {
      return null;
    }
    if (kQuestionBlockers.any(lower.contains)) return null;
    if (_emergencyQuestionBlockers.any(lower.contains) ||
        _emergencyQuestionBlockers.any(text.contains)) {
      return null;
    }
    if (_emergencyErrandPhrases.any(lower.contains) ||
        _emergencyErrandPhrases.any(text.contains)) {
      return null;
    }

    final spoken = voiceWords(text);
    if (_emergencyErrandWords.any(spoken.contains)) return null;

    // An unmistakable word carries a whole sentence. A merely-possible one
    // needs either brevity or something else that says this is not an
    // errand.
    if (strong) return const LocalIntent('trigger_emergency', {});
    final hasDistress =
        _distressContext.any(lower.contains) || _distressContext.any(text.contains);
    if (hasDistress || _cryLength(spoken) <= _maxBareCryWords) {
      return const LocalIntent('trigger_emergency', {});
    }
    return null;
  }

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

  /// Named hazards, so "report an open manhole" opens the Reporting Hub
  /// *on that hazard* instead of at the top of a three-level menu — Step 1
  /// of `05_module_plan_crowdsourcing.md` ("without breaking their stride").
  ///
  /// Keys are the same stable `subCategory` identities
  /// `Dashboard.hazardSubCategoryKeys` uses and `HazardReport` stores. Only
  /// hazards with a distinctive, unmistakable name are listed: "pothole"
  /// and "manhole" are only ever one thing, whereas a bare "blocked" or
  /// "broken" could mean any of several sub-categories, and guessing wrong
  /// files a real report under the wrong hazard type — which then clusters
  /// with the wrong reports and decays on the wrong schedule.
  static const _namedHazards = <({String category, String subCategory, List<String> en, List<String> bn})>[
    (category: 'crime', subCategory: 'mugging', en: ['mugging', 'mugged', 'robbery'], bn: ['ছিনতাই']),
    (category: 'crime', subCategory: 'harassment', en: ['harassment', 'harassed'], bn: ['উত্যক্ত']),
    (category: 'crime', subCategory: 'stalking', en: ['stalking', 'being followed'], bn: ['পিছু নিচ্ছে', 'পিছু নেওয়া']),
    (category: 'crime', subCategory: 'poorLighting', en: ['no street light', 'poor lighting', 'no lighting'], bn: ['রাস্তায় আলো নেই']),
    (category: 'roadHazard', subCategory: 'openManhole', en: ['open manhole', 'manhole'], bn: ['ম্যানহোল']),
    (category: 'roadHazard', subCategory: 'pothole', en: ['pothole', 'broken road'], bn: ['গর্ত', 'রাস্তা ভাঙা']),
    (category: 'roadHazard', subCategory: 'flooding', en: ['flooding', 'waterlogging', 'water logged'], bn: ['পানি জমে']),
    (category: 'roadHazard', subCategory: 'construction', en: ['construction'], bn: ['নির্মাণকাজ']),
    (category: 'roadHazard', subCategory: 'debrisFallenTree', en: ['fallen tree'], bn: ['গাছ পড়ে']),
    (category: 'accessibilityBlock', subCategory: 'stairsOnly', en: ['stairs only', 'only stairs', 'no ramp'], bn: ['শুধু সিঁড়ি', 'র‍্যাম্প নেই']),
    (category: 'accessibilityBlock', subCategory: 'brokenRamp', en: ['broken ramp'], bn: ['ঢালু পথ ভাঙা']),
    (category: 'accessibilityBlock', subCategory: 'noCurbCut', en: ['no curb cut', 'no kerb cut'], bn: ['ঢালু পথ নেই']),
    (category: 'accessibilityBlock', subCategory: 'blockedByVendors', en: ['vendors blocking', 'blocked by vendors', 'hawkers'], bn: ['হকার']),
  ];

  /// Verbs that turn a hazard *mention* into a hazard *report*.
  ///
  /// Required, and that requirement is the whole safeguard here: without it
  /// "is there a manhole near me?" would file a report about a manhole the
  /// user was only asking about. Reports feed a system that closes roads
  /// for other people, so a false one costs more than a missed one.
  static const _reportVerbsEn = ['report', 'flag', 'there is a', "there's a", 'there is an', "there's an", 'i see a', 'i see an'];
  static const _reportVerbsBn = ['জানাও', 'রিপোর্ট', 'আছে'];

  static LocalIntent? _matchOverlay(String lower, String text, bool bn) {
    if (_showScreenEn.any(lower.contains) || _showScreenBn.any(text.contains)) {
      return const LocalIntent('open_passerby_helper', {});
    }

    final isReport = _reportVerbsEn.any(lower.contains) || _reportVerbsBn.any(text.contains);
    if (isReport) {
      for (final hazard in _namedHazards) {
        if (hazard.en.any(lower.contains) || hazard.bn.any(text.contains)) {
          return LocalIntent('open_hazard_report', {
            'category': hazard.category,
            'subCategory': hazard.subCategory,
          });
        }
      }
    }

    if (_hazardEn.any(lower.contains) || _hazardBn.any(text.contains)) {
      return const LocalIntent('open_hazard_report', {});
    }
    return null;
  }

  // ---- follow-up ("even bigger", "a bit more") --------------------------

  /// Bare comparatives, per setting and direction. Matched only when that
  /// same setting was the last one changed.
  static const _followUps = <({String setting, String value, List<String> words})>[
    (setting: 'text_size', value: '_bigger', words: [
      'bigger', 'even bigger', 'larger', 'more', 'a bit more', 'again', 'increase',
      'বড়', 'আরও বড়', 'আরেকটু', 'আরও',
    ]),
    (setting: 'text_size', value: '_smaller', words: [
      'smaller', 'even smaller', 'less', 'a bit less', 'decrease',
      'ছোট', 'আরও ছোট', 'কম',
    ]),
    (setting: 'verbosity', value: 'minimalist', words: [
      'shorter', 'even shorter', 'less', 'briefer', 'সংক্ষেপে', 'আরও ছোট', 'কম',
    ]),
    (setting: 'verbosity', value: 'descriptive', words: [
      'longer', 'more', 'even more', 'more detail', 'বিস্তারিত', 'আরও', 'বেশি',
    ]),
  ];

  /// A follow-up has to be *short*. "Even bigger" is an adjustment;
  /// "bigger crowds make me anxious" is a sentence that happens to contain
  /// the word, and treating it as one would resize the user's text for no
  /// reason they could connect to anything they said.
  static const int _maxFollowUpWords = 4;

  static LocalIntent? _matchFollowUp(String text, String? recentSetting) {
    if (recentSetting == null) return null;
    final words = voiceWords(text);
    if (words.isEmpty || words.length > _maxFollowUpWords) return null;
    if (containsAny(words, kQuestionBlockers) || containsAny(words, kAllNegations)) return null;

    // Both directions of the same setting present ("bigger or smaller?") is
    // a question, not an instruction.
    final hits = _followUps
        .where((f) => f.setting == recentSetting && containsAny(words, f.words))
        .toList();
    if (hits.length != 1) return null;
    return LocalIntent('update_setting', {'setting': hits.first.setting, 'value': hits.first.value});
  }

  // ---- resolve_hazard ----------------------------------------------------

  /// "It's fixed" — the only way a structural block (stairs with no ramp, a
  /// missing curb cut) ever leaves the map, since those deliberately never
  /// decay on a timer. See `functions/lib/hazard_decay.js`.
  ///
  /// Matched before [_matchOverlay] so "the broken ramp is fixed" clears
  /// the hazard rather than opening a form to report it again — the phrase
  /// contains a named hazard *and* a resolution, and only one of those two
  /// readings is what anybody means by it.
  static const _resolvedEn = [
    'it is fixed',
    "it's fixed",
    'it has been fixed',
    // Bare "is fixed" rather than only "it is fixed": people name the thing
    // ("the broken ramp is fixed"), which is also exactly the phrasing that
    // contains a hazard name and would otherwise fall through to opening a
    // report form for the hazard they just said was gone.
    'is fixed',
    'are fixed',
    'has been fixed',
    'been repaired',
    'is repaired',
    'it is clear now',
    'the path is clear',
    'not there any more',
    'not there anymore',
    'no longer there',
  ];
  static const _resolvedBn = [
    'ঠিক হয়ে গেছে',
    'সারানো হয়েছে',
    'আর নেই',
    'পথ পরিষ্কার',
  ];

  static LocalIntent? _matchResolveHazard(String lower, String text) {
    if (_resolvedEn.any(lower.contains) || _resolvedBn.any(text.contains)) {
      return const LocalIntent('resolve_hazard', {});
    }
    return null;
  }

  // ---- boolean update_setting (wake word, auto-listen, deaf/hearing,
  // crowded/complex sensitivity) -----------------------------------------

  /// `(settingKey, onPhrasesEn, onPhrasesBn, offPhrasesEn, offPhrasesBn)`
  /// tuples — every boolean setting shares the same "turn on X" / "turn off
  /// X" shape, so one table drives all of them instead of near-duplicate
  /// per-setting matchers.
  /// Settings that are simply on or off. Split into *what* is being
  /// toggled and *which way*, instead of enumerating every
  /// "turn on X"/"disable X" sentence: the two are independent, so one
  /// subject list crossed with one polarity list covers far more phrasings
  /// than any hand-written sentence list ever did. "disable the wake word"
  /// used to miss purely because of the word "the".
  static const _toggleSettings = <({String setting, VoicePhrase subject})>[
    (
      setting: 'wake_word_enabled',
      // "Hey Jarvis" first, because that is what the bundled model actually
      // listens for (`assets/wakeword/hey_jarvis_v0.1.tflite`) and therefore
      // what a user has been told to say. "Hey ANT" was here on the
      // assumption the wake phrase would be renamed to match the app; it has
      // not been, so a user who says "turn off Hey Jarvis" — the only name
      // they have ever heard — was matching nothing at all.
      subject: VoicePhrase(anchors: [
        'hey jarvis', 'jarvis', 'হেই জার্ভিস', 'জার্ভিস',
        'hey ant', 'wake word', 'wakeword', 'wake-word',
        'হে অ্যান্ট', 'ওয়েক ওয়ার্ড',
      ]),
    ),
    (
      setting: 'voice_auto_listen',
      subject: VoicePhrase(anchors: [
        'auto listen', 'autolisten', 'automatic listening', 'listen automatically',
        'অটো লিসেন', 'নিজে থেকে শোনা',
      ]),
    ),
  ];

  static const _onWords = ['on', 'enable', 'enabled', 'activate', 'start', 'switch on', 'চালু'];
  static const _offWords = [
    'off', 'disable', 'disabled', 'deactivate', 'stop', 'switch off', 'turn off', 'বন্ধ',
  ];

  static LocalIntent? _matchToggle(List<String> words) {
    for (final entry in _toggleSettings) {
      if (!entry.subject.matches(words)) continue;
      // Both or neither polarity present is not something to guess at —
      // "should I turn the wake word on or off?" is a question.
      final value = exclusive(
        words,
        const VoicePhrase(anchors: _onWords),
        'true',
        const VoicePhrase(anchors: _offWords),
        'false',
      );
      if (value == null) return null;
      return LocalIntent('update_setting', {'setting': entry.setting, 'value': value});
    }
    return null;
  }

  /// Settings the user states as a fact about themselves rather than
  /// toggling.
  ///
  /// Each side is a *list* of phrasings, because a trait can be stated in
  /// genuinely different shapes — "I am deaf" names the trait directly,
  /// while "I can't hear well" states its opposite and negates it. Both
  /// mean the same thing and neither can be expressed as the other.
  ///
  /// Each side carries the other's negations as blockers, which is what
  /// keeps Bangla's post-verbal negation from inverting the answer: "শুনতে
  /// পাই" ("I can hear") is a literal prefix of "শুনতে পাই না" ("I cannot
  /// hear"), and matching the affirmative list on the negative sentence set
  /// a Deaf user's accommodation to exactly the wrong value.
  static const _traitSettings = <({String setting, List<VoicePhrase> present, List<VoicePhrase> absent})>[
    (
      setting: 'deaf_hearing_mode',
      present: [
        VoicePhrase(anchors: ['deaf', 'text mode', 'বধির', 'লেখা মোড']),
        VoicePhrase(
          anchors: ['hear', 'hearing', 'শুনি', 'শুনতে'],
          context: [
            ...kAllNegations,
            'hard', 'trouble', 'difficulty', 'difficult', 'problem', 'issue', 'poor', 'badly',
            'কষ্ট', 'সমস্যা', 'কম',
          ],
          requireContext: true,
        ),
      ],
      absent: [
        VoicePhrase(
          anchors: ['hear', 'hearing', 'শুনি', 'শুনতে'],
          context: ['fine', 'well', 'good', 'normal', 'normally', 'okay', 'ok', 'ঠিক', 'ভালো', 'স্বাভাবিক', 'পাই'],
          requireContext: true,
          blockers: kAllNegations,
        ),
      ],
    ),
    (
      setting: 'crowded_places_anxious',
      present: [
        VoicePhrase(
          anchors: ['anxious', 'anxiety', 'panic', 'nervous', 'uncomfortable', 'অস্বস্তি', 'ভয়'],
          context: ['crowd', 'crowds', 'crowded', 'busy', 'ভিড়', 'জনসমাগম'],
          requireContext: true,
          blockers: kAllNegations,
        ),
      ],
      absent: [
        VoicePhrase(
          anchors: ['fine', 'okay', 'ok', 'comfortable', 'ঠিক', 'সমস্যা নেই'],
          context: ['crowd', 'crowds', 'crowded', 'busy', 'ভিড়'],
          requireContext: true,
        ),
        VoicePhrase(
          anchors: ['anxious', 'anxiety', 'nervous', 'bother', 'অস্বস্তি'],
          context: ['crowd', 'crowds', 'crowded', 'ভিড়'],
          requireContext: true,
          // Only reached when the statement IS negated — "crowds don't
          // bother me".
          blockers: [],
        ),
      ],
    ),
    (
      setting: 'complex_instructions_hard',
      present: [
        VoicePhrase(
          anchors: ['simple', 'simpler', 'hard', 'difficult', 'confusing', 'সহজ', 'কষ্ট', 'কঠিন'],
          context: ['instruction', 'instructions', 'steps', 'directions', 'explain', 'নির্দেশ', 'ধাপ'],
          requireContext: true,
          blockers: kAllNegations,
        ),
      ],
      absent: [
        VoicePhrase(
          anchors: ['follow', 'understand', 'fine', 'বুঝতে পারি', 'সমস্যা নেই'],
          context: ['instruction', 'instructions', 'steps', 'complex', 'নির্দেশ'],
          requireContext: true,
          blockers: kAllNegations,
        ),
      ],
    ),
  ];

  static LocalIntent? _matchTraitSetting(List<String> words) {
    for (final entry in _traitSettings) {
      final present = entry.present.any((p) => p.matches(words));
      final absent = entry.absent.any((p) => p.matches(words));
      // Both or neither is not something to guess at — a trait stated two
      // ways in one sentence needs a reader, not a pattern.
      if (present == absent) continue;
      return LocalIntent(
        'update_setting',
        {'setting': entry.setting, 'value': present ? 'true' : 'false'},
      );
    }
    return null;
  }

  static LocalIntent? _matchBooleanSetting(String lower, String text) {
    final words = voiceWords(text);
    // A question about a setting is not a request to change it.
    if (containsAny(words, kQuestionBlockers)) return null;
    return _matchToggle(words) ?? _matchTraitSetting(words);
  }

  // ---- theme -------------------------------------------------------------

  /// Words that mean "this is about the app's appearance", used to keep an
  /// everyday word like "dark" or "light" from firing on an ordinary
  /// sentence. See `VoicePhrase.requireContext`.
  static const _appearanceContext = [
    'mode', 'theme', 'screen', 'display', 'background', 'colour', 'color', 'app',
    'make', 'turn', 'switch', 'set', 'change', 'put', 'want', 'like', 'prefer',
    'মোড', 'থিম', 'স্ক্রিন', 'পর্দা', 'রং', 'করো', 'কর', 'দাও', 'চাই',
  ];

  static const _darkPhrase = VoicePhrase(
    anchors: ['dark', 'darker', 'darken', 'black', 'night mode', 'ডার্ক', 'গাঢ়', 'কালো', 'অন্ধকার'],
    context: _appearanceContext,
    requireContext: true,
    // "It's getting dark outside" must never flip the theme.
    blockers: ['outside', 'sky', 'evening', 'বাইরে', 'আকাশ', ...kQuestionBlockers],
  );

  static const _lightPhrase = VoicePhrase(
    anchors: ['light', 'lighter', 'brighter', 'brighten', 'white', 'day mode', 'লাইট', 'হালকা', 'উজ্জ্বল', 'সাদা'],
    context: _appearanceContext,
    requireContext: true,
    // "The street light is broken" is a hazard report, not a theme change.
    blockers: [
      'street', 'streetlight', 'lamp', 'bulb', 'torch', 'flashlight', 'রাস্তার', 'বাতি', 'ল্যাম্প',
      ...kQuestionBlockers,
    ],
  );

  static LocalIntent? _matchTheme(String lower, String text) {
    final value = exclusive(voiceWords(text), _darkPhrase, 'dark', _lightPhrase, 'light');
    return value == null ? null : LocalIntent('update_setting', {'setting': 'theme', 'value': value});
  }

  // ---- language ------------------------------------------------------

  static const _languageContext = [
    'speak', 'speaking', 'talk', 'talking', 'say', 'reply', 'replies', 'answer',
    'language', 'switch', 'change', 'use', 'in',
    'ভাষা', 'বলো', 'বল', 'কথা', 'বলুন', 'করো',
  ];

  static const _banglaPhrase = VoicePhrase(
    anchors: ['bangla', 'bengali', 'বাংলা', 'বাংলায়'],
    context: _languageContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );
  static const _englishPhrase = VoicePhrase(
    anchors: ['english', 'ইংরেজি', 'ইংলিশ', 'ইংরেজিতে'],
    context: _languageContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );

  static LocalIntent? _matchLanguage(String lower, String text) {
    final value = exclusive(voiceWords(text), _banglaPhrase, 'bangla', _englishPhrase, 'english');
    return value == null ? null : LocalIntent('update_setting', {'setting': 'language', 'value': value});
  }

  // ---- verbosity -------------------------------------------------------

  static const _speechContext = [
    'talk', 'talking', 'talks', 'say', 'saying', 'speak', 'tell', 'reply', 'replies',
    'answer', 'answers', 'words', 'explanation', 'instructions', 'keep', 'be', 'you',
    'কথা', 'বলো', 'বল', 'উত্তর', 'নির্দেশ',
  ];

  static const _minimalPhrase = VoicePhrase(
    anchors: ['brief', 'briefer', 'concise', 'minimal', 'minimalist', 'shorter', 'short', 'less',
      'সংক্ষেপে', 'সংক্ষিপ্ত', 'ছোট', 'কম'],
    context: _speechContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );
  static const _descriptivePhrase = VoicePhrase(
    anchors: ['detail', 'details', 'detailed', 'descriptive', 'explain', 'longer', 'more',
      'বিস্তারিত', 'বেশি', 'খুলে'],
    context: _speechContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );

  static LocalIntent? _matchVerbosity(String lower, String text) {
    final value = exclusive(
        voiceWords(text), _minimalPhrase, 'minimalist', _descriptivePhrase, 'descriptive');
    return value == null ? null : LocalIntent('update_setting', {'setting': 'verbosity', 'value': value});
  }

  // ---- text size (relative bump, not an absolute value — this matcher
  // never knows the current profile's fontScale, so it can't compute one;
  // `ChatController` resolves the actual new number from the live profile
  // before calling the executor) ------------------------------------------

  static const _textContext = [
    'text', 'texts', 'font', 'fonts', 'letters', 'letter', 'size', 'words', 'writing',
    'print', 'type', 'লেখা', 'ফন্ট', 'আকার', 'হরফ',
  ];

  static const _biggerPhrase = VoicePhrase(
    anchors: ['bigger', 'larger', 'increase', 'enlarge', 'big', 'large', 'zoom in',
      'বড়', 'বাড়াও', 'বাড়ান'],
    context: _textContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );
  static const _smallerPhrase = VoicePhrase(
    anchors: ['smaller', 'decrease', 'reduce', 'shrink', 'small', 'zoom out',
      'ছোট', 'কমাও', 'কমান'],
    context: _textContext,
    requireContext: true,
    blockers: kQuestionBlockers,
  );

  static LocalIntent? _matchTextSize(String lower, String text) {
    final value =
        exclusive(voiceWords(text), _biggerPhrase, '_bigger', _smallerPhrase, '_smaller');
    return value == null ? null : LocalIntent('update_setting', {'setting': 'text_size', 'value': value});
  }

  // ---- request_route -----------------------------------------------------

  /// Ways of asking to be taken somewhere, in one alternation.
  ///
  /// Deliberately long. This is the single most important command in the
  /// app, and the previous list recognized nine phrasings — so "I wanna go
  /// to Gulshan", "let's head to New Market", "how do I get to the
  /// hospital" and "bring me to work" all missed and cost a full language
  /// model round trip to understand something entirely unambiguous. Every
  /// alternative here is a way real people ask, including the contracted
  /// and dropped-word forms speech recognizers actually produce.
  ///
  /// The trailing `(.+)` is greedy on purpose: destinations are
  /// multi-word ("Gulshan 2 circle", "the eye hospital in Mirpur") and
  /// truncating at the first space would break more than it fixed.
  static final _routeEnPattern = RegExp(
    r'\b(?:'
    r'take me to|take me|bring me to|walk me to|guide me to|lead me to|'
    r'route me to|route to|navigate to|navigate me to|'
    r'directions? to|the way to|'
    r'how (?:do|can) i get to|how to get to|'
    r"i (?:wanna|want to|wanna go|need to|have to|gotta|would like to|'d like to) go to|"
    r'i (?:wanna|want to|need to) visit|'
    r"let'?s go to|let'?s head to|head to|"
    // "i'm going to X", never a bare "going to" — "is it going to rain
    // before I get there" is a weather question, and starting to walk a
    // blind user somewhere because of it is a real failure.
    r"i am going to|i'?m going to|"
    r'go to'
    r')\s+(.+)',
    caseSensitive: false,
  );

  /// "Take me home" / "go to work" — a destination with no `to <place>`
  /// tail because the place *is* the last word. Handled separately since
  /// the pattern above requires something after the preposition.
  static final _routeBarePattern = RegExp(
    r'\b(?:take me|bring me|walk me|guide me|lead me|go|head)\s+(?:back\s+)?(home|to work|to school|to the office)\b',
    caseSensitive: false,
  );

  /// Words that make a routing request an enquiry instead. "Should I go to
  /// Gulshan?" and "how far is it to go to Uttara" are questions about a
  /// journey, not a request to start one — and starting to walk someone
  /// somewhere they were only wondering about is a real failure.
  static const _routeBlockers = ['should i', 'how far', 'how long', 'is it safe', 'কতদূর', 'কেমন লাগবে'];

  /// Phrases that mean the user is *rejecting* a destination, not naming one.
  ///
  /// Reported live: "take me to work" resolved to a wrong saved place, and
  /// every attempt to say so — "this is not my workplace", "can you take me
  /// somewhere else" — matched here again as a fresh route request and got
  /// the same answer. The user could not get out of the loop by talking,
  /// which in a voice-only app means they could not get out at all.
  ///
  /// These belong to the conversation, not to a command, so they are handed
  /// to the model instead. Substrings rather than whole words, because the
  /// signal is the phrase ("not my", "somewhere else"), not a single token.
  /// Whether a captured destination is a description rather than a place.
  ///
  /// Seen on device: "take me to a nice place" matched as a route request
  /// with the destination "a nice place", which is then handed to a geocoder
  /// that can only fail or return something arbitrary. An indefinite article
  /// is the giveaway — real destinations here are proper nouns ("Labaid"),
  /// saved labels ("work", "home") or addresses, none of which begin with
  /// "a" or "some". A request shaped like this wants the assistant to
  /// *choose*, which is Gemini's job and not a lookup's.
  static bool _isVagueDestination(String destination) {
    final lower = destination.toLowerCase().trim();
    if (_vagueDestinations.contains(lower)) return true;
    return lower.startsWith('a ') ||
        lower.startsWith('an ') ||
        lower.startsWith('some ') ||
        lower.startsWith('any ');
  }

  static const _vagueDestinations = {
    'somewhere', 'anywhere', 'someplace', 'somewhere else', 'anywhere else',
    'কোথাও', 'যেকোনো জায়গা',
  };

  static const _routeRefusals = [
    'not my', "isn't my", 'is not my', 'not the', 'somewhere else', 'another place',
    'different place', 'wrong place', 'not there', "don't want to go", 'do not want to go',
    'আমার না', 'অন্য কোথাও', 'অন্য জায়গা', 'ভুল জায়গা',
  ];

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
  /// route request. Checked as a whole *word* — see [_bnNegationParticles]
  /// and [_words] for why a substring check was wrong here, and which real
  /// destinations it was silently refusing to route to.
  static bool _isNegatedBn(String text) => _words(text).any(_bnNegationParticles.contains);

  /// Words that lead a spoken destination clause without being part of the
  /// place name.
  ///
  /// Bangla puts the subject first and the verb last — "আমি গুলশান যেতে চাই"
  /// is *I Gulshan go want* — so a pattern anchored on the trailing verb
  /// captures the pronoun along with the place. Confirmed from a real
  /// device log: the destination reaching Nominatim was **"আমি গুলশান"**,
  /// which returns zero results, while "গুলশান" resolves immediately. The
  /// user heard "I don't know where that is" about a place the geocoder
  /// knows perfectly well.
  static const _leadingFillerBn = [
    'আমি', 'আমরা', 'আমাকে', 'আমার', 'তুমি', 'আপনি', 'এখন', 'একটু', 'দয়া', 'করে', 'প্লিজ', 'চলো', 'নিয়ে',
  ];
  static const _leadingFillerEn = [
    'please', 'now', 'ok', 'okay', 'so', 'um', 'uh', 'hey', 'well', 'just', 'can', 'you', 'i',
  ];

  /// Trims the politeness and filler speech recognizers faithfully
  /// transcribe around a destination — "take me to Gulshan please" must
  /// geocode "Gulshan", and so must "আমি গুলশান".
  static String _tidyDestination(String raw) {
    var out = raw.trim();

    // Leading filler first. Stops at the first word that looks like a real
    // place name, so a destination that legitimately starts with one of
    // these words is not eaten.
    var lead = true;
    while (lead) {
      lead = false;
      for (final filler in [..._leadingFillerBn, ..._leadingFillerEn]) {
        // Whitespace-or-end rather than `\b`: Dart's word boundary is
        // defined by ASCII `\w`, so it never matches after a Bangla
        // character and this stripped nothing at all in the language that
        // needed it most.
        final pattern = RegExp('^${RegExp.escape(filler)}(?:[\\s,]+|\$)', caseSensitive: false);
        final trimmed = out.replaceFirst(pattern, '');
        if (trimmed != out && trimmed.trim().isNotEmpty) {
          out = trimmed.trim();
          lead = true;
        }
      }
    }

    const trailing = ['please', 'thanks', 'thank you', 'now', 'right now', 'ok', 'okay', 'দয়া করে', 'প্লিজ', 'এখন'];
    var changed = true;
    while (changed) {
      changed = false;
      for (final filler in trailing) {
        final pattern = RegExp('[ ,]+${RegExp.escape(filler)}[.!?]*\$', caseSensitive: false);
        final trimmed = out.replaceFirst(pattern, '');
        if (trimmed != out) {
          out = trimmed;
          changed = true;
        }
      }
    }
    return out.replaceAll(RegExp(r'[.!?]+$'), '').trim();
  }

  // ---- request_alternative_route / replan_route ------------------------

  /// "Give me a different route."
  ///
  /// Reported directly: after being told a route passed a risky area, the
  /// user had no way to ask for another one — the alternatives Google had
  /// already returned were being thrown away, and there was no command that
  /// would have reached them anyway.
  static const _alternativeRoutePhrases = [
    'different route', 'another route', 'other route', 'different way',
    'another way', 'other way', 'different path', 'another path',
    'different road', 'another road', 'change the route', 'change route',
    'not this route', "don't like this route", 'dont like this route',
    'অন্য পথ', 'আরেকটা পথ', 'আরেকটি পথ', 'অন্য রাস্তা', 'আরেকটা রাস্তা',
    'অন্য কোনো পথ', 'অন্য কোন পথ', 'পথ পাল্টাও', 'পথ বদলাও',
  ];

  /// "Re-route" — start again from where I am standing.
  ///
  /// This one is not a nicety: [Dashboard.navigateOffRoute] tells a user who
  /// has drifted off the route to stop and say exactly this, and promises
  /// that the way will be found from where they are now. Nothing matched it,
  /// so the promise was empty at the one moment it mattered — a blind
  /// pedestrian, off route, on a Dhaka street.
  ///
  /// Distinct from [_alternativeRoutePhrases]: the same destination by a
  /// *different* road versus the same destination from a *new* origin.
  static const _replanPhrases = [
    're-route', 'reroute', 're route', 'route again', 'plan again',
    'find the way again', 'where do i go from here', 'start over',
    'নতুন পথ', 'আবার পথ', 'পথ খুঁজে দাও', 'এখান থেকে পথ',
  ];

  /// A destination named in the same breath means this is a fresh journey,
  /// not a change to the current one — "another way to Gulshan" is for
  /// Gemini, which has both tools and the conversation to tell them apart.
  static final _namesADestination = RegExp(r'\bto\s+\S', caseSensitive: false);

  /// "Cancel the trip." Ends the walk and clears the route.
  ///
  /// There was no intent for this at all, so it fell to Gemini — which
  /// answered "Cancelled your trip to Dhaka" and cancelled nothing. The route
  /// stayed active, the map kept drawing it, and the user was told otherwise.
  /// A confident wrong answer about a state the model cannot change is the
  /// worst of the three possible outcomes.
  /// Named a cancellation outright — these mean it wherever they appear.
  static const _cancelRouteStrong = [
    'cancel the trip', 'cancel trip', 'cancel the route', 'cancel the journey',
    'cancel my trip', 'stop the trip', 'stop the route', 'stop navigation',
    'stop navigating', 'end the trip', 'end navigation', 'forget the route',
    'never mind the route',
    'ট্রিপ বাতিল', 'যাত্রা বাতিল', 'পথ বাতিল', 'পথ দেখানো বন্ধ', 'নেভিগেশন বন্ধ',
  ];

  /// Bare negations — "I'm not going". A cancellation only when that is
  /// what the sentence is *about*, which is why they cannot be matched as
  /// substrings the way the strong phrases can.
  ///
  /// Both languages had the same false positive from doing exactly that.
  /// `যাব না` ("won't go") sits at the end of `আমি অফিসে যাব না` — "I am not
  /// going to the office", an ordinary statement — and English "i am not
  /// going" is the opening of "I'm not going to lie" and "I'm not going to
  /// bother", where "going" is an auxiliary and no journey is meant at all.
  /// Both were answered by cancelling the user's route.
  static const _cancelRouteWeak = [
    'i am not going', "i'm not going", 'im not going', 'no longer going',
    'যাব না', 'যাবো না',
  ];

  /// How far a weak phrase may fall short of the whole utterance.
  ///
  /// One word — enough for the subject or an adverb the phrase itself
  /// leaves out ("আমি যাব না", "আর যাব না", "I'm not going anymore"), and
  /// not enough for a destination or a following clause, which is exactly
  /// what distinguishes a cancellation from a statement about one. Same
  /// shape as [_maxBareCryWords], for the same reason: a phrase that is
  /// sometimes the whole point and sometimes an aside cannot be matched on
  /// its presence alone.
  static const int _maxCancelExtraWords = 1;

  static LocalIntent? _matchCancelRoute(String lower, String text) {
    if (_cancelRouteStrong.any((p) => lower.contains(p) || text.contains(p))) {
      return const LocalIntent('cancel_route', {});
    }
    final spokenWords = _words(text).length;
    for (final phrase in _cancelRouteWeak) {
      if (!lower.contains(phrase) && !text.contains(phrase)) continue;
      if (spokenWords - _words(phrase).length <= _maxCancelExtraWords) {
        return const LocalIntent('cancel_route', {});
      }
    }
    return null;
  }

  static LocalIntent? _matchRouteChange(String lower, String text) {
    final hasDestination = _namesADestination.hasMatch(lower);
    if (_replanPhrases.any((p) => lower.contains(p) || text.contains(p))) {
      return hasDestination ? null : const LocalIntent('replan_route', {});
    }
    if (_alternativeRoutePhrases.any((p) => lower.contains(p) || text.contains(p))) {
      return hasDestination ? null : const LocalIntent('request_alternative_route', {});
    }
    return null;
  }

  static LocalIntent? _matchRoute(String lower, String text, bool bn) {
    final words = voiceWords(text);
    if (containsAny(words, _routeBlockers)) return null;
    if (_routeRefusals.any((p) => lower.contains(p) || text.contains(p))) return null;

    final bareMatch = _routeBarePattern.firstMatch(text);
    if (bareMatch != null) {
      // Normalized to the bare place word — "take me back home" and "go to
      // work" become "home"/"work", which is what `SavedPlaceMatcher`
      // resolves against.
      final raw = bareMatch.group(1)!.toLowerCase().replaceAll(RegExp(r'^to (the )?'), '');
      return LocalIntent('request_route', {'destination': raw});
    }

    final enMatch = _routeEnPattern.firstMatch(text);
    if (enMatch != null) {
      final destination = _tidyDestination(enMatch.group(1)!);
      if (destination.isNotEmpty && !_isVagueDestination(destination)) {
        return LocalIntent('request_route', {'destination': destination});
      }
    }
    if (bn && !_isNegatedBn(text)) {
      final bnMatch = _routeBnPattern.firstMatch(text);
      if (bnMatch != null) {
        final destination = _tidyDestination(bnMatch.group(1)!);
        if (destination.isNotEmpty && destination.length <= 40) {
          return LocalIntent('request_route', {'destination': destination});
        }
      }
    }
    return null;
  }
}
