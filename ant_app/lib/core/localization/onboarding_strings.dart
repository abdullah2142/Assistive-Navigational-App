import '../../features/onboarding/models/disability_profile_enums.dart';
import '../../features/onboarding/models/user_profile.dart';
import 'app_language.dart';

/// All UI text for the onboarding flow, in both languages. One class per
/// [AppLanguage] resolved once per screen build — `Onboarding.of(language)`
/// — rather than per-string lookups, so a screen just does
/// `final s = Onboarding.of(lang); s.roleSelectionTitle`.
///
/// [LanguageSelectionScreen] is the one screen that doesn't use this — it
/// has to show both languages at once, since there isn't a chosen one yet.
///
/// Bangla wording is deliberately plain, everyday spoken Bangla — see
/// `dashboard_strings.dart`'s doc comment for the same rule applied there.
/// Concretely: "দেখাশোনাকারী" over "পরিচর্যাকারী", "সুবিধা" over "বৈশিষ্ট্য",
/// "ঠিক করা"/"আরামদায়ক" over "সামঞ্জস্য করা"/"স্বাচ্ছন্দ্যদায়ক", and short
/// concrete sentences over compound formal nouns throughout.
class Onboarding {
  const Onboarding._(this._bn);

  factory Onboarding.of(AppLanguage language) => Onboarding._(language == AppLanguage.bangla);

  final bool _bn;
  String _t(String en, String bn) => _bn ? bn : en;

  // Role selection
  String get roleSelectionTitle => _t('Welcome to ANT', 'অ্যান্টে স্বাগতম');
  String get roleSelectionSubtitle => _t(
        'Let\'s get started. Are you setting this up for yourself, or for someone you care for?',
        'শুরু করা যাক। আপনি কি নিজের জন্য, নাকি অন্য কারো দেখাশোনার জন্য এটি সেট করছেন?',
      );
  String get roleDisabledUserLabel => _t('I need assistance', 'আমার সহায়তা প্রয়োজন');
  String get roleDisabledUserDescription => _t('Set up navigation help for myself.', 'নিজের জন্য পথ দেখানোর সাহায্য সেট করুন।');
  // Voice "wiggle room" — a user paraphrasing the description ("myself")
  // rather than repeating the label verbatim should still be recognized.
  // See `OnboardingVoiceChoice.synonyms`' doc comment for the live bug this
  // fixes.
  List<String> get roleDisabledUserSynonyms => _bn
      ? const ['নিজের জন্য', 'নিজে', 'আমার জন্য', 'আমার সাহায্য', 'সাহায্য']
      : const ['myself', 'for myself', 'assistance', 'i need help', 'help me', 'disabled'];
  String get roleCaretakerLabel => _t('I am a Caretaker', 'আমি একজন দেখাশোনাকারী');
  String get roleCaretakerDescription =>
      _t('Set up remote monitoring for someone I support.', 'আমি যাকে দেখাশোনা করি, দূর থেকে তার খেয়াল রাখতে এটি সেট করুন।');
  List<String> get roleCaretakerSynonyms => _bn
      ? const ['দেখাশোনাকারী', 'অন্য কারো জন্য', 'কারো জন্য', 'দেখাশোনা করি']
      : const ['caretaker', 'someone else', 'support someone', 'guardian', 'monitoring'];

  // Caretaker pairing (share code)
  String get caretakerPairingTitle =>
      _t('Share this code with your Disabled User\'s device', 'এই কোডটি যাকে দেখাশোনা করেন তার ফোনে দেখান');
  String get caretakerPairingGenerating => _t('Generating code', 'কোড তৈরি হচ্ছে');
  String caretakerPairingYourCode(String code) => _t('Your pairing code is $code', 'আপনার কোড হলো $code');
  String get caretakerPairingWaiting => _t('Waiting for them to enter this code...', 'তিনি এই কোডটি দেওয়ার অপেক্ষায়...');

  // Paired confirmation (caretaker side)
  String get pairedConfirmationTitle => _t('Paired successfully!', 'যুক্ত হয়ে গেছে!');
  String get pairedConfirmationBody => _t(
        'You are now linked. You will be able to see their live location and get safety alerts once they finish their setup.',
        'আপনারা এখন যুক্ত। তিনি তার সেটআপ শেষ করলে আপনি তার অবস্থান দেখতে পারবেন এবং নিরাপত্তা সতর্কতা পাবেন।',
      );
  String get continueLabel => _t('Continue', 'চালিয়ে যান');
  List<String> get continueSynonyms => _bn
      ? const ['শেষ', 'হয়ে গেছে', 'চালিয়ে যাও', 'ঠিক আছে']
      : const ['done', 'finish', "that's it", "i'm done", 'next', 'okay', 'ready'];

  // User pairing (disabled user enters code)
  String get userPairingTitle => _t('Enter your caretaker\'s code', 'দেখাশোনাকারীর কোড লিখুন');
  // Deliberately states the skip option right here as well as in
  // `userPairingSpokenHint` — "you don't actually need a caretaker" isn't a
  // choice-enumeration detail a user can just ask "help" for if they don't
  // already know it's an option at all — it has to be said upfront, every
  // time, or a user with no caretaker could get stuck here not realizing
  // they can just say so and move on.
  String get userPairingSubtitle => _t(
        'Ask your caretaker for the 6-digit code shown on their screen. If you don\'t have a caretaker, just say so — you can use every safety feature on your own.',
        'যিনি আপনার দেখাশোনা করেন, তার স্ক্রিনে থাকা ৬-সংখ্যার কোডটি চেয়ে নিন। যদি আপনার কোনো দেখাশোনাকারী না থাকে, শুধু সেটা বলুন — আপনি একাই সব নিরাপত্তা সুবিধা ব্যবহার করতে পারবেন।',
      );
  String get userPairingCodeFieldLabel => _t('Enter the 6 digit pairing code', 'ছয় সংখ্যার কোড লিখুন');
  String get userPairingNoCaretakerButton => _t('I don\'t have a caretaker', 'আমার কোনো দেখাশোনাকারী নেই');
  List<String> get userPairingNoCaretakerSynonyms => _bn
      ? const ['নেই', 'বাদ দিন', 'কেউ নেই']
      : const ['no caretaker', 'skip', "don't have one", 'none', 'no one'];
  String get userPairingNoCaretakerSemantics =>
      _t('I don\'t have a caretaker, continue without pairing', 'আমার কোনো দেখাশোনাকারী নেই, এটি বাদ দিয়ে চালিয়ে যান');
  String get userPairingNoCaretakerCaption => _t(
        'You can still use every safety feature. You can pair with a caretaker later just by asking the AI.',
        'তবুও আপনি সব নিরাপত্তা সুবিধা ব্যবহার করতে পারবেন। পরে শুধু AI-কে বললেই একজন দেখাশোনাকারীর সাথে যুক্ত হতে পারবেন।',
      );
  String get userPairingSpokenHint => _t(
        'If you do not have a caretaker or a code, there is a button below labeled: '
            'I don\'t have a caretaker. Tap it to skip pairing and use every safety feature on your own.',
        'আপনার যদি কোনো দেখাশোনাকারী বা কোড না থাকে, নিচে একটি বোতাম আছে: আমার কোনো দেখাশোনাকারী নেই। '
            'এটি বাদ দিয়ে নিজে থেকে সব নিরাপত্তা সুবিধা ব্যবহার করতে সেটিতে চাপুন।',
      );
  String get userPairingVoicePromptSpoken => _t(
        'Say your 6-digit code, or say "I don\'t have a caretaker" to skip.',
        'আপনার ৬-সংখ্যার কোডটি বলুন, অথবা বাদ দিতে "আমার কোনো দেখাশোনাকারী নেই" বলুন।',
      );
  String get userPairingCodePartialSpoken => _t(
        'Got part of that. Say the rest of the code, or say the whole thing again.',
        'কিছুটা পেয়েছি। বাকি সংখ্যাগুলো বলুন, অথবা পুরো কোডটি আবার বলুন।',
      );

  // Vision question
  String get visionTitle => _t('Do you have any vision difficulty?', 'আপনার কি চোখে কোনো সমস্যা আছে?');
  String get visionSubtitle =>
      _t('This helps us adjust the screen and voice guidance for you.', 'এটি আমাদের স্ক্রিন ও ভয়েস আপনার জন্য ঠিক করতে সাহায্য করবে।');
  String get visionNoneLabel => _t('No vision', 'দৃষ্টিশক্তি নেই');
  String get visionNoneDescription => _t('I rely entirely on voice and touch.', 'আমি পুরোপুরি ভয়েস আর স্পর্শের উপর নির্ভর করি।');
  List<String> get visionNoneSynonyms => _bn
      ? const ['অন্ধ', 'দেখি না', 'একদমই দেখি না', 'কিছু দেখি না']
      : const ['blind', 'none', "can't see", 'cannot see', "i don't see"];
  String get visionLowLabel => _t('Partial / low vision', 'আংশিক / কম দৃষ্টিশক্তি');
  String get visionLowDescription =>
      _t('I can see some things, but need larger text and higher contrast.', 'আমি কিছুটা দেখতে পাই, তবে বড় লেখা আর বেশি কনট্রাস্ট লাগে।');
  List<String> get visionLowSynonyms => _bn
      ? const ['আংশিক', 'কম দেখি', 'একটু দেখি', 'কিছুটা দেখি']
      : const ['partial', 'low vision', 'a little', 'some vision', 'low'];
  String get visionFullLabel => _t('Full vision', 'সম্পূর্ণ দৃষ্টিশক্তি');
  String get visionFullDescription => _t('I see well and don\'t need visual adjustments.', 'আমি ভালো দেখতে পাই, কিছু পাল্টানোর দরকার নেই।');
  List<String> get visionFullSynonyms => _bn
      ? const ['ভালো দেখি', 'সম্পূর্ণ দেখি', 'ঠিক আছে', 'স্বাভাবিক']
      : const ['full', 'normal', 'fine', 'good vision', 'i see well', 'perfect'];

  // Visual calibration
  String get calibrationTitle => _t('Let\'s adjust the display for you', 'চলুন স্ক্রিন আপনার জন্য ঠিক করি');
  String get calibrationSubtitle =>
      _t('Move the sliders until the text below is easy for you to read.', 'নিচের লেখাটি সহজে পড়া না যাওয়া পর্যন্ত স্লাইডার সরান।');
  String get calibrationPreviewText => _t(
        'ANT will guide you safely.',
        'অ্যান্ট আপনাকে নিরাপদে পথ দেখাবে।',
      );
  String get calibrationContrastLabel => _t('Contrast', 'কনট্রাস্ট');
  String calibrationContrastSemantics(int percent) => _t('Contrast level slider, currently $percent percent', 'কনট্রাস্টের স্লাইডার, এখন $percent শতাংশ');
  String get calibrationTextSizeLabel => _t('Text size', 'লেখার আকার');
  String calibrationTextSizeSemantics(String scale) =>
      _t('Text size slider, currently $scale times normal size', 'লেখার আকারের স্লাইডার, এখন স্বাভাবিকের $scale গুণ');
  String get calibrationContinueButton => _t('This is comfortable, continue', 'এটি আরামদায়ক, চালিয়ে যান');
  List<String> get calibrationContinueSynonyms =>
      _bn ? const ['আরামদায়ক', 'ঠিক আছে', 'চালিয়ে যান'] : const ['comfortable', 'good', 'fine', 'continue', 'done'];
  String get calibrationSpokenHint => _t(
        'Two sliders follow: contrast, and text size. Adjust them if needed, or just tap the '
            'button at the bottom to continue with the current comfortable defaults.',
        'দুটি স্লাইডার আছে: কনট্রাস্ট আর লেখার আকার। প্রয়োজনে ঠিক করুন, নাহলে এমনিই '
            'ভালো আছে এমন মান নিয়ে চালিয়ে যেতে নিচের বোতামে চাপুন।',
      );

  // Theme preference
  String get themeTitle => _t('Light or dark?', 'হালকা নাকি গাঢ়?');
  String get themeSubtitle =>
      _t('Pick whichever is easier on your eyes. You can change this later just by asking the AI.', 'যেটি আপনার চোখের জন্য আরামদায়ক সেটি বেছে নিন। পরে শুধু AI-কে বললেই এটি পাল্টাতে পারবেন।');
  String get themeLightLabel => _t('Light', 'হালকা');
  String get themeLightDescription => _t('Soft cream background, dark text.', 'হালকা ক্রিম রঙের পটভূমি, গাঢ় লেখা।');
  List<String> get themeLightSynonyms => _bn ? const ['সাদা', 'উজ্জ্বল', 'দিনের মোড'] : const ['bright', 'white', 'day mode'];
  // Auto-listen. Asked of everyone who is not blind — a blind user gets it
  // without being asked, because they cannot find a mic button on a screen
  // they cannot see.
  String get autoListenTitle => _t('Should the microphone open on its own?', 'মাইক কি নিজে থেকেই চালু হবে?');
  String get autoListenSubtitle => _t(
        'After ANT answers, it can keep listening for a few seconds so you can just carry on '
            'talking, instead of finding the mic button or saying the wake word again.',
        'ANT উত্তর দেওয়ার পর কয়েক সেকেন্ড শুনতে থাকতে পারে, যাতে আপনি সরাসরি কথা চালিয়ে যেতে পারেন '
            '— মাইক বোতাম খোঁজা বা আবার জাগানোর শব্দ বলা লাগবে না।',
      );
  String get autoListenYesLabel => _t('Yes, open it for me', 'হ্যাঁ, নিজেই চালু হোক');
  String get autoListenYesDescription =>
      _t('Best if tapping a small button is hard.', 'ছোট বোতামে চাপ দেওয়া কঠিন হলে এটাই ভালো।');
  List<String> get autoListenYesSynonyms =>
      _bn ? const ['হ্যাঁ', 'চালু', 'নিজেই'] : const ['yes', 'open it', 'automatic', 'on'];
  String get autoListenNoLabel => _t('No, I will tap the mic', 'না, আমি মাইকে চাপব');
  String get autoListenNoDescription =>
      _t('The microphone only opens when you ask.', 'আপনি না চাইলে মাইক চালু হবে না।');
  List<String> get autoListenNoSynonyms =>
      _bn ? const ['না', 'আমি চাপব', 'বন্ধ'] : const ['no', 'i will tap', 'manual', 'off'];

  // ---- Option narration ---------------------------------------------------
  //
  // Asked rather than decided, because it has been decided both ways and both
  // were right for somebody. `OnboardingScaffold` first deferred the option
  // list until it was asked for, so a user who knew their answer did not sit
  // through a read-out; live testing reverted that, because a microphone
  // opening in silence reads as the app "just recording". Different people,
  // both correct.
  String get optionNarrationTitle =>
      _t('Should I read the choices out?', 'আমি কি বিকল্পগুলো পড়ে শোনাব?');
  String get optionNarrationSubtitle => _t(
        'On every question, ANT can read all the answers out before it listens — or stay quiet '
            'and read them only when you ask.',
        'প্রতিটি প্রশ্নে ANT শোনার আগে সব উত্তর পড়ে শোনাতে পারে — অথবা চুপ থেকে আপনি চাইলে তবেই পড়বে।',
      );
  String get optionNarrationAlwaysLabel => _t('Read them every time', 'প্রতিবার পড়ে শোনাও');
  String get optionNarrationAlwaysDescription => _t(
        'Best if you cannot see the screen — you never have to guess what you may say.',
        'স্ক্রিন দেখতে না পেলে এটাই ভালো — কী বলা যাবে তা অনুমান করতে হবে না।',
      );
  /// Item 62 — "turn on narration of choices, do not postpone narration of
  /// choices".
  ///
  /// The reported sentence used to select the *opposite* option. `on request`
  /// was an on-request synonym, `fuzzyMatchScore` accepts half a target's
  /// words, and "turn **on**" is half of "**on** request" — so the most
  /// natural way in English to ask for something to be enabled scored 0.5 for
  /// switching it off and 0 for switching it on. Same defect as "Low vision"
  /// selecting "No vision": a half-match on a shared word that carries none
  /// of the meaning.
  ///
  /// Two halves to the fix. The ambiguous synonym is gone from the other
  /// option, and the ways people actually say "enable this" are listed here,
  /// so they win outright rather than merely tying.
  List<String> get optionNarrationAlwaysSynonyms => _bn
      ? const [
          'প্রতিবার', 'পড়ে শোনাও', 'সবসময়', 'হ্যাঁ',
          'চালু করো', 'চালু', 'পড়ো', 'শোনাও',
        ]
      : const [
          'every time', 'read them', 'always', 'yes', 'read it out',
          'turn it on', 'turn on', 'keep it on', 'switch it on', 'leave it on',
          'read the choices', 'read the options', 'narrate', 'narration on',
        ];

  String get optionNarrationOnRequestLabel => _t('Only when I ask', 'শুধু আমি চাইলে');
  String get optionNarrationOnRequestDescription => _t(
        'Quicker once you know the questions. Say "options" at any point to hear them.',
        'প্রশ্নগুলো জানা থাকলে দ্রুত হয়। যেকোনো সময় "বিকল্প" বললেই শুনতে পাবেন।',
      );
  /// `on request` is deliberately absent — see
  /// [optionNarrationAlwaysSynonyms]. Its only distinctive word is
  /// "request", and the other one inverted the setting for anybody who said
  /// "turn it on".
  List<String> get optionNarrationOnRequestSynonyms => _bn
      ? const ['শুধু চাইলে', 'চাইলে', 'না', 'দরকার নেই', 'চুপ থাকো']
      : const [
          'only when i ask', 'when i ask', 'no', 'keyword',
          'only if i ask', 'when i request', 'stay quiet',
        ];

  /// Spoken in place of the option list when the user has asked for quiet.
  ///
  /// The silence itself was the reported problem — a mic opening with nothing
  /// said reads as the app simply recording. So this is not "say nothing", it
  /// is "say the one thing that gets the list back".
  String get optionNarrationKeywordHint =>
      _t('Say "options" to hear the choices.', '"বিকল্প" বললে পছন্দগুলো শুনতে পাবেন।');

  String get themeDarkLabel => _t('Dark', 'গাঢ়');
  String get themeDarkDescription => _t('Deep charcoal background, soft white text.', 'গাঢ় কালচে পটভূমি, নরম সাদা লেখা।');
  List<String> get themeDarkSynonyms => _bn ? const ['কালো', 'রাতের মোড', 'গাঢ় রং'] : const ['black', 'night mode', 'night'];

  // Mobility
  String get mobilityTitle => _t('How do you get around?', 'আপনি কীভাবে চলাফেরা করেন?');
  String get mobilitySubtitle => _t('This helps us choose routes that work for you.', 'এটি আমাদের আপনার জন্য ঠিক পথ বেছে নিতে সাহায্য করে।');
  String get mobilityWhiteCaneLabel => _t('White cane', 'সাদা ছড়ি');
  List<String> get mobilityWhiteCaneSynonyms => _bn ? const ['ছড়ি', 'লাঠি'] : const ['cane', 'stick', 'blind cane'];
  String get mobilityWheelchairLabel => _t('Wheelchair', 'হুইলচেয়ার');
  List<String> get mobilityWheelchairSynonyms => _bn ? const ['চেয়ার', 'হুইল চেয়ার'] : const ['chair', 'wheel chair'];
  String get mobilityUnassistedLabel => _t('I walk unassisted', 'আমি সাহায্য ছাড়াই হাঁটি');
  /// "Alone" carries this answer on its own, in both languages.
  ///
  /// Item 33: a tester answered `আমি একাই হাঁটি` ("I walk alone") and it was
  /// not accepted. The phrase does score against the label — but only by
  /// accident, on the one word `হাঁটি` it happens to share with it. Nothing
  /// here knew the word for *alone* at all, so the whole answer rested on
  /// that single verb: `আমি একাই হাটি` (the same word without its
  /// chandrabindu, which is how it is often transcribed), `আমি একা চলি`
  /// ("I get about alone"), and a bare `আমি একা` all scored zero against
  /// every option on the screen.
  ///
  /// A synonym per *concept*, not per phrasing, is what makes this hold up:
  /// the answer should not depend on which verb the user reaches for.
  List<String> get mobilityUnassistedSynonyms => _bn
      ? const [
          'নিজে হাঁটি', 'সাহায্য ছাড়া', 'সাহায্য লাগে না',
          'একা', 'একাই', 'একা চলি', 'একাই চলি', 'নিজে চলি', 'নিজেই',
        ]
      : const [
          'walk myself', 'no aid', 'on my own', 'unassisted', 'nothing', 'none',
          'alone', 'walk alone', 'by myself',
        ];

  // Cognitive & anxiety
  String get cognitiveTitle => _t('A couple more questions', 'আরও কয়েকটি প্রশ্ন');
  String get cognitiveSubtitle =>
      _t('There are no wrong answers here — this only helps us keep things calm for you.', 'এখানে কোনো ভুল উত্তর নেই — এটি শুধু আপনাকে শান্ত রাখতে সাহায্য করবে।');
  String get cognitiveCrowdedQuestion => _t('Do crowded places make you feel anxious?', 'ভিড়ের জায়গায় কি আপনার অস্বস্তি লাগে?');
  String get cognitiveComplexQuestion =>
      _t('Do you find complex, multi-step instructions hard to follow?', 'অনেক ধাপের কঠিন নির্দেশ বুঝতে কি আপনার অসুবিধা হয়?');
  String get cognitiveSpokenHint => _t(
        'Two switches follow, both off by default: do crowded places make you feel anxious, '
            'and do you find complex multi-step instructions hard to follow. Toggle either if it '
            'applies, then tap Continue at the bottom.',
        'দুটি সুইচ আছে, দুটোই এখন বন্ধ: ভিড়ের জায়গায় কি অস্বস্তি লাগে, আর অনেক '
            'ধাপের কঠিন নির্দেশ বুঝতে কি অসুবিধা হয়। প্রযোজ্য হলে সুইচ চালু করুন, তারপর নিচে চালিয়ে যান-এ চাপুন।',
      );
  // See `classifyTraitYesNo`'s doc comment — these phrase lists deliberately
  // bake in whatever negation each phrase needs, rather than relying on a
  // generic "flip on negation" rule that gets the direction wrong depending
  // on *what's* negated.
  List<String> get cognitiveCrowdedPresentPhrases => _bn
      ? const ['অস্বস্তি', 'ভয় লাগে', 'নার্ভাস', 'ঘাবড়ে যাই', 'অসুবিধা হয়']
      : const [
          'anxious', 'nervous', 'uncomfortable', 'stressed', 'uneasy', 'panic', 'scared',
          'bother me', 'bothers me', "don't like crowds", 'dont like crowds', 'hate crowds',
        ];
  List<String> get cognitiveCrowdedAbsentPhrases => _bn
      ? const ['অস্বস্তি লাগে না', 'সমস্যা নেই', 'ভালো লাগে', 'ঠিক আছে']
      : const [
          'fine in crowds', 'comfortable in crowds', 'not bothered', 'no problem', "don't bother me",
          'dont bother me', "doesn't bother me", 'okay with crowds', 'used to crowds', 'fine with crowds',
        ];
  List<String> get cognitiveComplexPresentPhrases => _bn
      ? const ['কঠিন', 'বুঝতে কষ্ট', 'জটিল', 'সমস্যা হয়']
      : const [
          'hard to follow', 'confusing', 'difficult', 'hard time', 'complicated', 'get lost',
          "can't follow", 'cant follow', 'hard for me',
        ];
  List<String> get cognitiveComplexAbsentPhrases => _bn
      ? const ['সহজ', 'বুঝতে পারি', 'সমস্যা নেই', 'ঠিক আছে']
      : const [
          'easy to follow', 'understand fine', 'no problem', 'can follow', 'fine with instructions',
          'not hard', 'not difficult', 'easy for me',
        ];

  // Deaf/hearing
  String get deafTitle => _t('Are you deaf or hard of hearing?', 'আপনি কি কানে কম শোনেন বা একদম শোনেন না?');
  String get deafSubtitle =>
      _t('If so, we\'ll show you text and visual guidance instead of relying on audio.', 'তাহলে আমরা শব্দের বদলে লেখা ও ছবি দিয়ে বোঝাব।');
  String get deafYesLabel => _t('Yes', 'হ্যাঁ');
  String get deafYesDescription => _t('Show me text and visuals instead of audio.', 'শব্দের বদলে আমাকে লেখা এবং ছবি দেখান।');
  String get deafNoLabel => _t('No', 'না');
  String get deafNoDescription => _t('I can hear voice guidance normally.', 'আমি সহকারীর কথা স্বাভাবিকভাবে শুনতে পাই।');
  // See `classifyTraitYesNo`'s doc comment — replaced the old synonym-list
  // matching entirely (confirmed live as a real bug: word-overlap scoring
  // let "I can hear my assistant" match the *deaf* answer's "can't hear"
  // synonym, since both merely share the word "hear" and negation isn't
  // something word-overlap counting can see). Each phrase here already has
  // whatever negation it needs baked directly in.
  List<String> get deafPresentPhrases => _bn
      ? const ['বধির', 'কানে শুনি না', 'কম শুনি', 'শুনতে সমস্যা', 'শুনতে পাই না', 'ভালো শুনি না', 'শোনায় সমস্যা']
      : const [
          'deaf', 'hard of hearing', 'trouble hearing', 'hearing problem', 'hearing issue',
          "can't hear", 'cant hear', 'cannot hear', 'can not hear', "don't hear well", 'dont hear well',
          'hard time hearing', 'poor hearing', 'bad hearing', 'difficulty hearing',
        ];
  List<String> get deafAbsentPhrases => _bn
      ? const ['শুনতে পাই', 'শোনায় সমস্যা নেই', 'ঠিক আছে শুনি', 'ভালো শুনি', 'স্বাভাবিক শুনি']
      : const [
          'hear fine', 'hear well', 'can hear', 'hearing is fine', 'hearing is good', 'hearing is normal',
          'no hearing problem', 'no trouble hearing', 'normal hearing', 'good hearing', 'hear you',
          'hear everything', 'hear my assistant', 'no problem hearing',
        ];

  // Verbosity & voice
  String get verbosityTitle => _t('How should the AI talk to you?', 'AI আপনার সাথে কীভাবে কথা বলবে?');
  String get verbosityChattinessLabel => _t('Chattiness', 'কথা বলার ধরন');
  String get verbosityMinimalistLabel => _t('Minimalist', 'সংক্ষিপ্ত');
  String get verbosityMinimalistDescription => _t('Short, essential instructions only.', 'শুধু ছোট, দরকারি কথা বলবে।');
  List<String> get verbosityMinimalistSynonyms =>
      _bn ? const ['কম কথা', 'ছোট', 'সংক্ষেপে'] : const ['short', 'brief', 'less talking', 'minimal'];
  String get verbosityDescriptiveLabel => _t('Descriptive', 'বিস্তারিত');
  String get verbosityDescriptiveDescription => _t('More detail and reassurance along the way.', 'পথে আরও বিস্তারিত কথা আর ভরসা দেবে।');
  List<String> get verbosityDescriptiveSynonyms =>
      _bn ? const ['বেশি কথা', 'বিস্তারিত', 'খুলে বলা'] : const ['detailed', 'more talking', 'long', 'descriptive'];
  String get verbosityVoiceLabel => _t('Voice', 'ভয়েস');
  /// The voice options name the language the user actually chose.
  ///
  /// Both were hardcoded to say "Bangla", so an English user was offered
  /// "Bangla — Female voice" and "Bangla — Male voice" and read them aloud in
  /// English. Reported as the screen having Bangla hardcoded, which it did —
  /// the wrong half of it was fixed first: the stored voice id, which was
  /// also wrong but invisible.
  String get _voiceLanguageName => _bn ? 'বাংলা' : 'English';
  String get verbosityFemaleVoiceLabel =>
      _t('$_voiceLanguageName — Female voice', '$_voiceLanguageName — নারী কণ্ঠ');
  List<String> get verbosityFemaleVoiceSynonyms => _bn ? const ['নারী', 'মেয়ে', 'মহিলা'] : const ['female', 'woman', 'girl'];
  String get verbosityMaleVoiceLabel =>
      _t('$_voiceLanguageName — Male voice', '$_voiceLanguageName — পুরুষ কণ্ঠ');
  List<String> get verbosityMaleVoiceSynonyms => _bn ? const ['পুরুষ', 'ছেলে'] : const ['male', 'man', 'boy'];
  String get verbositySpokenHint => _t(
        'How chatty should the assistant be. Option 1: Minimalist, short essential instructions only. '
            'Option 2: Descriptive, more detail and reassurance along the way.',
        'সহকারী কতটা কথা বলবে। বিকল্প ১: সংক্ষিপ্ত, শুধু দরকারি কথা। '
            'বিকল্প ২: বিস্তারিত, পথে আরও কথা আর ভরসা।',
      );
  String get verbositySpokenVoiceHint => _t(
        'Then pick a voice. Option 1: $_voiceLanguageName, female voice. '
            'Option 2: $_voiceLanguageName, male voice.',
        'তারপর একটি ভয়েস বেছে নিন। বিকল্প ১: $_voiceLanguageName, নারী কণ্ঠ। '
            'বিকল্প ২: $_voiceLanguageName, পুরুষ কণ্ঠ।',
      );

  // Magic Button contacts
  String get contactsTitle => _t('Who should we contact in an emergency?', 'বিপদে পড়লে আমরা কাকে জানাব?');
  String get contactsSubtitle =>
      _t('Add at least one trusted contact. They\'ll get an SMS with your location if you press the Magic Button.', 'অন্তত একজন বিশ্বস্ত মানুষের নাম দিন। আপনি ম্যাজিক বাটন চাপলে তিনি আপনার অবস্থানসহ একটি SMS পাবেন।');
  String get contactsNameHint => _t('Name (e.g. Mother)', 'নাম (যেমন মা)');
  String get contactsPhoneHint => _t('Phone number', 'ফোন নম্বর');
  // Spoken when a dictated value is read back for confirmation — the hints
  // above carry an example in parentheses, which is useful on screen and
  // confusing out loud.
  String get contactsNameLabel => _t('the name', 'নামটি');
  String get contactsPhoneLabel => _t('the phone number', 'ফোন নম্বরটি');
  String get contactsAddButton => _t('Add contact', 'পরিচিতি যোগ করুন');
  String get contactsErrorAtLeastOne =>
      _t('Please add at least one trusted contact for the Magic Button to work.', 'ম্যাজিক বাটন কাজ করার জন্য অন্তত একজনের নাম দিন।');
  String get contactsSpokenHint => _t(
        'Below are two fields: name, and phone number, followed by an Add contact button. '
            'Add at least one, then tap Continue at the bottom.',
        'নিচে দুটি ঘর আছে: নাম, এবং ফোন নম্বর, তারপর পরিচিতি যোগ করুন বোতাম। '
            'অন্তত একজনকে যোগ করুন, তারপর নিচে চালিয়ে যান-এ চাপুন।',
      );
  String contactsRemoveSemantics(String name) => _t('Remove $name', '$name বাদ দিন');
  String get contactsNamePromptSpoken => _t('Say the contact\'s name.', 'পরিচিতির নাম বলুন।');
  String get contactsPhonePromptSpoken => _t('Now say their phone number.', 'এখন তাদের ফোন নম্বর বলুন।');
  String get contactsAddAnotherLabel => _t('Add another', 'আরেকজন যোগ করুন');
  List<String> get contactsAddAnotherSynonyms =>
      _bn ? const ['আরেকজন', 'আরও একজন', 'আরও'] : const ['another', 'one more', 'add', 'add one more'];
  String get contactsAddedThenAddAnotherOrContinueSpoken => _t(
      'Contact saved. Say "add another" to add someone else, or "continue" if you\'re done.',
      'পরিচিতি যোগ হয়েছে। আরেকজন যোগ করতে "আরেকজন" বলুন, অথবা শেষ হলে "চালিয়ে যান" বলুন।');
  /// Read back before saving, not after — explicit user feedback: a
  /// dictated phone number is exactly the kind of thing that's easy for
  /// STT to get subtly wrong (a dropped or swapped digit), and this is an
  /// *emergency* contact, so confirming it's right matters more here than
  /// almost anywhere else in onboarding. [spacedPhone] should have its
  /// digits spoken one at a time (space-separated), not read as one large
  /// number — see `_spaceOutDigits` at the call site.
  /// [spelledName] is [name] spelled out — see `spelledOutName`.
  ///
  /// The number was always read digit by digit so it could be checked by ear.
  /// The name was not, and a name is no easier to get right: reported against
  /// the step that asks for a relative's real name, the read-back came out
  /// misspelled. Nor could it have been caught, because the name was only ever
  /// *pronounced*, and "Rahima", "Rohima" and "Raheema" are the same sound —
  /// so a user who cannot see the screen was being asked to confirm something
  /// they had no way to check. It is said and then spelled: the pronunciation
  /// to recognise it by, the letters to verify it by.
  String contactsConfirmSpoken(String name, String spelledName, String spacedPhone) => _t(
        'I heard the name as $name — spelled $spelledName — and the phone number as $spacedPhone. '
            'Say "yes" to save this, or "no" to try again.',
        'নাম শুনেছি $name — বানান $spelledName — আর ফোন নম্বর $spacedPhone। '
            'ঠিক থাকলে "হ্যাঁ" বলুন, নাহলে আবার বলতে "না" বলুন।',
      );

  // Passerby messages
  String get passerbyTitle => _t('What might you need to tell a stranger?', 'অচেনা মানুষকে আপনার কী বলার দরকার হতে পারে?');
  String get passerbySubtitle => _t(
        'Pick the messages you\'d want ready to show — you can add your own too. '
            'These show up full-screen when you ask the AI to "show my screen."',
        'যেসব বার্তা তৈরি রাখতে চান বেছে নিন — নিজেও লিখতে পারেন। '
            'AI-কে "আমার স্ক্রিন দেখাও" বললে এগুলো বড় করে স্ক্রিনে দেখাবে।',
      );
  String get passerbyWriteOwnHint => _t('Write or dictate your own…', 'নিজে লিখুন বা বলুন…');
  String get passerbyAddButton => _t('Add message', 'বার্তা যোগ করুন');
  String get passerbySpeakSemantics => _t('Speak your message', 'কথা বলে বলুন');
  String get passerbySpeakHint => _t('Voice input arrives with the AI Assistant module', 'কথা বলে লেখার অংশটি পরে যোগ হবে');
  String get passerbyAiSummaryLabel => _t('AI summary (this is what gets added)', 'ছোট করে লেখা (এটাই যোগ হবে)');
  String get passerbyWriteFieldSemantics => _t('Write your own message', 'নিজের বার্তা লিখুন');
  String passerbySpokenPreselected(String messages) => _t('The first 3 below are pre-selected: $messages.', 'নিচের প্রথম ৩টি আগে থেকেই বাছাই করা আছে: $messages।');
  String passerbySpokenMore(String messages) => _t('More options follow: $messages.', 'আরও কিছু বিকল্প আছে: $messages।');
  String get passerbySpokenAddOwn => _t(
        'There is also a field at the bottom to write and add your own message. Tap Continue when ready.',
        'নিচে নিজের বার্তা লিখে যোগ করার জন্য একটি ঘরও আছে। প্রস্তুত হলে চালিয়ে যান-এ চাপুন।',
      );
  String get passerbyVoiceRetryHint => _t(
        'Say one of the messages to turn it on or off, say "my own message" to add something new, say "help" to hear the messages again, or say "continue" when you\'re done.',
        'কোনো বার্তার নাম বললে সেটি চালু বা বন্ধ হবে, নতুন কিছু যোগ করতে "নিজের বার্তা" বলুন, আবার শুনতে "সাহায্য" বলুন, অথবা শেষ হলে "চালিয়ে যান" বলুন।',
      );
  /// Spoken *before* the very first listen, not just after a miss —
  /// confirmed live as a real gap without this: a user was given zero
  /// instructions on what to actually say until after they'd already
  /// guessed wrong once. Also gives a concrete, literal example phrase
  /// (not just an abstract description) a user with nothing of their own
  /// to say can just repeat verbatim — explicit user feedback: "it should
  /// clearly give me a keyword to use." Names the "my own message" trigger
  /// explicitly too (see `passerbyAddOwnTriggers`) — confirmed live as a
  /// second, separate real gap: without a distinct keyword, an arbitrary
  /// custom message could share a stray word with a suggestion sentence
  /// and get misread as picking that one instead of being added as new text.
  String passerbyVoiceIntroSpoken(String example) => _t(
        'Say one of these messages to turn it on or off, or say "my own message" to add something new. '
            'If you can\'t think of one, you can just say: "$example" — that will be added as your message. '
            'Say "help" any time to hear the messages again, or "continue" when you\'re done.',
        'এই বার্তাগুলোর যেকোনো একটির নাম বললে সেটি চালু বা বন্ধ হবে, অথবা নতুন কিছু যোগ করতে "নিজের বার্তা" বলুন। '
            'কিছু মনে না এলে, এটাই বলতে পারেন: "$example" — এটি আপনার বার্তা হিসেবে যোগ হবে। '
            'বার্তাগুলো আবার শুনতে যেকোনো সময় "সাহায্য" বলুন, অথবা শেষ হলে "চালিয়ে যান" বলুন।',
      );
  String passerbyMessageAddedSpoken(String message) => _t('Added: $message.', 'যোগ হয়েছে: $message।');
  String passerbyMessageRemovedSpoken(String message) => _t('Removed: $message.', 'বাদ দেওয়া হয়েছে: $message।');
  String get passerbyCustomAddedSpoken => _t('Added your message.', 'আপনার বার্তা যোগ হয়েছে।');
  /// Explicit keyword to signal "what I say next is my own new message, not
  /// an attempt to pick one of the suggestions" — confirmed live as needed:
  /// without a clear trigger, an arbitrary custom message could easily
  /// share a stray word with a suggestion sentence and get misread as
  /// picking that one instead of being added as new text.
  List<String> get passerbyAddOwnTriggers => _bn
      ? const ['নিজের বার্তা', 'আমার বার্তা যোগ করব', 'নিজের কথা', 'কাস্টম বার্তা']
      : const ['my own message', 'add my own', 'say my own', 'custom message', 'write my own', 'add a message'];
  String get passerbyAddOwnButton => _t('Add this message', 'এই বার্তাটি যোগ করুন');
  String get passerbyAddOwnPromptSpoken => _t('Okay, say your message now.', 'ঠিক আছে, এখন আপনার বার্তা বলুন।');
  String get passerbyNeedAtLeastOneSpoken => _t(
        'Please pick at least one message, or add your own, before continuing.',
        'চালিয়ে যাওয়ার আগে অন্তত একটি বার্তা বেছে নিন, বা নিজের একটি যোগ করুন।',
      );

  // Default passerby message suggestions (also used as the runtime fallback
  // for profiles created before this feature existed)
  String get passerbyNeedHelp => _t('I need help, please.', 'আমার সাহায্য দরকার, দয়া করে।');
  String get passerbyWhichDirection => _t('Which direction is this address?', 'এই ঠিকানাটি কোন দিকে?');
  String get passerbyHelpCross => _t('Can you help me cross the street?', 'আমাকে রাস্তা পার হতে একটু সাহায্য করবেন?');
  String get passerbyVisuallyImpaired => _t('I am visually impaired. Can you guide me?', 'আমি চোখে দেখি না। আমাকে একটু পথ দেখাবেন?');
  String get passerbyRoadFlooded => _t('Is this road flooded or blocked?', 'এই রাস্তায় কি পানি জমেছে বা আটকানো আছে?');
  String get passerbyWhatSignSays => _t('What does this sign say?', 'এই সাইনবোর্ডে কী লেখা আছে?');
  String get passerbyDeaf => _t('I am deaf. Please type or point to answer.', 'আমি কানে শুনি না। দয়া করে লিখে বা ইশারা করে বলুন।');
  String get passerbyWhichBus => _t('Which bus number is this?', 'এটি কত নম্বর বাস?');
  String get passerbyRampNearby => _t('Is there a ramp or accessible entrance nearby?', 'কাছে কোনো ঢালু পথ বা সহজ দরজা আছে কি?');

  // Snapshot consent
  String get snapshotTitle => _t('Can your caretaker request a photo anytime?', 'আপনার দেখাশোনাকারী কি যেকোনো সময় ছবি চাইতে পারবেন?');
  String get snapshotSubtitle => _t(
        'This controls whether they need to ask you first before your camera captures a single frame for them.',
        'ছবি তোলার আগে তার আপনাকে জিজ্ঞেস করা লাগবে কিনা, সেটা এখানে ঠিক করুন।',
      );
  String get snapshotAlwaysLabel => _t('Always allow', 'সবসময় অনুমতি দিন');
  String get snapshotAlwaysDescription => _t('They can request a snapshot anytime, no need to ask me first.', 'তিনি যেকোনো সময় একটা ছবি চাইতে পারবেন, আগে জিজ্ঞেস করার দরকার নেই।');
  List<String> get snapshotAlwaysSynonyms => _bn ? const ['সবসময়', 'যেকোনো সময়'] : const ['always', 'anytime', 'yes always'];
  String get snapshotAskLabel => _t('Ask me each time', 'প্রতিবার আমাকে জিজ্ঞেস করুন');
  String get snapshotAskDescription => _t('I want to approve every snapshot request as it happens.', 'প্রতিবার ছবি চাইলে আগে আমাকে জিজ্ঞেস করা হোক।');
  List<String> get snapshotAskSynonyms =>
      _bn ? const ['জিজ্ঞেস করুন', 'আগে বলুন', 'অনুমতি নিন'] : const ['ask me', 'ask first', 'check with me'];
  String get snapshotNeverLabel => _t('Never allow', 'কখনো অনুমতি দেবেন না');
  String get snapshotNeverDescription => _t('Turn off Snapshot Requests entirely.', 'ছবি চাওয়ার সুবিধাটি পুরোপুরি বন্ধ রাখুন।');
  List<String> get snapshotNeverSynonyms =>
      _bn ? const ['কখনো না', 'বন্ধ রাখুন', 'বন্ধ'] : const ['never', "don't allow", 'turn off', 'no'];

  // Safe havens
  String get safeHavensTitle => _t('Where do you feel safest?', 'আপনি কোথায় সবচেয়ে নিরাপদ বোধ করেন?');
  String get safeHavensSubtitle =>
      _t('We\'ll use these to guide you back to safety and to reroute you away from danger.', 'বিপদে পড়লে এগুলো ব্যবহার করে আমরা আপনাকে নিরাপদ জায়গায় ফিরিয়ে আনব।');
  String get safeHavensHomeLabel => _t('Home address', 'বাড়ির ঠিকানা');
  String get safeHavensHomeHint => _t('e.g. House 12, Road 5, Dhanmondi', 'যেমন বাড়ি ১২, রোড ৫, ধানমন্ডি');
  String get safeHavensPlaceLabel => _t('A safe place nearby (optional)', 'কাছাকাছি একটি নিরাপদ জায়গা (ইচ্ছা হলে)');
  String get safeHavensPlaceHint => _t('e.g. A trusted relative\'s house', 'যেমন কোনো বিশ্বস্ত আত্মীয়ের বাড়ি');
  String get safeHavensSpokenHint => _t(
        'Two fields follow: home address, which is required, and an optional safe place nearby.',
        'দুটি ঘর আছে: বাড়ির ঠিকানা, যা লিখতেই হবে, আর কাছাকাছি একটি নিরাপদ জায়গা, যা ইচ্ছা হলে লিখতে পারেন।',
      );
  String get safeHavensHomePromptSpoken => _t('Say your home address.', 'আপনার বাড়ির ঠিকানা বলুন।');
  String get safeHavensPlacePromptSpoken => _t(
        'Now say a safe place nearby, if you have one — or say "skip" if not.',
        'এখন কাছাকাছি একটি নিরাপদ জায়গার কথা বলুন, থাকলে — না থাকলে "বাদ" বলুন।',
      );
  List<String> get safeHavensSkipWords =>
      _bn ? const ['বাদ', 'নেই', 'স্কিপ'] : const ['skip', 'none', 'no', "don't have one", 'nothing'];

  // Frequent places (optional) — destinations the user can later ask for
  // by name instead of by address.
  String get placesTitle => _t('Anywhere you go often?', 'নিয়মিত কোথাও যান?');
  String get placesSubtitle => _t(
        'If you tell me now, you can just say "take me to work" later instead of giving the whole address. '
            'You can skip this and add them any time by saying "save this place".',
        'এখন বলে রাখলে পরে শুধু "অফিসে নিয়ে চলো" বললেই হবে, পুরো ঠিকানা বলতে হবে না। '
            'চাইলে এখন বাদ দিয়ে পরে যেকোনো সময় "এই জায়গাটা সেভ করো" বলেও যোগ করতে পারবেন।',
      );
  String get placesSpokenHint => _t(
        'This one is optional. Tell me a place you go to often — like work, school, a relative\'s house, '
            'or your doctor — and then its address. Say "skip" or "done" whenever you want to move on.',
        'এটা ইচ্ছা হলে দিতে পারেন। আপনি নিয়মিত যান এমন একটা জায়গার কথা বলুন — যেমন অফিস, স্কুল, '
            'আত্মীয়ের বাড়ি, বা ডাক্তারের চেম্বার — তারপর তার ঠিকানা। এগিয়ে যেতে চাইলে "বাদ" বা "শেষ" বলুন।',
      );
  String get placesNamePromptSpoken =>
      _t('What do you want to call this place?', 'এই জায়গাটাকে কী নামে ডাকবেন?');
  String get placesAddressPromptSpoken =>
      _t('And what is the address?', 'আর ঠিকানাটা কী?');
  String get placesNameLabel => _t('the place name', 'জায়গার নাম');
  String get placesAddressLabel => _t('the address', 'ঠিকানা');
  String get placesAddAnotherSpoken => _t(
        'Saved. Say "another" to add one more, or "done" to move on.',
        'সেভ হয়ে গেছে। আরেকটা যোগ করতে "আরেকটা" বলুন, নয়তো এগিয়ে যেতে "শেষ" বলুন।',
      );
  String get placesAddAnotherLabel => _t('Add another', 'আরেকটা যোগ করুন');
  List<String> get placesAddAnotherSynonyms =>
      _bn ? const ['আরেকটা', 'আরও', 'আরেকটি'] : const ['another', 'one more', 'add', 'more'];
  String get placesSkipLabel => _t('Skip for now', 'আপাতত বাদ দিন');
  List<String> get placesSkipSynonyms => _bn
      ? const ['বাদ', 'শেষ', 'পরে', 'স্কিপ', 'দরকার নেই']
      : const ['skip', 'done', 'later', 'none', 'no thanks', 'nothing', 'finished'];
  String get placesFieldNameHint => _t('e.g. Work', 'যেমন অফিস');
  String get placesFieldAddressHint => _t('e.g. Gulshan 1, Road 11', 'যেমন গুলশান ১, রোড ১১');
  String get placesAddButton => _t('Add place', 'জায়গা যোগ করুন');
  String placesSavedCount(int n) => n == 0
      ? _t('No places saved yet.', 'এখনো কোনো জায়গা সেভ করা হয়নি।')
      : _t('$n place${n == 1 ? '' : 's'} saved.', '$n টি জায়গা সেভ করা আছে।');

  // Lock-in summary
  // ---- Voice command tour -------------------------------------------

  String get commandTourTitle => _t('How to talk to the app', 'অ্যাপের সাথে যেভাবে কথা বলবেন');
  String get commandTourSubtitle => _t(
        'A few things you can say. You never have to remember them exactly.',
        'কিছু কথা যা আপনি বলতে পারেন। হুবহু মনে রাখার দরকার নেই।',
      );

  /// Grouped so the user hears a *category* before its examples — a flat
  /// list of a dozen sentences is unmemorable read aloud, and this screen
  /// exists to leave an impression, not to be a reference.
  /// [note] is guidance *about* a command rather than something to say —
  /// kept in its own field so it is never narrated in the same breath as a
  /// real example. A user who repeats a sentence like "then say send when
  /// you are done" at the microphone gets nothing, and has no way to tell
  /// which of the lines they were read was the one meant literally.
  List<({String heading, List<String> examples, String? note})> get commandTourGroups => [
        (
          heading: _t('To go somewhere, say', 'কোথাও যেতে বলুন'),
          examples: [
            _t('Take me to Gulshan', 'আমি গুলশান যেতে চাই'),
            _t('Take me home', 'বাসায় যাব'),
            _t('Go to work', 'অফিসে যাব'),
          ],
          note: null,
        ),
        (
          heading: _t('To report something unsafe, say', 'অনিরাপদ কিছু জানাতে বলুন'),
          examples: [
            _t('Report a hazard', 'বিপদ জানাও'),
            _t("There's an open manhole", 'ম্যানহোল আছে'),
          ],
          note: _t(
            'Describe it in your own words, then say "send" to file it.',
            'নিজের ভাষায় বলুন, তারপর পাঠাতে বলুন "সেন্ড"।',
          ),
        ),
        (
          heading: _t('To change a setting, say', 'সেটিং বদলাতে বলুন'),
          examples: [
            _t('Make the text bigger', 'লেখা বড় করো'),
            _t('Speak to me in Bangla', 'বাংলায় বলো'),
            _t('Keep your answers short', 'সংক্ষেপে বলো'),
          ],
          note: _t(
            'Straight after, "even bigger" keeps adjusting the same thing.',
            'এর পরেই "আরও বড়" বললে একই জিনিস আবার বদলাবে।',
          ),
        ),
        (
          heading: _t('For help from a stranger, say', 'অপরিচিত কারও সাহায্য পেতে বলুন'),
          examples: [
            _t('Show my screen', 'স্ক্রিন দেখাও'),
          ],
          note: null,
        ),
      ];

  String get commandTourClosing => _t(
        'You do not have to say these exactly. Say it however feels natural, and the app will work it out. '
        'If it misses twice, it will tell you one short phrase that always works.',
        'এগুলো হুবহু বলতে হবে না। আপনার স্বাভাবিক ভাবেই বলুন, অ্যাপ বুঝে নেবে। '
        'দুইবার না বুঝলে অ্যাপ আপনাকে একটি ছোট বাক্য বলে দেবে যা সবসময় কাজ করে।',
      );

  String get commandTourRepeatLabel => _t('Hear it again', 'আবার শুনুন');
  List<String> get commandTourRepeatSynonyms =>
      _t('again, repeat, one more time, say again', 'আবার, আরেকবার, পুনরায়').split(', ');
  String get commandTourContinueLabel => _t('I am ready', 'আমি প্রস্তুত');
  List<String> get commandTourContinueSynonyms =>
      _t('ready, continue, next, ok, got it, done', 'প্রস্তুত, ঠিক আছে, পরবর্তী, বুঝেছি').split(', ');

  String get lockInTitle => _t('You\'re all set', 'সব প্রস্তুত');
  String get lockInSubtitle => _t(
        'Once you confirm, this setup screen goes away for good. To change anything later, '
            'just tell the AI — for example, say "Change my emergency contact to Mom."',
        'নিশ্চিত করার পর এই সেটআপ স্ক্রিন আর দেখাবে না। পরে কিছু পাল্টাতে '
            'শুধু AI-কে বলুন — যেমন "আমার জরুরি পরিচিতি মা করে দাও।"',
      );
  String get lockInConfirmButton => _t('Confirm and start using ANT', 'নিশ্চিত করুন এবং অ্যান্ট ব্যবহার শুরু করুন');
  List<String> get lockInConfirmSynonyms =>
      _bn ? const ['নিশ্চিত', 'শুরু করুন', 'ঠিক আছে', 'হ্যাঁ'] : const ['confirm', 'start', 'yes', 'done', 'lock in', 'begin'];
  String get lockInVisionLabel => _t('Vision', 'দৃষ্টিশক্তি');
  String get lockInThemeLabel => _t('Theme', 'রং');
  String get lockInMobilityLabel => _t('Mobility', 'চলাফেরা');
  String get lockInDeafLabel => _t('Deaf / hard of hearing', 'কানে শোনার সমস্যা');
  String get lockInVerbosityLabel => _t('AI verbosity', 'AI কথার ধরন');
  String get lockInContactsLabel => _t('Trusted contacts', 'বিশ্বস্ত পরিচিতি');
  String lockInContactsValue(int count) => _t('$count added', '$count জন যোগ হয়েছে');
  String get lockInMessagesLabel => _t('Passerby messages', 'অন্যদের জন্য বার্তা');
  String lockInMessagesValue(int count) => _t('$count ready', '$count টি প্রস্তুত');
  String get lockInHomeLabel => _t('Home address', 'বাড়ির ঠিকানা');
  String get lockInSnapshotLabel => _t('Snapshot permission', 'ছবি তোলার অনুমতি');
  String snapshotConsentLabel(SnapshotConsentPreference pref) => switch (pref) {
        SnapshotConsentPreference.always => snapshotAlwaysLabel,
        SnapshotConsentPreference.askEachTime => snapshotAskLabel,
        SnapshotConsentPreference.never => snapshotNeverLabel,
      };
  String get lockInNotSet => _t('—', '—');
  String get lockInYes => _t('Yes', 'হ্যাঁ');
  List<String> get lockInYesSynonyms => _bn ? const ['জি', 'ঠিক আছে হ্যাঁ', 'হুম'] : const ['yeah', 'yep', 'sure', 'correct', 'true'];
  String get lockInNo => _t('No', 'না');
  List<String> get lockInNoSynonyms => _bn ? const ['না না', 'নাহ'] : const ['nope', 'not really', 'false', 'nah'];
  String get lockInSpokenIntro => _t('Here is a summary before you confirm.', 'নিশ্চিত করার আগে সবকিছু দেখে নিন।');
  String get lockInSpokenOutro => _t(
        'If everything sounds right, tap the button at the bottom to confirm and start using ANT. '
            'Otherwise, use the back button to change anything.',
        'সবকিছু ঠিক থাকলে, নিশ্চিত করে অ্যান্ট ব্যবহার শুরু করতে নিচের বোতামে চাপুন। '
            'কিছু পাল্টাতে চাইলে পেছনের বোতাম ব্যবহার করুন।',
      );
  String get lockInHomeNotSet => _t('not set', 'লেখা হয়নি');

  // Complete (transitional hand-off)
  String get completeMessage => _t('All set — taking you to your dashboard…', 'সব প্রস্তুত — নিয়ে যাচ্ছি…');

  // Shared
  String get backButtonSemantics => _t('Go back to the previous step', 'আগের ধাপে ফিরে যান');
  String get voiceOnSemantics => _t('Voice guidance is on. Double tap to turn off.', 'ভয়েস চালু আছে। বন্ধ করতে দুইবার চাপুন।');
  String get voiceOffSemantics => _t('Voice guidance is off. Double tap to turn on.', 'ভয়েস বন্ধ আছে। চালু করতে দুইবার চাপুন।');
  String get voiceChoiceRetryHint => _t(
      'Sorry, I didn\'t catch that. Say your answer, or say "help" to hear the options.',
      'দুঃখিত, বুঝতে পারিনি। আপনার উত্তর বলুন, অথবা বিকল্পগুলো শুনতে "বিকল্প" বলুন।');
  /// Spoken when the microphone cannot be used at all.
  ///
  /// Every one of these voice loops used to end here with nothing but a
  /// `debugPrint` — the app simply stopped talking. To a blind user that is
  /// indistinguishable from a crash, and it is the reason a release that
  /// shipped without `CLOUD_STT_API_KEY` reached testers as "voice does not
  /// work no matter what you say" rather than as a specific, reportable
  /// fault.
  ///
  /// So it names the problem, and then says the one thing that is still
  /// true: the buttons work.
  String get voiceUnavailableSpoken => _t(
      'I cannot use the microphone right now. You can still tap the buttons on the screen to continue.',
      'এই মুহূর্তে মাইক্রোফোন ব্যবহার করতে পারছি না। আপনি স্ক্রিনের বোতামে চাপ দিয়ে এগিয়ে যেতে পারেন।');

  String get voiceListeningIndicator => _t('Listening for your answer…', 'আপনার উত্তর শুনছি…');
  String get voiceDictateSemantics => _t('Dictate this by voice', 'কথা বলে লিখুন');
  String get voiceDoneWord => _t('done', 'শেষ');

  /// Appended to a spoken yes/no question so the listener knows what a
  /// valid answer sounds like *before* the mic opens, rather than only
  /// after asking for help — see `CognitiveAnxietyScreen`.
  /// Spoken once, on the first screen after the language is chosen.
  ///
  /// A user who cannot see the screen has no way to discover that this app
  /// is voice-driven — nothing announces it, and the alternative is finding
  /// out by accident or not at all. It also teaches the one convention
  /// everything else depends on: **two buzzes mean it is your turn to
  /// speak.** Without that, the microphone opening is invisible and
  /// inaudible, and people talk into a mic that is not listening yet.
  ///
  /// Deliberately short. This is the first thing anyone hears, and a long
  /// preamble before the first question is its own kind of obstacle.
  String get voiceIntroSpoken => _t(
        'Before we start, two quick things. You can do everything here by voice — I will read out '
            'your choices and you just say the one you want, and later you can change any setting '
            'just by telling me, like "make the text bigger" or "take me to work". And whenever you '
            'feel two short buzzes, that means I am listening and it is your turn to speak.',
        'শুরু করার আগে দুটো কথা। এখানে সবকিছু আপনি কথা বলেই করতে পারবেন — আমি বিকল্পগুলো পড়ে শোনাব, '
            'আপনি শুধু যেটা চান সেটা বলবেন। পরে যেকোনো সেটিংও শুধু বলেই পাল্টাতে পারবেন, যেমন '
            '"লেখা বড় করো" বা "অফিসে নিয়ে চলো"। আর যখনই দুইবার ছোট কম্পন অনুভব করবেন, বুঝবেন আমি '
            'শুনছি — তখন আপনি বলবেন।',
      );

  String get voiceAnswerYesOrNo =>
      _t('Answer yes or no.', 'হ্যাঁ অথবা না বলুন।');

  /// Accepted confirmations when a dictated value is read back for
  /// checking. Wider than a bare yes/no on purpose — people confirm a
  /// read-back with "correct", "that's it", "ঠিক আছে" far more often than
  /// with a flat "yes", and rejecting those would make the user repeat
  /// themselves over a value that was already right.
  List<String> get confirmYesWords => _bn
      ? const ['হ্যাঁ', 'হ্যা', 'জি', 'ঠিক', 'ঠিক আছে', 'হুম', 'সঠিক']
      : const ['yes', 'yeah', 'yep', 'yup', 'correct', 'right', 'sure', 'ok', 'okay', 'perfect', 'exactly'];

  List<String> get confirmNoWords => _bn
      ? const ['না', 'নাহ', 'ভুল', 'আবার', 'ঠিক নয়']
      : const ['no', 'nope', 'nah', 'wrong', 'incorrect', 'again', 'redo', 'change'];

  /// Numbers a spoken choice — "Option 1: …", "বিকল্প ১: …".
  ///
  /// Was hardcoded English inline in six screens, so a Bangla user's
  /// narration read "Option 1: [Bangla label]". The Bangla numeral matters
  /// as much as the word: a `bn-BD` TTS voice reads a bare ASCII "1" with
  /// an English-accented pronunciation mid-Bangla-sentence.
  String spokenOptionLabel(int number) =>
      _bn ? 'বিকল্প ${_bengaliNumeral(number)}' : 'Option $number';

  /// ASCII digits → Bengali numerals (০-৯), for numbers spoken aloud in
  /// Bangla. Mirrors the reverse conversion in `spokenTextToDigits`.
  String _bengaliNumeral(int number) => number
      .toString()
      .split('')
      .map((c) => String.fromCharCode(0x09E6 + (c.codeUnitAt(0) - 0x30)))
      .join();

  /// Localized labels for the disability-profile enums, used by
  /// [MySettingsScreen]/[RemoteManagementScreen] chips as well as onboarding.
  String visionLevelLabel(VisionLevel level) => switch (level) {
        VisionLevel.none => visionNoneLabel,
        VisionLevel.low => visionLowLabel,
        VisionLevel.full => visionFullLabel,
      };
  String mobilityAidLabel(MobilityAid aid) => switch (aid) {
        MobilityAid.whiteCane => mobilityWhiteCaneLabel,
        MobilityAid.wheelchair => mobilityWheelchairLabel,
        MobilityAid.unassisted => mobilityUnassistedLabel,
      };
  String verbosityLevelLabel(VerbosityLevel v) => switch (v) {
        VerbosityLevel.minimalist => verbosityMinimalistLabel,
        VerbosityLevel.descriptive => verbosityDescriptiveLabel,
      };
  String themePreferenceLabel(ThemePreference t) => switch (t) {
        ThemePreference.light => themeLightLabel,
        ThemePreference.dark => themeDarkLabel,
      };

  /// The default Passerby Helper message set, localized — used as the
  /// dashboard's fallback whenever [UserProfile.passerbyHelperMessages] is
  /// empty (profiles created before this feature existed, or an
  /// unpaired/edge-case flow).
  List<String> get defaultPasserbyMessages => [
        passerbyVisuallyImpaired,
        passerbyDeaf,
        passerbyRoadFlooded,
        passerbyWhichBus,
      ];
}
