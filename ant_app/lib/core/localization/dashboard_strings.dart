import '../../features/dashboard/models/hazard_report.dart';
import '../services/routing_service.dart' show ManeuverKind;
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
  String get chatTypeInsteadSemantics => _t('Type instead', 'বদলে লিখুন');

  /// Spoken right after a read-back, so the escape route is part of the
  /// same breath as the thing being confirmed — a user who has to remember
  /// a cancel word from an earlier screen does not have one.
  String cancelWindowPrompt(int seconds) => _t(
        'Sending in $seconds seconds. Say cancel to stop, or change it to say it again.',
        '$seconds সেকেন্ডে পাঠানো হবে। থামাতে বলুন বাতিল, আবার বলতে চাইলে বলুন বদলাও।',
      );
  String get cancelWindowCancelled => _t('Cancelled. Nothing was sent.', 'বাতিল হয়েছে। কিছু পাঠানো হয়নি।');
  String cancelWindowReadBack(String value) =>
      _t('You said: $value.', 'আপনি বলেছেন: $value।');
  String get chatCloseKeyboardSemantics => _t('Close the keyboard', 'কীবোর্ড বন্ধ করুন');
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
  String get mapExpandSemantics => _t('Expand map to full screen', 'মানচিত্র পুরো স্ক্রিনে দেখুন');
  String get mapCollapseSemantics => _t('Shrink map back to split view', 'মানচিত্র আবার ভাগ করা স্ক্রিনে আনুন');

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

  // Working out where an unknown destination actually is.
  //
  // The rule these follow: **never ask the same question twice.** A user
  // who could answer "where is it?" would have answered it the first time.
  // Each round asks for a different kind of clue — an area, then a
  // landmark — because that is how a person actually helps someone find a
  // place they cannot name precisely.

  /// First round: ask for the area. Broad, easy to answer, and the single
  /// most useful thing for narrowing a Dhaka search.
  String clarifyAskArea(String place) => _t(
        "I couldn't find $place. Which area is it in — Dhanmondi, Mirpur, Uttara, somewhere else?",
        '$place খুঁজে পেলাম না। এটা কোন এলাকায় — ধানমন্ডি, মিরপুর, উত্তরা, নাকি অন্য কোথাও?',
      );

  /// Second round: ask for a landmark. Someone who could not name the area
  /// can usually still name what is next to it.
  String clarifyAskLandmark(String place) => _t(
        "Still not finding $place. Is there a landmark near it — a market, a hospital, a big road, "
            'a bus stop?',
        '$place এখনো পাচ্ছি না। এর কাছাকাছি চেনা কিছু আছে — কোনো বাজার, হাসপাতাল, বড় রাস্তা, বাস স্ট্যান্ড?',
      );

  /// Asked when the geocoder found several genuinely different places.
  /// Numbered, because a user who cannot see a list cannot point at one.
  String clarifyChooseOption(List<String> labels) {
    final numbered = [
      for (var i = 0; i < labels.length; i++)
        _bn ? '${_bengaliNumeral(i + 1)}, ${labels[i]}' : '${i + 1}, ${labels[i]}',
    ].join('. ');
    return _t(
      'I found a few places by that name. $numbered. Which one — say the number, or the name.',
      'ওই নামে কয়েকটা জায়গা পেয়েছি। $numbered। কোনটা — নম্বরটা বলুন, বা নামটা বলুন।',
    );
  }

  String _bengaliNumeral(int n) => n
      .toString()
      .split('')
      .map((c) => String.fromCharCode(0x09E6 + (c.codeUnitAt(0) - 0x30)))
      .join();

  /// Given up after [DestinationClarification.maxAttempts].
  ///
  /// Ends with something the user can actually do, not an apology. Being
  /// told "sorry, I failed" while standing on a footpath is worthless; being
  /// told the two things that *do* work is not.
  String clarifyGaveUp(String place) => _t(
        "I still can't place $place, and I don't want to send you the wrong way. Two things that will "
            'work: if you have been there before, ask someone nearby for the area name and tell me that. '
            'Or, once you are there, say "save this place" and I will remember it for next time.',
        '$place কোথায় সেটা এখনো বুঝতে পারছি না, আর ভুল পথে পাঠাতে চাই না। দুটো উপায় আছে: আগে গিয়ে থাকলে '
            'আশেপাশের কাউকে এলাকার নাম জিজ্ঞেস করে আমাকে বলুন। অথবা একবার পৌঁছে গিয়ে "এই জায়গাটা সেভ করো" '
            'বললে পরেরবারের জন্য আমি মনে রাখব।',
      );

  String get clarifyCancelled =>
      _t('Alright, I have dropped that.', 'ঠিক আছে, ওটা বাদ দিলাম।');

  /// Re-asked when a reply carried nothing usable.
  String get clarifyUnclear => _t(
        "Sorry, I didn't catch that. Tell me anything you know about where it is, "
            'or say "cancel" to stop looking.',
        'দুঃখিত, বুঝতে পারিনি। জায়গাটা সম্পর্কে যা জানেন বলুন, অথবা খোঁজা বন্ধ করতে "বাদ" বলুন।',
      );

  /// Said after a clarified destination finally resolves. Offers to save it,
  /// because a place that took three questions to find is precisely the one
  /// worth never having to find again.
  String clarifyResolvedOfferSave(String place) => _t(
        'Found it. Say "save this place" when you get there and I will remember $place for next time.',
        'পেয়ে গেছি। পৌঁছে গিয়ে "এই জায়গাটা সেভ করো" বললে $place পরেরবারের জন্য মনে রাখব।',
      );

  // Saved places — frequent destinations ("work", "Ma's house") the user
  // can ask for by name.

  String savedPlaceRouting(String label) =>
      _t('Heading to $label — I have that saved, so no need to look it up.',
          '$label-এর দিকে যাচ্ছি — এটা আমার সেভ করা আছে, খুঁজতে হবে না।');

  String savedPlaceStored({required String label, required bool usedCurrentLocation}) =>
      usedCurrentLocation
          ? _t('Saved where you are now as "$label". Say "take me to $label" any time.',
              'আপনি এখন যেখানে আছেন সেটা "$label" নামে সেভ করলাম। যেকোনো সময় "$label-এ নিয়ে চলো" বলুন।')
          : _t('Saved "$label". Say "take me to $label" any time.',
              '"$label" সেভ করলাম। যেকোনো সময় "$label-এ নিয়ে চলো" বলুন।');

  String savedPlaceRemoved(String label) =>
      _t('Removed "$label" from your saved places.', '"$label" আপনার সেভ করা জায়গা থেকে সরিয়ে দিলাম।');

  String get savedPlaceUnknown =>
      _t("I don't have a place saved by that name.", 'ওই নামে কোনো জায়গা সেভ করা নেই।');

  /// Asked instead of guessing when a spoken name matches more than one
  /// saved place. Walking someone to the wrong relative's house is a
  /// failure they may not notice until they arrive.
  String savedPlaceAmbiguous(List<String> options) {
    final list = options.join(_bn ? ', নাকি ' : ', or ');
    return _t('I have more than one place like that — did you mean $list?',
        'ওই রকম একাধিক জায়গা সেভ করা আছে — আপনি কি $list বোঝাচ্ছেন?');
  }

  String get savedPlaceNeedsLocation => _t(
        "I can't tell where you are right now, so I can't save this spot. "
            'Tell me the address instead and I will save that.',
        'আপনি এখন কোথায় আছেন বুঝতে পারছি না, তাই এই জায়গাটা সেভ করতে পারলাম না। '
            'ঠিকানাটা বলুন, সেটাই সেভ করে রাখি।',
      );

  /// Read back before a voice-given value is committed.
  ///
  /// Every dictated value in this app gets spoken back for confirmation,
  /// and this is the shared wording. A sighted user glances at the field
  /// and sees the recognizer dropped a digit; a blind user has no such
  /// moment, so the read-back *is* their only chance to catch it. Digits
  /// are spaced out by the caller (see `spokenDigitsForReadback`) because
  /// a text-to-speech engine reads "01712" as a single enormous number
  /// otherwise, which is unverifiable by ear.
  String confirmHeardValue({required String fieldLabel, required String value}) => _t(
        'I heard $fieldLabel: $value. Is that right? Say yes to keep it, or no to say it again.',
        '$fieldLabel শুনলাম: $value। ঠিক আছে? রাখতে "হ্যাঁ" বলুন, আবার বলতে "না" বলুন।',
      );

  String get confirmValueAccepted => _t('Got it.', 'ঠিক আছে।');
  String get confirmValueRetry => _t('No problem — say it again.', 'সমস্যা নেই — আবার বলুন।');

  // Turn-by-turn navigation narration.
  //
  // Phrased for someone who cannot see the road, which changes the wording
  // in two specific ways from what a sighted navigation app says:
  //
  // - **Direction first, distance second.** "Turn left in 50 metres" makes
  //   the listener hold a direction while waiting for the distance; "In 50
  //   metres, turn left" lets them hear how urgent it is before the
  //   instruction lands. Speech is linear — order is the interface.
  // - **No street names when the backend has none.** Dhaka is full of
  //   unnamed lanes, and "turn left onto unnamed road" is worse than "turn
  //   left": it sounds like information and carries none.

  String maneuverDirection(ManeuverKind kind) => switch (kind) {
        ManeuverKind.depart => _t('set off', 'রওনা দিন'),
        ManeuverKind.straight => _t('keep going straight', 'সোজা যেতে থাকুন'),
        ManeuverKind.slightLeft => _t('bear slightly left', 'একটু বাঁ দিকে চাপুন'),
        ManeuverKind.left => _t('turn left', 'বাঁ দিকে ঘুরুন'),
        ManeuverKind.sharpLeft => _t('take the sharp left', 'জোরে বাঁ দিকে ঘুরুন'),
        ManeuverKind.slightRight => _t('bear slightly right', 'একটু ডান দিকে চাপুন'),
        ManeuverKind.right => _t('turn right', 'ডান দিকে ঘুরুন'),
        ManeuverKind.sharpRight => _t('take the sharp right', 'জোরে ডান দিকে ঘুরুন'),
        ManeuverKind.uTurn => _t('turn around', 'পেছনে ঘুরুন'),
        ManeuverKind.roundabout => _t('go around the roundabout', 'গোল চত্বর ঘুরে যান'),
        ManeuverKind.crossing => _t('cross the road', 'রাস্তা পার হন'),
        ManeuverKind.arrive => _t('you have arrived', 'আপনি পৌঁছে গেছেন'),
      };

  /// Rounded to something a walking person can actually judge — 10 m steps
  /// up close, 50 m further out. Reading "in 187 metres" aloud is precision
  /// nobody can pace out and takes longer to say than it is worth.
  String spokenDistance(double meters) {
    if (meters < 20) return _t('a few steps', 'কয়েক কদম');
    final rounded = meters < 100 ? (meters / 10).round() * 10 : (meters / 50).round() * 50;
    return _bn ? '$rounded মিটার' : '$rounded metres';
  }

  /// Far-out and mid-range warning: distance first, then the turn.
  String navigateTurnAhead({
    required ManeuverKind kind,
    required double meters,
    String streetName = '',
  }) {
    final direction = maneuverDirection(kind);
    final distance = spokenDistance(meters);
    if (streetName.isEmpty) {
      return _t('In $distance, $direction.', '$distance পরে, $direction।');
    }
    return _t('In $distance, $direction onto $streetName.', '$distance পরে, $streetName-এ $direction।');
  }

  /// The instruction itself, at the turn.
  String navigateTurnNow({required ManeuverKind kind, String streetName = ''}) {
    final direction = maneuverDirection(kind);
    if (streetName.isEmpty) return _t('Now, $direction.', 'এখন, $direction।');
    return _t('Now, $direction onto $streetName.', 'এখন, $streetName-এ $direction।');
  }

  /// Final manoeuvre — says so, so the user knows to start looking for the
  /// door rather than the next street.
  String navigateFinalTurn({required ManeuverKind kind, String streetName = ''}) {
    final direction = maneuverDirection(kind);
    return streetName.isEmpty
        ? _t('$direction — your destination is just ahead.', '$direction — গন্তব্য একদম সামনেই।')
        : _t('$direction onto $streetName — your destination is just ahead.',
            '$streetName-এ $direction — গন্তব্য একদম সামনেই।');
  }

  String get navigateArrived =>
      _t('You have arrived at your destination.', 'আপনি গন্তব্যে পৌঁছে গেছেন।');

  /// Said once when the user leaves the route corridor.
  ///
  /// Deliberately does not bark "make a U-turn": a blind pedestrian who has
  /// drifted needs to *stop* before doing anything else, and being told to
  /// reverse direction immediately, on a Dhaka street, without being able to
  /// see what is behind them, is not a safe instruction. Stop, then
  /// re-plan.
  String get navigateOffRoute => _t(
        'It looks like we have come off the route. Stop somewhere safe when you can, '
            'and say "re-route" and I will find the way from where you are now.',
        'মনে হচ্ছে আমরা পথ থেকে সরে গেছি। সুবিধা মতো নিরাপদ জায়গায় দাঁড়ান, '
            'আর "নতুন পথ" বলুন — আমি এখান থেকে আবার পথ খুঁজে দেব।',
      );

  /// Spoken when navigation starts, before the first manoeuvre.
  String navigateStarted({required String destination, required double totalMeters}) => _t(
        'Starting navigation to $destination, ${spokenDistance(totalMeters)} in total. '
            'I will tell you each turn as it comes.',
        '$destination-এর দিকে যাত্রা শুরু করছি, মোট ${spokenDistance(totalMeters)}। '
            'প্রতিটি মোড় আসার আগে আমি বলে দেব।',
      );

  String get navigateStopped => _t('Navigation stopped.', 'পথ দেখানো বন্ধ করলাম।');

  /// Used when a route was planned but the backend returned no manoeuvres,
  /// so there is nothing to narrate turn by turn.
  String navigateNoStepsFallback({required String destination, required double meters}) => _t(
        'I have the route to $destination, ${spokenDistance(meters)} away, but no turn-by-turn '
            'directions for it. Follow the arrow, and ask me any time where to go next.',
        '$destination-এর পথ পেয়েছি, দূরত্ব ${spokenDistance(meters)}, তবে মোড়ে মোড়ে নির্দেশ পাইনি। '
            'তীর অনুসরণ করুন, আর যেকোনো সময় আমাকে জিজ্ঞেস করুন কোন দিকে যেতে হবে।',
      );

  // Module 5 — crowdsourced hazard warnings on an active route.
  //
  // Deliberately worded as somebody's report rather than as fact ("a user
  // reported", "কেউ জানিয়েছে"): a Yellow Flag is exactly one unverified
  // person's word, and telling a blind user something is definitely there
  // when it might not be trains them to distrust every warning the app
  // gives — including the confirmed ones that matter most.

  /// One unconfirmed report on the path ahead. Warns without rerouting.
  String hazardWarningAhead(String hazardLabel) => _t(
        'Heads up — a user reported $hazardLabel on the way. Take care as you approach.',
        'খেয়াল রাখবেন — সামনে $hazardLabel আছে বলে কেউ জানিয়েছে। কাছে গেলে সাবধানে থাকবেন।',
      );

  /// Several people independently reported the same thing — this is the
  /// route being actively steered away from it.
  String hazardConfirmedAvoided(String hazardLabel) => _t(
        'Several people reported $hazardLabel on the direct path, so I have routed you around it.',
        'সরাসরি পথে $hazardLabel আছে বলে কয়েকজন জানিয়েছেন, তাই আমি ঘুরিয়ে অন্য পথে নিয়ে যাচ্ছি।',
      );

  /// No alternative existed, so the user is being walked toward a hazard
  /// that multiple people have confirmed. The most important sentence this
  /// module produces — it never gets softened or skipped.
  String hazardConfirmedUnavoidable(String hazardLabel) => _t(
        'Warning: several people reported $hazardLabel on this path and I could not find a way around it. '
            'Please go slowly, and ask someone nearby for help if you need it.',
        'সতর্কতা: এই পথে $hazardLabel আছে বলে কয়েকজন জানিয়েছেন, আর ঘুরে যাওয়ার কোনো পথ পাইনি। '
            'ধীরে ধীরে যাবেন, দরকার হলে আশেপাশের কাউকে সাহায্য করতে বলবেন।',
      );

  /// Offered after the user has been warned about a structural block —
  /// those never expire on their own (see `hazard_decay.js`), so somebody
  /// walking past a rebuilt ramp is the only thing that clears them.
  String get hazardResolvePrompt => _t(
        'If it is fixed now, say "it is fixed" and I will clear it for everyone.',
        'যদি এখন ঠিক হয়ে গিয়ে থাকে, "ঠিক হয়ে গেছে" বলুন — আমি সবার জন্য সরিয়ে দেব।',
      );
  String get hazardResolvedConfirmation => _t(
        'Thank you — cleared. Other users will not be routed around it any more.',
        'ধন্যবাদ — সরিয়ে দিয়েছি। এখন থেকে আর কাউকে ঘুরিয়ে নেওয়া হবে না।',
      );
  String get hazardResolveNothingToClear => _t(
        "There is no reported hazard on your route to clear right now.",
        'এখন আপনার পথে সরানোর মতো কোনো বিপদের খবর নেই।',
      );

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
