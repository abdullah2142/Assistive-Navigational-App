import '../../features/dashboard/models/hazard_report.dart';
import 'app_language.dart';

/// All UI text for the Split-Mode Dashboard, My Settings, the Crowdsource
/// Reporting Hub, and the Passerby Helper overlay/picker — everything the
/// Disabled User sees after onboarding. Mirrors [Onboarding]'s pattern:
/// `Dashboard.of(language)` once per build.
///
/// Bangla wording throughout is deliberately plain, everyday spoken Bangla —
/// common English loanwords already used in daily Bangla tech speech
/// (রিপোর্ট, ভয়েস, সেভ, কনট্রাস্ট) over their more formal/Sanskrit-derived
/// equivalents, and short concrete phrasing over technical compound nouns —
/// since several people this app is built for may have low literacy or
/// cognitive load limits. When in doubt, prefer the word a market vendor or
/// a rickshaw driver would use over the word a government form would use.
class Dashboard {
  const Dashboard._(this._bn);

  factory Dashboard.of(AppLanguage language) => Dashboard._(language == AppLanguage.bangla);

  final bool _bn;
  String _t(String en, String bn) => _bn ? bn : en;

  // Chat stream
  String get chatWelcome => _t(
        'I\'m your assistant. Tap the mic or type below.',
        'আমি আপনার সহকারী। মাইক চাপুন অথবা লিখুন।',
      );
  String get chatInputHint => _t('Type or tap the mic…', 'লিখুন অথবা মাইকে চাপুন…');
  String get chatSpeakSemantics => _t('Speak to your assistant', 'সহকারীর সাথে কথা বলুন');
  String get chatSpeakHint => _t('Tap, then speak', 'চাপুন, তারপর বলুন');
  String get chatListeningSemantics => _t('Listening… tap again to stop', 'শুনছি… থামাতে আবার চাপুন');
  String get chatVoiceUnavailable =>
      _t('Voice input isn\'t available on this device.', 'এই ডিভাইসে ভয়েস ইনপুট নেই।');
  String get chatSendSemantics => _t('Send message', 'বার্তা পাঠান');
  String get chatAssistantTyping => _t('Assistant is typing', 'সহকারী লিখছে');
  String chatYouSaid(String text) => _t('You said: $text', 'আপনি বলেছেন: $text');
  String chatAssistantSaid(String text) => _t('Assistant said: $text', 'সহকারী বলেছে: $text');
  String get chatStubReply => _t(
        'Got it — I\'ve noted that. Full understanding of open-ended requests like this arrives with the AI Assistant module.',
        'ঠিক আছে, লিখে রাখলাম। এই ধরনের কথা পুরোপুরি বোঝার ক্ষমতা পরে যোগ হবে।',
      );
  String get chatAskDestination => _t('Where would you like to go?', 'আপনি কোথায় যেতে চান?');
  String get chatStubBusScan =>
      _t('Bus sign scanning needs the Snapshot Vision Engine, which is Module 6.', 'বাসের সাইনবোর্ড পড়ে দেওয়ার কাজটি পরে যোগ হবে।');

  // Suggested chips
  String get chipRouteToWork => _t('Route to Work', 'কাজের পথ');
  String get chipScanBus => _t('Scan the next bus', 'বাসের নাম্বার দেখুন');
  String get chipShowScreen => _t('Show screen to passerby', 'কাউকে স্ক্রিন দেখান');
  String get chipReportHazard => _t('Report a hazard', 'বিপদ জানান');

  // Map
  String get mapUnavailableTitle => _t('Map unavailable', 'মানচিত্র নেই');
  String get mapUnavailableSubtitle => _t('A Google Maps API key hasn\'t been configured yet.', 'মানচিত্র এখনো চালু করা হয়নি।');
  String get mapLiveViewLabel => _t('Live map view', 'সরাসরি মানচিত্র');
  String get mapNextDirection => _t('Next direction: continue forward', 'পরের নির্দেশ: সোজা যান');

  /// Spoken/screen-reader label for the giant directional arrow once a real
  /// route (Module 4) is active, replacing [mapNextDirection]'s static text.
  String mapRouteStatus({required bool safe, required bool wasRerouted, required double distanceMeters}) {
    final km = (distanceMeters / 1000).toStringAsFixed(distanceMeters >= 1000 ? 1 : 2);
    if (!safe) {
      return _t(
        'Continue ahead — $km km to go. This is the safest route found, but still passes a risky area.',
        'সামনে এগিয়ে যান — বাকি আছে $km কিলোমিটার। এটাই সবচেয়ে নিরাপদ পথ, তবে কিছুটা ঝুঁকিপূর্ণ এলাকা দিয়ে যায়।',
      );
    }
    if (wasRerouted) {
      return _t(
        'Continue ahead — $km km to go. Route adjusted to avoid an unsafe area.',
        'সামনে এগিয়ে যান — বাকি আছে $km কিলোমিটার। অনিরাপদ এলাকা এড়াতে পথ পাল্টানো হয়েছে।',
      );
    }
    return _t('Continue ahead — $km km to go.', 'সামনে এগিয়ে যান — বাকি আছে $km কিলোমিটার।');
  }

  // Passerby Helper overlay / picker
  String get passerbyPickerTitle => _t('What do you need to say?', 'কী বলতে চান?');
  String get passerbyPickerSubtitle =>
      _t('Pick a message, or type your own — it\'ll show full-screen so a passerby can read it.', 'একটি বার্তা বেছে নিন, বা নিজে লিখুন — এটি বড় করে স্ক্রিনে দেখাবে যাতে অন্য কেউ পড়তে পারে।');
  String get passerbyPickerComposeHint => _t('Or write your own…', 'অথবা নিজে লিখুন…');
  String get passerbyPickerShowButton => _t('Show This', 'দেখান');
  String get passerbyOverlayTapToClose => _t('Tap anywhere to close.', 'বন্ধ করতে যেকোনো জায়গায় চাপুন।');
  String get passerbyOverlayShownAnnouncement =>
      _t('Showing your screen now. Say "go back" any time to return, or tap anywhere to close.',
          'স্ক্রিন দেখাচ্ছি। ফিরে যেতে যেকোনো সময় "ফিরে যাও" বলুন, বা বন্ধ করতে চাপুন।');
  String get passerbyWriteFieldSemantics => _t('Write your own message', 'নিজের বার্তা লিখুন');
  String get passerbySpeakSemantics => _t('Speak your message', 'কথা বলে বলুন');
  String get passerbySpeakHint => chatSpeakHint;
  String get passerbyPickerContinueOrShowSpoken =>
      _t('Got it. Say more, or say "show it" to display your message now.',
          'ঠিক আছে। আরও বলুন, বা এখনই দেখাতে "দেখাও" বলুন।');

  // Crowdsource Reporting Hub
  String get crowdsourceTitle => _t('Report a Hazard', 'বিপদ জানান');
  String get crowdsourceDescribeItTitle => _t('Describe It', 'বলুন কী হয়েছে');
  String get crowdsourceBackSemantics => _t('Back', 'পেছনে');
  String get crowdsourceCloseSemantics => _t('Close', 'বন্ধ করুন');
  String get passerbyPickerCloseSemantics => _t('Close, cancel showing a message', 'বন্ধ করুন, বার্তা দেখানো বাতিল করুন');
  String get crowdsourceOptionalDetails =>
      _t('Add any details (optional). Tap the mic to dictate.', 'ইচ্ছা হলে আরেকটু বলুন। বলে দিতে মাইকে চাপুন।');
  String get crowdsourceDescribeHint =>
      _t('Type or speak what\'s happening — we\'ll summarize it for the report.', 'কী হচ্ছে লিখুন বা বলুন — আমরা এটি ছোট করে লিখে দেব।');
  String get crowdsourceDescriptionHint => _t('Describe what happened…', 'কী হয়েছে বলুন…');
  String get crowdsourceDescriptionFieldSemantics => _t('Describe what happened', 'কী হয়েছে বলুন');
  String get crowdsourceSpeakSemantics => _t('Speak your description', 'কথা বলে বলুন');
  String get crowdsourceAiSummaryLabel => _t('AI summary (this is what gets submitted)', 'ছোট করে লেখা (এটাই পাঠানো হবে)');
  String get crowdsourceSubmitButton => _t('Submit Report', 'পাঠান');
  String get crowdsourceSubmitSuccess => _t('Thanks — your report was pinned to the map.', 'ধন্যবাদ — এটি মানচিত্রে যোগ হয়েছে।');
  String crowdsourceSubmitError(String error) => _t('Couldn\'t submit the report: $error', 'পাঠানো যায়নি: $error');
  String get crowdsourceVoiceUnavailable => chatVoiceUnavailable;
  String crowdsourceCategoryPrompt(String optionsList) =>
      _t('Report a hazard. Choose a category: $optionsList. Say one, or tap it.',
          'বিপদ জানাতে একটি বিভাগ বেছে নিন: $optionsList। বলুন, বা চাপুন।');
  String crowdsourceSubCategoryPrompt(String categoryLabel, String optionsList) =>
      _t('$categoryLabel. Choose: $optionsList. Say one, or tap it.',
          '$categoryLabel। বেছে নিন: $optionsList। বলুন, বা চাপুন।');
  String get crowdsourceDescribePromptSpoken => _t(
      'Now describe what happened. When you\'re done, say "submit" to send the report, or tap Submit.',
      'এখন কী হয়েছে বলুন। বলা শেষ হলে "পাঠাও" বলুন, অথবা পাঠান বাটনে চাপুন।');
  String get crowdsourceOptionalPromptSpoken => _t(
      'Report ready. Add more details if you want, or say "submit" to send it now.',
      'রিপোর্ট তৈরি। চাইলে আরও বলুন, নাহলে এখনই পাঠাতে "পাঠাও" বলুন।');
  String crowdsourceCategorySelectedSpoken(String label) => _t('$label selected.', '$label বেছে নেওয়া হয়েছে।');
  String get crowdsourceContinueOrSubmitSpoken =>
      _t('Got it. Say more, or say "submit" to send.', 'ঠিক আছে। আরও বলুন, বা পাঠাতে "পাঠাও" বলুন।');

  String hazardCategoryLabel(HazardCategory category) => switch (category) {
        HazardCategory.crime => _t('Crime', 'অপরাধ'),
        HazardCategory.roadHazard => _t('Road Hazard', 'রাস্তার সমস্যা'),
        HazardCategory.accessibilityBlock => _t('Accessibility Block', 'চলাচলে বাধা'),
      };

  static const _otherKey = 'other';

  /// Keys into [hazardSubCategoryLabel] — kept English/stable as Firestore
  /// data (the `HazardReport.subCategory` field), same pattern as every
  /// other enum in this app. The *label* is what's localized.
  List<String> hazardSubCategoryKeys(HazardCategory category) => switch (category) {
        HazardCategory.crime => const [
            'mugging',
            'harassment',
            'suspiciousCrowd',
            'theftPickpocketing',
            'stalking',
            'verbalAbuse',
            'physicalAssault',
            'poorLighting',
            _otherKey,
          ],
        HazardCategory.roadHazard => const [
            'pothole',
            'flooding',
            'construction',
            'noSidewalk',
            'openManhole',
            'brokenStreetlight',
            'recklessTraffic',
            'illegalParking',
            'debrisFallenTree',
            _otherKey,
          ],
        HazardCategory.accessibilityBlock => const [
            'brokenRamp',
            'blockedPath',
            'noCurbCut',
            'stairsOnly',
            'narrowPassage',
            'noTactilePaving',
            'elevatorOutOfService',
            'blockedByVendors',
            _otherKey,
          ],
      };

  bool isOtherSubCategoryKey(String key) => key == _otherKey;

  String hazardSubCategoryLabel(String key) => switch (key) {
        'mugging' => _t('Mugging', 'ছিনতাই'),
        'harassment' => _t('Harassment', 'উত্যক্ত করা'),
        'suspiciousCrowd' => _t('Suspicious Crowd', 'সন্দেহজনক লোকজন'),
        'theftPickpocketing' => _t('Theft / Pickpocketing', 'চুরি / পকেট মারা'),
        'stalking' => _t('Stalking', 'পিছু নেওয়া'),
        'verbalAbuse' => _t('Verbal Abuse', 'গালিগালাজ'),
        'physicalAssault' => _t('Physical Assault', 'মারধর'),
        'poorLighting' => _t('Poor / No Street Lighting', 'রাস্তায় আলো নেই'),
        'pothole' => _t('Pothole', 'গর্ত'),
        'flooding' => _t('Flooding', 'পানি জমে আছে'),
        'construction' => _t('Construction', 'নির্মাণকাজ চলছে'),
        'noSidewalk' => _t('No Sidewalk', 'ফুটপাত নেই'),
        'openManhole' => _t('Open Manhole', 'ম্যানহোল খোলা'),
        'brokenStreetlight' => _t('Broken Streetlight', 'রাস্তার বাতি নষ্ট'),
        'recklessTraffic' => _t('Reckless Traffic', 'গাড়ি বেপরোয়াভাবে চলে'),
        'illegalParking' => _t('Illegal Parking Blocking Path', 'গাড়ি রাস্তা আটকে রেখেছে'),
        'debrisFallenTree' => _t('Debris / Fallen Tree', 'ভাঙা জিনিস / গাছ পড়ে আছে'),
        'brokenRamp' => _t('Broken Ramp', 'ঢালু পথ ভাঙা'),
        'blockedPath' => _t('Blocked Path', 'পথ আটকানো'),
        'noCurbCut' => _t('No Curb Cut', 'হুইলচেয়ারের জন্য ঢালু পথ নেই'),
        'stairsOnly' => _t('Stairs Only', 'শুধু সিঁড়ি, র‍্যাম্প নেই'),
        'narrowPassage' => _t('Narrow Passage', 'পথ খুব সরু'),
        'noTactilePaving' => _t('No Tactile Paving', 'অন্ধদের হাঁটার বিশেষ পথ নেই'),
        'elevatorOutOfService' => _t('Elevator Out of Service', 'লিফট নষ্ট'),
        'blockedByVendors' => _t('Blocked by Vendors', 'হকাররা রাস্তা আটকে রেখেছে'),
        _otherKey => _t('Something else (describe it)', 'অন্য কিছু (বলুন কী)'),
        _ => key,
      };

  // My Settings
  String get settingsTitle => _t('My Settings', 'আমার সেটিংস');
  String get settingsEntrySemantics =>
      _t('My Settings — review or change what you set up during onboarding', 'আমার সেটিংস — শুরুতে যা যা ঠিক করেছিলেন তা দেখুন বা পাল্টান');
  String get settingsCouldNotLoad => _t('Couldn\'t load profile', 'তথ্য আনা যায়নি');
  String get settingsPairingSection => _t('Caretaker', 'দেখাশোনাকারী');
  String get settingsPairingIntro =>
      _t('Have a caretaker now? Enter the 6-digit code from their app to link up — you can also just ask me in chat.',
          'এখন কি একজন দেখাশোনাকারী আছেন? তাদের অ্যাপের ৬ সংখ্যার কোডটি দিন — চ্যাটেও বলতে পারেন।');
  String get settingsPairingCodeHint => _t('6-digit code', '৬ সংখ্যার কোড');
  String get settingsPairingButton => _t('Pair', 'যুক্ত করুন');
  String settingsPairedWithLabel(String name) =>
      name.isEmpty ? _t('Paired with a caretaker', 'একজন দেখাশোনাকারীর সাথে যুক্ত') : _t('Paired with $name', '$name-এর সাথে যুক্ত');
  String get settingsPairingErrorNotFound =>
      _t("Couldn't find that code. Ask your caretaker for a new one.", 'এই কোডটি খুঁজে পাইনি। দেখাশোনাকারীকে নতুন কোড দিতে বলুন।');
  String get settingsPairingErrorExpired =>
      _t('That code expired. Ask your caretaker for a new one.', 'কোডটির মেয়াদ শেষ হয়ে গেছে। দেখাশোনাকারীকে নতুন কোড দিতে বলুন।');
  String get settingsPairingErrorUsed => _t('That code has already been used.', 'কোডটি আগেই ব্যবহার হয়ে গেছে।');
  String get settingsPairingErrorGeneric => _t("Couldn't pair — please try again.", 'যুক্ত করা যায়নি — আবার চেষ্টা করুন।');
  String get settingsVisionSection => _t('Vision', 'চোখের অবস্থা');
  String get settingsThemeSection => _t('Theme', 'রং');
  String get settingsLanguageSection => _t('Language', 'ভাষা');
  String get settingsTextSizeSection => _t('Text size', 'লেখার আকার');
  String settingsTextSizeSemantics(String scale) => _t('Text size, currently $scale times normal', 'লেখার আকার এখন স্বাভাবিকের $scale গুণ');
  String get settingsMobilitySection => _t('Mobility aid', 'চলাচলে সাহায্য');
  String get settingsCognitiveSection => _t('Cognitive & anxiety', 'উদ্বেগ ও চাপ');
  String get settingsCrowdedSwitch => _t('Crowded places make me feel anxious', 'ভিড়ে আমার অস্বস্তি লাগে');
  String get settingsComplexSwitch => _t('Complex, multi-step instructions are hard to follow', 'অনেক ধাপের কঠিন নির্দেশ বুঝতে আমার অসুবিধা হয়');
  String get settingsDeafSection => _t('Deaf / hard of hearing', 'কানে কম শোনেন বা শোনেন না');
  String get settingsDeafSwitch => _t('Show text and visuals instead of relying on audio', 'শব্দের বদলে লেখা ও ছবি দেখান');
  String get settingsVerbositySection => _t('Assistant verbosity', 'সহকারী কতটা কথা বলবে');
  String get settingsVoiceSection => _t('Voice', 'ভয়েস');
  String get settingsWakeWordSection => _t('"Hey ANT" voice trigger', '"Hey ANT" ভয়েস ট্রিগার');
  String get settingsWakeWordSwitch =>
      _t('Listen for "Hey ANT" so I can talk without tapping the mic', '"Hey ANT" বললে মাইকে না চেপেই কথা বলা যাবে');
  String get settingsAutoListenSection => _t('Auto-listen', 'নিজে থেকে শোনা');
  String get settingsAutoListenSwitch =>
      _t('Start listening automatically when a voice input opens, instead of tapping the mic first',
          'ভয়েস ইনপুট খুললে মাইকে চাপ না দিয়েই নিজে থেকে শোনা শুরু হবে');
  String get settingsContactsSection => _t('Magic Button contacts', 'ম্যাজিক বাটনের পরিচিতি');
  String get settingsMessagesSection => _t('Passerby messages', 'অন্যদের জন্য বার্তা');
  String get settingsHavensSection => _t('Safe havens', 'নিরাপদ জায়গা');
  String get settingsHomeLabel => _t('Home address', 'বাড়ির ঠিকানা');
  String get settingsSafePlaceLabel => _t('Safe place (optional)', 'নিরাপদ জায়গা (ইচ্ছা হলে)');
  String get settingsSaveAddressesButton => _t('Save addresses', 'সেভ করুন');
  String get settingsNamePlaceholder => _t('Name', 'নাম');
  String get settingsPhonePlaceholder => _t('Phone', 'ফোন নম্বর');
  String get settingsAddContactButton => _t('Add contact', 'পরিচিতি যোগ করুন');
  String settingsRemoveContactSemantics(String name) => _t('Remove $name', '$name বাদ দিন');
  String get settingsRemoveMessageSemantics => _t('Remove this message', 'এই বার্তা বাদ দিন');
  String get settingsWriteMessageHint => _t('Write or dictate a new message…', 'নতুন বার্তা লিখুন বা বলুন…');
  String get settingsWriteMessageSemantics => _t('Write a new passerby message', 'নতুন বার্তা লিখুন');
  String get settingsSpeakMessageSemantics => _t('Speak your message', 'কথা বলে বলুন');
  String get settingsAddMessageButton => _t('Add message', 'বার্তা যোগ করুন');
  String get settingsFooterNote => _t('Changes here save immediately.', 'এখানে যা পাল্টাবেন সাথে সাথে সেভ হবে।');

  String languageLabel(AppLanguage language) =>
      language == AppLanguage.bangla ? _t('Bangla', 'বাংলা') : _t('English', 'ইংরেজি');
}
