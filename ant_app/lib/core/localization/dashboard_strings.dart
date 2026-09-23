import '../../features/dashboard/models/hazard_report.dart';
import '../config/diagnostics_config.dart';
import '../services/routing_service.dart' show ManeuverKind;
import '../../features/onboarding/models/disability_profile_enums.dart';
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
  // ---- Magic Button (Module 9) ---------------------------------------

  /// Spoken the instant a trigger fires, before anything is sent.
  ///
  /// Said first and said plainly, because the user needs to know the phone
  /// understood them before they decide whether to keep holding it, shout
  /// again, or run.
  String get emergencyActivated =>
      _t('Emergency mode. Sending alerts.', 'জরুরি অবস্থা। সাহায্যের বার্তা পাঠানো হচ্ছে।');

  /// The cancel window's read-back for an accidental trigger.
  /// Introduces the cancel window, and must keep naming both the time and the
  /// word.
  ///
  /// The window was briefly removed here along with dictation's, then put
  /// back: the two cases are not alike. A dictated message has been read back
  /// and is on its way to a human who can make sense of it anyway, so waiting
  /// five seconds on every one is pure cost. An SOS can be raised by accident
  /// — a volume-down hold in a pocket — and there is no undoing a message and
  /// a phone call to somebody's family. The delay is the only thing standing
  /// between a false trigger and that. See open_bugs item 41.
  String emergencyAbout(int contacts, int seconds) => _t(
        'I will message $contacts people and call for help in $seconds seconds. '
        'Say cancel to stop.',
        '$contacts জনকে বার্তা পাঠাব এবং $seconds সেকেন্ডে ফোন করব। থামাতে বলুন বাতিল।',
      );

  String get emergencyCancelled =>
      _t('Emergency cancelled. Nothing was sent.', 'জরুরি অবস্থা বাতিল। কিছু পাঠানো হয়নি।');

  String emergencySent(int reached) => _t(
        reached == 1 ? '1 person has been messaged.' : '$reached people have been messaged.',
        '$reached জনকে বার্তা পাঠানো হয়েছে।',
      );

  /// Said when every message failed.
  ///
  /// Never silently optimistic: a user who believes help is coming and
  /// stops trying to get it themselves is in a worse position than one who
  /// knows the phone could not reach anyone.
  String get emergencyNotSent => _t(
        'I could not send the messages. Try calling someone directly.',
        'বার্তা পাঠাতে পারিনি। সরাসরি কাউকে ফোন করার চেষ্টা করুন।',
      );

  String emergencyCalling(String name) =>
      _t('Calling $name now.', '$name-কে এখন ফোন করছি।');

  String get emergencyNoContacts => _t(
        'You have no emergency contacts saved. Say: add an emergency contact.',
        'আপনার কোনো জরুরি যোগাযোগ সংরক্ষিত নেই। বলুন: জরুরি যোগাযোগ যোগ করো।',
      );

  /// Eight-point compass names, indexed by `SafeHavenFinder.compassIndex`.
  ///
  /// Used only in the offline fallback, where there is no route to follow
  /// and a direction plus a distance is the most that can honestly be
  /// offered. Left/right would be meaningless without knowing which way the
  /// user is facing; a compass bearing does not depend on that.
  List<String> get compassPoints => _t(
        'north, north-east, east, south-east, south, south-west, west, north-west',
        'উত্তর, উত্তর-পূর্ব, পূর্ব, দক্ষিণ-পূর্ব, দক্ষিণ, দক্ষিণ-পশ্চিম, পশ্চিম, উত্তর-পশ্চিম',
      ).split(', ');

  String havenRouting(String label) => _t(
        'I am taking you to $label. Follow my directions.',
        'আমি আপনাকে $label-এ নিয়ে যাচ্ছি। আমার নির্দেশ অনুসরণ করুন।',
      );

  /// The offline answer: no route, but a direction and a distance.
  String havenDirection({required String label, required String compass, required int metres}) => _t(
        '$label is about $metres metres to the $compass.',
        '$label প্রায় $metres মিটার $compass দিকে।',
      );

  /// Said when there is genuinely nowhere to send them.
  ///
  /// Staying put is a real instruction, not a failure message — the
  /// contacts have already been told where they are, and moving makes them
  /// harder to find.
  String get havenStayPut => _t(
        'Stay where you are. I have told your contacts where to find you.',
        'আপনি যেখানে আছেন সেখানেই থাকুন। আপনার পরিচিতদের জানিয়ে দিয়েছি আপনি কোথায় আছেন।',
      );

  /// Spoken instead of dispatching, in a build where live dispatch is off.
  ///
  /// Says plainly that nothing was sent. A rehearsal that sounded identical
  /// to the real thing would be worse than no rehearsal: a tester would
  /// report the feature works, and the first person to find out otherwise
  /// would be someone in trouble.
  String emergencyRehearsal(int contacts) => _t(
        'Practice mode. Nothing was sent. In a real emergency I would message '
        '$contacts people and call for help.',
        'অনুশীলন মোড। কিছু পাঠানো হয়নি। সত্যিকারের বিপদে আমি $contacts জনকে বার্তা '
        'পাঠাতাম এবং সাহায্যের জন্য ফোন করতাম।',
      );

  String get emergencyNoPermission => _t(
        'I need permission to send messages and make calls. Please grant it in settings.',
        'বার্তা পাঠাতে ও ফোন করতে অনুমতি দরকার। সেটিংসে অনুমতি দিন।',
      );

  /// The SOS variant. Names one word, and does not offer to "change it" —
  /// the generic prompt advertised a re-dictation that does not exist in
  /// this flow and that, if taken up, cancelled the emergency outright.
  String cancelWindowPromptEmergency(int seconds) => _t(
        'Sending in $seconds seconds. Say cancel, and only cancel, to stop it.',
        '$seconds সেকেন্ডে পাঠানো হবে। থামাতে হলে শুধু বলুন বাতিল।',
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
  /// Said when a reply is taking long enough that silence would read as
  /// failure.
  ///
  /// A user who cannot see the typing indicator has no way to tell a slow
  /// answer from a command that was never heard — so they say the wake word
  /// again, and report it as unreliable. Measured on device at 20-29 seconds
  /// for an assistant reply; this is what fills that.
  String get chatStillWorking => _t('Still working on that…', 'একটু সময় লাগছে…');

  String get chatAskDestination => _t('Where would you like to go?', 'আপনি কোথায় যেতে চান?');
  // Suggested chips
  /// Was "Route to Work" / "কাজের পথ" — a chip that could only ever mean one
  /// destination, and which did not actually know one (it asked). Now the
  /// single entry point to *anywhere*: it opens the destination sheet, where
  /// a place can be searched for, pinned on the map, typed, or spoken.
  String get chipPath => _t('Go somewhere', 'পথ');

  /// Was "Scan the next bus". The camera is not a bus-only instrument and
  /// labelling it as one hid every other thing it does — reading a sign,
  /// checking the ground, saying what is ahead. This chip now *is* the
  /// camera button, which is why there is no longer one on the input row.
  String get chipCamera => _t('Camera', 'ক্যামেরা');

  /// The destination sheet opened by [chipPath].
  String get pathSheetTitle => _t('Where do you want to go?', 'কোথায় যেতে চান?');
  String get pathSearchLabel => _t('Search for a place', 'জায়গা খুঁজুন');
  String get pathSearchHint => _t('Type a place name', 'জায়গার নাম লিখুন');
  String get pathPinOnMap => _t('Pin it on the map', 'ম্যাপে পিন করুন');
  String get pathPinOnMapHint =>
      _t('Open the map and tap where you want to go', 'ম্যাপ খুলে যেখানে যেতে চান সেখানে চাপুন');
  String get pathSpeak => _t('Say it out loud', 'বলে দিন');
  String get pathSpeakHint => _t('Tap, then say the place name', 'চাপুন, তারপর জায়গার নাম বলুন');
  String get settingsAddSavedPlace => _t('Add a place', 'জায়গা যোগ করুন');
  String get settingsSavedPlaceLabelField => _t('Call it', 'যে নামে ডাকবেন');
  String get settingsSavedPlaceLabelHint => _t('e.g. work, my sister\'s', 'যেমন অফিস, বোনের বাসা');
  String get settingsSavedPlaceAddressField => _t('Where is it', 'কোথায়');
  String get settingsSavedPlaceSaveButton => _t('Save place', 'সেভ করুন');
  String get settingsSavedPlaceNeedsBoth =>
      _t('It needs a name and a place.', 'একটা নাম আর একটা জায়গা — দুটোই লাগবে।');

  String get pathSearchNoResults =>
      _t('I could not find that place.', 'ওই জায়গাটা খুঁজে পেলাম না।');

  String get pathPinConfirm => _t('Go here', 'এখানে যান');
  /// Said back after a pin, when the reverse geocode produced nothing.
  /// Deliberately not coordinates: "23.81, 90.41" confirms nothing to
  /// somebody checking they pinned the right place.
  String get pathPinnedFallback =>
      _t('the place you picked on the map', 'ম্যাপে বেছে নেওয়া জায়গা');

  /// The transcript entry for a pin, so the conversation records what was
  /// asked for even though nothing was said or typed.
  String pathPinnedRequest(String place) =>
      _t('Take me to $place', '$place-এ নিয়ে চলুন');

  String get pathPinUnroutable => _t(
      "I couldn't find a walking route to that point. Try pinning somewhere closer to a road.",
      'ওই জায়গায় হেঁটে যাওয়ার পথ পেলাম না। রাস্তার কাছাকাছি কোথাও পিন করে দেখুন।');

  String get pathPinInstruction =>
      _t('Tap the map to choose a destination', 'গন্তব্য বেছে নিতে ম্যাপে চাপুন');
  /// Short enough to sit in a one-third-width cell without wrapping to five
  /// lines. The full sentence is still what a screen reader announces — see
  /// [chipShowScreenSemantics] and `SuggestedChip.semanticsLabelFor`.
  String get chipShowScreen => _t('Show my screen', 'স্ক্রিন দেখান');
  String get chipShowScreenSemantics =>
      _t('Show my screen to a passer-by', 'কাউকে আমার স্ক্রিন দেখান');
  String get chipReportHazard => _t('Report a hazard', 'বিপদ জানান');

  // Map
  String get mapUnavailableTitle => _t('Map unavailable', 'মানচিত্র নেই');
  String get mapUnavailableSubtitle => _t('A Google Maps API key hasn\'t been configured yet.', 'মানচিত্র এখনো চালু করা হয়নি।');
  String get mapLiveViewLabel => _t('Live map view', 'সরাসরি মানচিত্র');
  /// The draggable divider between the chat and the map.
  /// Hands the camera back to following the user after they have panned.
  String get mapRecentreSemantics =>
      _t('Recentre the map on me', 'মানচিত্র আমার উপর ফিরিয়ে আনুন');

  String get mapResizeSemantics =>
      _t('Resize the map. Swipe up or down to adjust.', 'মানচিত্রের আকার বদলান। উপরে বা নিচে সোয়াইপ করুন।');

  String get mapExpandSemantics => _t('Expand map to full screen', 'মানচিত্র পুরো স্ক্রিনে দেখুন');
  String get mapCollapseSemantics => _t('Shrink map back to split view', 'মানচিত্র আবার ভাগ করা স্ক্রিনে আনুন');

  /// Screen-reader label for the route banner, and the one sentence that
  /// has to carry the whole route for someone who cannot look at the line.
  ///
  /// Reported: "that stupid big arrow is confusing, i wanna see the route
  /// lines as well like in google maps, as well as info about how far to go
  /// in which direction." The arrow was a static placeholder Module 2
  /// shipped before turn-by-turn existed; this is what replaced it.
  String mapRouteStatus({
    required bool safe,
    required bool wasRerouted,
    required double distanceMeters,
    String destination = '',
    String via = '',
  }) {
    final remaining = spokenRouteLength(distanceMeters);
    final heading = destination.isEmpty
        ? _t('Route active', 'পথ চালু আছে')
        : _t('Heading to $destination', '$destination-এর দিকে যাচ্ছেন');
    final viaClause = via.isEmpty ? '' : _t(' via $via', ' $via দিয়ে');
    final base = _t('$heading$viaClause — $remaining to go.', '$heading$viaClause — বাকি আছে $remaining।');
    if (!safe) {
      return _t(
        '$base This is the safest route found, but it still passes a risky area.',
        '$base এটাই সবচেয়ে নিরাপদ পথ, তবে কিছুটা ঝুঁকিপূর্ণ এলাকা দিয়ে যায়।',
      );
    }
    if (wasRerouted) {
      return _t(
        '$base Route adjusted to avoid an unsafe area.',
        '$base অনিরাপদ এলাকা এড়াতে পথ পাল্টানো হয়েছে।',
      );
    }
    return base;
  }

  /// The next manoeuvre, written for the eye rather than the ear.
  ///
  /// Distance first for speech ([navigateTurnAhead]) because speech is
  /// linear and the listener needs to know how urgent it is before the
  /// instruction lands. On a screen both are visible at once, so the
  /// instruction leads and the distance sits beside it as its own large
  /// number — which is the part a low-vision user is squinting at.
  String mapManeuverLine({required ManeuverKind kind, String streetName = ''}) {
    final direction = maneuverDirection(kind);
    final sentence = streetName.isEmpty
        ? direction
        : _t('$direction onto $streetName', '$streetName-এ $direction');
    return sentence.isEmpty ? sentence : sentence[0].toUpperCase() + sentence.substring(1);
  }

  /// The distance to the next manoeuvre, as a short label beside its icon.
  ///
  /// Never "a few steps": this has to fit a fixed slot and be readable at a
  /// glance. Rounded to the same bands [spokenDistance] uses — 10 m close
  /// in, 50 m further out — so what is on the screen and what was just said
  /// out loud cannot disagree, which for a low-vision user reading the
  /// screen *and* hearing the voice is worse than either alone.
  String mapCompactDistance(double meters) {
    if (meters >= 1000) return _compactKm(meters);
    final rounded = meters < 100 ? (meters / 10).round() * 10 : (meters / 50).round() * 50;
    return _bn ? '$rounded মি' : '$rounded m';
  }

  /// "1.2 km left" under the manoeuvre — the total, not the next turn.
  ///
  /// Rounded to 10 m throughout rather than to the announcement bands: this
  /// number is never spoken, so it has nothing to stay in step with, and
  /// showing "950 m left" for 940 m is a rounding nobody asked for.
  String mapRemainingLabel(double meters) {
    final value = meters >= 1000 ? _compactKm(meters) : '${(meters / 10).round() * 10}${_bn ? ' মি' : ' m'}';
    return _t('$value left', 'বাকি $value');
  }

  String _compactKm(double meters) {
    final km = (meters / 100).round() / 10;
    return _bn ? '$km কিমি' : '$km km';
  }

  /// Shown in the banner before the first GPS fix arrives, when the route
  /// exists but nothing has been walked yet.
  String mapHeadingTo(String destination) =>
      _t('Heading to $destination', '$destination-এর দিকে');

  /// Shown in place of the manoeuvre when the user has left the route.
  String get mapOffRoute => _t('Off the route', 'পথ থেকে সরে গেছেন');

  /// Shown once the destination is reached.
  String get mapArrived => _t('Arrived', 'পৌঁছে গেছেন');

  /// The destination pin's screen-reader label.
  String mapDestinationMarker(String destination) =>
      _t('Destination: $destination', 'গন্তব্য: $destination');

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

  /// Asked when the "name" that came back was the request restated —
  /// "a new place I go to frequently" is not what anyone calls anywhere.
  /// Said when the save conversation has asked as much as it usefully can.
  ///
  /// Ends with something the user can act on, not an apology — the same rule
  /// `clarifyGaveUp` follows.
  String get savedPlaceGaveUp => _t(
        "I could not get that saved. When you are standing at the place, say "
            '"save this place" and give it a short name — that is the way that always works.',
        'জায়গাটা সেভ করতে পারলাম না। ওখানে পৌঁছে "এই জায়গাটা সেভ করো" বলে একটা ছোট নাম দিন — '
            'এভাবে সব সময় কাজ হয়।',
      );

  String get savedPlaceNeedsName => _t(
        'What should I call that place? Give me a short name — "work", "the clinic" — '
            'and tell me the address if you are not standing there now.',
        'জায়গাটাকে কী নামে ডাকব? ছোট একটা নাম বলুন — "অফিস", "ক্লিনিক" — '
            'আর এখন সেখানে না থাকলে ঠিকানাটাও বলুন।',
      );

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

  /// A whole route's length, as a person would say it.
  ///
  /// Distinct from [spokenDistance], which is built for the *next* few
  /// metres and answers "a few steps" below 20 m. A total is a different
  /// question — "how far is this walk" — and wants a kilometre once it is
  /// past one.
  String spokenRouteLength(double meters) {
    if (meters >= 1000) {
      final km = (meters / 100).round() / 10;
      return _bn ? '$km কিলোমিটার' : '$km km';
    }
    final rounded = (meters / 10).round() * 10;
    return _bn ? '$rounded মিটার' : '$rounded metres';
  }

  /// How long the walk takes, rounded to whole minutes.
  ///
  /// Never seconds: nobody paces a walk to the second, and "about" is the
  /// honest word for an estimate built from an average walking speed that
  /// this app's users may not match (see `RoutingConfig`).
  String spokenWalkDuration(double seconds) {
    final minutes = (seconds / 60).round();
    if (minutes < 1) return _t('under a minute', 'এক মিনিটেরও কম');
    if (minutes == 1) return _t('about a minute', 'প্রায় এক মিনিট');
    return _t('about $minutes minutes', 'প্রায় $minutes মিনিট');
  }

  /// The one-line description of a route the assistant is about to walk the
  /// user along: which way, how far, how long.
  ///
  /// Reported directly — after "take me to Labaid" the assistant said only
  /// that the safest route passed a risky area, and the user wanted to know
  /// *which* way it was taking them. A route the user cannot see is a route
  /// they cannot object to, so it has to be said.
  ///
  /// [via] is omitted rather than faked when no step on the route carries a
  /// name, which is common in Dhaka.
  String routeSummary({required String via, required double distanceMeters, required double durationSeconds}) {
    final length = spokenRouteLength(distanceMeters);
    final duration = spokenWalkDuration(durationSeconds);
    if (via.isEmpty) return _t('$length, $duration.', '$length, $duration।');
    return _t('Via $via — $length, $duration.', '$via দিয়ে — $length, $duration।');
  }

  /// Said when the user asks for a different route and there is one.
  String routeAlternativeTaken({required String via, required double distanceMeters, required double durationSeconds}) {
    final summary = routeSummary(via: via, distanceMeters: distanceMeters, durationSeconds: durationSeconds);
    return _t('Here is another way. $summary', 'এই যে আরেকটা পথ। $summary');
  }

  /// Said when they ask and there is not.
  String get routeNoAlternatives => _t(
        "That is the only walking route I can find to there. Say \"stop\" if you would rather not go.",
        'ওখানে যাওয়ার জন্য হেঁটে যাওয়ার এই একটাই পথ পাচ্ছি। যেতে না চাইলে "থামো" বলুন।',
      );

  /// Said when they ask for a different route without being on one.
  /// Said when a trip is actually cancelled.
  String get routeCancelled =>
      _t('Trip cancelled. Tell me where to go when you are ready.',
          'যাত্রা বাতিল করা হলো। যেতে চাইলে বলবেন।');

  /// Said when there is nothing to cancel.
  String get routeNothingToCancel =>
      _t('You are not on a trip right now.', 'এখন আপনি কোনো যাত্রায় নেই।');

  String get routeNoActiveRoute => _t(
        'You are not following a route right now. Tell me where you want to go and I will find one.',
        'এখন আপনি কোনো পথে নেই। কোথায় যেতে চান বলুন, আমি পথ খুঁজে দিচ্ছি।',
      );

  /// How many other routes are still on the shelf, so the user knows
  /// whether asking again will get them anywhere.
  String routeAlternativesRemaining(int count) => count == 0
      ? _t('That was the last one I had.', 'এটাই ছিল আমার কাছে থাকা শেষ পথ।')
      : _t('I have $count more if you want another.', 'আরও $count টা আছে, চাইলে বলুন।');

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
  ///
  /// Uses [spokenRouteLength], not [spokenDistance] — the latter rounds to
  /// 50 m bands for the *next* manoeuvre and turned a whole journey into
  /// "1200 metres in total", which is both harder to hear and less useful
  /// than "1.2 km".
  String navigateStarted({required String destination, required double totalMeters}) => _t(
        'Starting navigation to $destination, ${spokenRouteLength(totalMeters)} in total. '
            'I will tell you each turn as it comes.',
        '$destination-এর দিকে যাত্রা শুরু করছি, মোট ${spokenRouteLength(totalMeters)}। '
            'প্রতিটি মোড় আসার আগে আমি বলে দেব।',
      );

  /// The same moment, when the caller has just described the route itself.
  ///
  /// The chat reply already said where, which way and how far — repeating
  /// the destination and the total straight afterwards is the "saying too
  /// much" failure `NavigationNarrator` is built to avoid, and it lands
  /// before the user has taken a single step.
  String get navigateStartedBrief =>
      _t('I will tell you each turn as it comes.', 'প্রতিটি মোড় আসার আগে আমি বলে দেব।');

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

  /// Spoken once as the sheet opens, **before** the microphone is opened.
  ///
  /// It used to open the mic immediately and say nothing, so the user heard
  /// a listening buzz with no idea what they were meant to say into it. Says
  /// what the screen is for and what to do with it, in that order, because
  /// somebody who cannot see the sheet has no other way to find out.
  String get passerbyPickerIntroSpoken => _t(
        'This shows a message full-screen so someone nearby can read it. '
            'Say what you need, then say "show it".',
        'এটি আপনার বার্তা বড় করে স্ক্রিনে দেখাবে যাতে কাছের কেউ পড়তে পারে। '
            'যা বলতে চান বলুন, তারপর "দেখাও" বলুন।',
      );

  /// Said when "show it" arrives with nothing dictated yet.
  ///
  /// The old loop simply re-asked the same question, forever: the submit
  /// phrase was recognized, there was nothing to submit, and the identical
  /// prompt played again. Reported from the device as exactly that — "it
  /// loops on, telling me it got it and i should say show it".
  String get passerbyPickerNothingToShowSpoken => _t(
        'I do not have a message yet. Tell me what to say first, then say "show it".',
        'এখনো কোনো বার্তা পাইনি। আগে কী বলতে চান সেটা বলুন, তারপর "দেখাও" বলুন।',
      );

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

  /// The report is written and will reach the map — the *confirmation* is
  /// what has not arrived. Deliberately not phrased as a failure: Firestore
  /// has already applied the write locally and will sync it, so telling the
  /// user it did not work would be false, and telling them nothing at all is
  /// what the hub used to do.
  String get crowdsourceSubmitQueued =>
      _t('Saved — it will reach the map as soon as you are back online.',
          'সংরক্ষণ হয়েছে — ইন্টারনেট এলে মানচিত্রে যোগ হবে।');
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
  // Saved places, listed so they can be seen and removed.
  //
  // They were only ever reachable by voice — "take me to X", "forget X" —
  // so there was no way to notice that "hospital" had been saved as the
  // wrong hospital until you were walked to it, and no way to clear a junk
  // entry that a half-understood command had created.
  String get settingsSavedPlacesSection => _t('Your saved places', 'আপনার সেভ করা জায়গা');
  String get settingsSavedPlacesEmpty => _t(
        'Nothing saved yet. Say "save this place" when you are somewhere you go often.',
        'এখনো কিছু সেভ করা নেই। যেখানে প্রায়ই যান সেখানে গিয়ে "এই জায়গাটা সেভ করো" বলুন।',
      );
  String settingsSavedPlaceRemoveSemantics(String label) =>
      _t('Remove $label from your saved places', '$label সেভ করা জায়গা থেকে সরান');
  String get settingsSavedPlaceNoAddress => _t('No address saved', 'কোনো ঠিকানা সেভ নেই');

  String get settingsWakeWordSection => _t('"Hey ANT" voice trigger', '"Hey ANT" ভয়েস ট্রিগার');
  String get settingsWakeWordSwitch =>
      _t('Listen for "Hey ANT" so I can talk without tapping the mic', '"Hey ANT" বললে মাইকে না চেপেই কথা বলা যাবে');
  // ---- Wake-word sensitivity dial -----------------------------------------
  //
  // Testers reported that "Hey Jarvis" has to be said softly, gently, and
  // with a pause between the two words. That is a statement about where the
  // detection line sits for their voices and their rooms, and it could not be
  // answered by a build-time constant — every guess cost a new APK. These
  // strings front the dial that moves it, and the live score that makes
  // moving it something other than guesswork.
  String get settingsWakeWordSensitivitySection =>
      _t('"Hey ANT" sensitivity', '"Hey ANT" সংবেদনশীলতা');

  String get settingsWakeWordSensitivityHint => _t(
        'Higher means it triggers more easily, but is likelier to fire on its own. '
            'Say "Hey ANT" and watch the bar below — set the marker just under where your voice reaches.',
        'বেশি মানে সহজে চালু হবে, তবে নিজে থেকেও চালু হওয়ার ঝুঁকি বাড়ে। '
            '"Hey ANT" বলুন আর নিচের বারটি দেখুন — আপনার কণ্ঠ যতটা পৌঁছায় তার একটু নিচে দাগটি রাখুন।',
      );

  String settingsWakeWordSensitivityValue(int percent) =>
      _t('Sensitivity $percent%', 'সংবেদনশীলতা $percent%');

  /// The raw threshold, shown alongside the friendly percentage.
  ///
  /// Kept visible on purpose while the wake word is still being tuned: the
  /// numbers in the device logs and in `wake_word_threshold_test.dart` are
  /// thresholds, not percentages, and a tester reporting "mine works at 0.22"
  /// is worth far more than one reporting "about three quarters along".
  String settingsWakeWordThresholdValue(String threshold) =>
      _t('Triggers at $threshold', 'চালু হয় $threshold-এ');

  String settingsWakeWordLiveScore(String score) => _t('Heard just now: $score', 'এইমাত্র শোনা: $score');

  String get settingsWakeWordMeterSemantics =>
      _t('Live "Hey ANT" match strength', 'সরাসরি "Hey ANT" মিলের মাত্রা');

  String get settingsWakeWordListeningOff => _t(
        'Turn the "Hey ANT" trigger on above to test your voice against this.',
        'কণ্ঠ পরীক্ষা করতে উপরে "Hey ANT" ট্রিগার চালু করুন।',
      );

  String get settingsWakeWordReset => _t('Reset to default', 'ডিফল্টে ফিরুন');

  // ---- Caretaker messages arriving (Module 8, receiving half) -------------
  String caretakerMemoHeard(String text) =>
      _t('Message from your caretaker: $text', 'আপনার সহায়কের বার্তা: $text');

  String get caretakerVoiceMemoHeard =>
      _t('A voice message from your caretaker.', 'আপনার সহায়ক একটি ভয়েস বার্তা পাঠিয়েছেন।');

  /// Said when the clip itself cannot be played, so the user is not left
  /// wondering whether anything arrived.
  String get caretakerVoiceMemoUnplayable => _t(
        'A voice message from your caretaker arrived, but it could not be played.',
        'আপনার সহায়কের ভয়েস বার্তা এসেছে, কিন্তু বাজানো যায়নি।',
      );

  String get caretakerSnapshotRequested => _t(
        'Your caretaker asked to see a photo of what is around you.',
        'আপনার সহায়ক আপনার আশপাশের একটি ছবি দেখতে চেয়েছেন।',
      );

  /// Module 6 is not built, so the request can be delivered and not answered.
  /// Saying so is the point: a request that silently does nothing is what the
  /// whole of item 28 felt like.
  /// A picture the caretaker chose to send.
  ///
  /// The user is very often blind, so the arrival is announced and the
  /// picture is described by the vision tier rather than simply appearing —
  /// a photo that lands silently on a screen nobody can see is a message
  /// that was not delivered.
  String get caretakerPhotoArrived =>
      _t('Your caretaker sent a photo. Let me look at it.',
          'আপনার দেখাশোনাকারী একটা ছবি পাঠিয়েছেন। দেখে নিই।');

  String get caretakerPhotoUnreadable => _t(
        "Your caretaker sent a photo, but I couldn't make it out.",
        'আপনার দেখাশোনাকারী একটা ছবি পাঠিয়েছেন, কিন্তু আমি বুঝতে পারিনি।',
      );

  String get photoSentToCaretaker =>
      _t('Photo sent to your caretaker.', 'দেখাশোনাকারীকে ছবি পাঠিয়ে দিয়েছি।');

  /// Voicemail-style replay of caretaker voice memos.
  ///
  /// The position is said before the clip plays. For somebody who cannot see
  /// a list, "the second of four" is the only thing that makes stepping
  /// through them navigable at all.
  String voiceMemoReplaying(int index, int total) => total == 1
      ? _t('Playing your caretaker\'s message.', 'আপনার দেখাশোনাকারীর বার্তা শোনাচ্ছি।')
      : _t('Message $index of $total.', '$total-টির মধ্যে $index নম্বর বার্তা।');

  String get voiceMemoNoneToReplay => _t(
        'Your caretaker has not sent a voice message yet.',
        'আপনার দেখাশোনাকারী এখনো কোনো ভয়েস বার্তা পাঠাননি।',
      );

  /// Clamped, not wrapped — silently restarting at the other end sounds like
  /// the same message arriving twice.
  String get voiceMemoNoOlder =>
      _t('That is the oldest one.', 'এটাই সবচেয়ে পুরোনো।');

  String get voiceMemoNoNewer =>
      _t('That is the newest one.', 'এটাই সবচেয়ে নতুন।');

  /// A landmark coming up beside the route — see `NavigationNarrator`.
  ///
  /// Said plainly and once. A bus stop is information ("you could board
  /// here"); a crossing is a caution ("the road is about to be in front of
  /// you"), so the two do not share a sentence shape.
  String landmarkBusStop(String name) => name.isEmpty
      ? _t('Bus stop just ahead.', 'সামনেই বাস স্ট্যান্ড।')
      : _t('$name bus stop just ahead.', '$name বাস স্ট্যান্ড সামনেই।');

  String get landmarkCrossing =>
      _t('Crossing coming up.', 'সামনে রাস্তা পারাপার।');

  /// Weather, appended to a route when it changes whether to set off.
  ///
  /// Short, and never the whole reply — the user asked for a route, and the
  /// route is still the answer. Rain in Dhaka is not a comfort question: a
  /// flooded footpath is standing water of unknown depth over an open drain,
  /// which is the exact hazard a cane cannot find in time.
  String weatherRainingNow() => _t(
        "It's raining — footpaths flood fast here, so take care.",
        'বৃষ্টি হচ্ছে — এখানে ফুটপাত দ্রুত ডুবে যায়, সাবধানে যাবেন।',
      );

  String weatherRainSoon(int percent) => _t(
        'Rain looks likely within the hour — about $percent percent.',
        'এক ঘণ্টার মধ্যে বৃষ্টির সম্ভাবনা — প্রায় $percent শতাংশ।',
      );

  String get weatherThunderstorm => _t(
        "There's a thunderstorm about. Going out now is not a good idea.",
        'বজ্রঝড় হচ্ছে। এখন বাইরে যাওয়া ঠিক হবে না।',
      );

  String weatherVeryHot(int feelsLike) => _t(
        'It feels like $feelsLike degrees out — carry water and rest in the shade.',
        'বাইরে $feelsLike ডিগ্রির মতো লাগছে — পানি নেবেন, ছায়ায় বিশ্রাম নেবেন।',
      );

  /// Prefixed to a reply that carries the camera frame it was based on, for
  /// a screen-reader user who cannot see the picture is there.
  String get chatAnsweredFromAPhoto => _t('From a photo.', 'ছবি থেকে।');

  /// Said once, when ambient path-watching stops because the battery is low.
  ///
  /// The scanner has always stopped below `ambientMinBatteryPercent` and has
  /// always done it silently, which is the worst way to withdraw a safety
  /// feature from somebody who cannot see that it is gone: they keep walking
  /// as though the phone is still watching the ground. Said once per
  /// discharge, not per scan — a warning repeated every thirty seconds is
  /// one the user turns the app off to escape.
  String batteryLowScanningStopped(int percent) => _t(
        'Battery is at $percent percent, so I have stopped watching the path to save power. '
        'You can still ask me to look at any time.',
        'ব্যাটারি $percent শতাংশ, তাই পথ দেখা বন্ধ করলাম যাতে চার্জ থাকে। '
        'আপনি চাইলে যেকোনো সময় দেখতে বলতে পারেন।',
      );

  /// Said when it starts again, so the user knows the cover is back.
  String get batteryRecoveredScanningResumed => _t(
        'Charge is back up — I am watching the path again.',
        'চার্জ ফিরে এসেছে — আবার পথ দেখছি।',
      );

  /// Said while the camera is actually taking the guardian's picture.
  String get caretakerSnapshotTaking =>
      _t('Taking a photo for them now.', 'এখনই তাদের জন্য ছবি তুলছি।');

  /// Said once it has gone.
  String get caretakerSnapshotSent =>
      _t('Sent to your caretaker.', 'আপনার দেখাশোনাকারীকে পাঠিয়ে দিয়েছি।');

  /// The camera ran and could not see. Distinct from not having a camera at
  /// all, which is what this used to say.
  String get caretakerSnapshotFailed => _t(
        "I couldn't get a photo just now — I told them so.",
        'এখন ছবি তুলতে পারিনি — তাদের জানিয়ে দিয়েছি।',
      );

  /// Asked when snapshot consent is "ask me each time".
  String get caretakerSnapshotAsk => _t(
        'Your caretaker asked for a photo of what is in front of you. Shall I send one?',
        'আপনার দেখাশোনাকারী আপনার সামনের একটা ছবি চেয়েছেন। পাঠাব?',
      );

  String get caretakerSnapshotNotAvailable => _t(
        'Sending photos is not available in this build yet, so nothing was sent.',
        'এই সংস্করণে ছবি পাঠানো এখনও চালু হয়নি, তাই কিছু পাঠানো হয়নি।',
      );

  String get caretakerSnapshotDeclined => _t(
        'You have photo sharing switched off, so nothing was sent.',
        'আপনি ছবি শেয়ার বন্ধ রেখেছেন, তাই কিছু পাঠানো হয়নি।',
      );

  // ---- Haptic strength (Module 7 step 3.1) --------------------------------
  // ---- Remembering things (item 56) -----------------------------------------
  /// Said out loud on purpose. A user who cannot see a screen has no other
  /// way to know something about them was written down and kept, and being
  /// told is the difference between a feature and a surprise.
  String rememberedNote(String note) =>
      _t("I'll remember that: $note", 'এটা মনে রাখব: $note');
  String get forgotNote => _t("Forgotten — I won't bring that up again.",
      'ভুলে গেছি — এটা আর বলব না।');
  String get forgotNoteUnknown =>
      _t("I don't have anything like that written down.", 'ওরকম কিছু আমার কাছে লেখা নেই।');

  // ---- Asking for the map (item 51) -----------------------------------------
  String get mapOpened => _t('Showing the map.', 'ম্যাপ দেখাচ্ছি।');
  String get mapClosed => _t('Hiding the map.', 'ম্যাপ লুকিয়ে ফেলছি।');

  // ---- Alerting the caretaker (item 57) -------------------------------------
  String get alertCaretakerSent => _t(
        "I've let your caretaker know, and sent them where you are.",
        'আপনার দেখাশোনাকারীকে জানিয়ে দিয়েছি, আর আপনি কোথায় আছেন তাও পাঠিয়েছি।',
      );
  /// Says what to do instead, rather than only that it failed. Someone
  /// standing in the street needs the next step, not a status code.
  String get alertCaretakerNotPaired => _t(
        "You don't have a caretaker paired yet, so there's nobody to tell. "
            'Say "pair with my caretaker" and I\'ll walk you through it.',
        'আপনার সাথে এখনো কোনো দেখাশোনাকারী যুক্ত নেই, তাই জানানোর কেউ নেই। '
            '"দেখাশোনাকারী যুক্ত করো" বলুন, আমি দেখিয়ে দিচ্ছি।',
      );
  String get alertCaretakerFailed => _t(
        "I couldn't reach your caretaker just now. If this is urgent, hold the Magic Button.",
        'এখন আপনার দেখাশোনাকারীর কাছে পৌঁছাতে পারিনি। জরুরি হলে ম্যাজিক বাটন চেপে ধরুন।',
      );

  // ---- Sending to the caretaker ---------------------------------------------
  String caretakerMessageSent(String message) =>
      _t('Sent to your caretaker: "$message"', 'আপনার দেখাশোনাকারীকে পাঠিয়েছি: "$message"');
  String get caretakerMessageEmpty => _t(
        "What would you like me to tell them?",
        'তাঁকে কী বলতে চান?',
      );
  String get caretakerMessageFailed => _t(
        "I couldn't send that just now. If it's urgent, hold the Magic Button.",
        'এখন পাঠাতে পারিনি। জরুরি হলে ম্যাজিক বাটন চেপে ধরুন।',
      );

  String get chipVoiceMemo => _t('Voice message', 'ভয়েস বার্তা');

  // ---- Voice memo to the caretaker ------------------------------------------
  /// Spoken before recording starts, so somebody who cannot see the screen
  /// knows the microphone is open and roughly how long they have.
  String get voiceMemoIntro => _t(
        'Recording a voice message for your caretaker. Speak after the tone, and say "send" when you are done.',
        'আপনার দেখাশোনাকারীর জন্য ভয়েস বার্তা রেকর্ড করছি। শব্দের পরে বলুন, শেষ হলে "পাঠাও" বলুন।',
      );
  String get voiceMemoRecording => _t('Recording…', 'রেকর্ড হচ্ছে…');
  String voiceMemoSent(int seconds) => _t(
        'Sent your caretaker a $seconds second voice message.',
        'আপনার দেখাশোনাকারীকে $seconds সেকেন্ডের ভয়েস বার্তা পাঠিয়েছি।',
      );
  String get voiceMemoTooShort => _t(
        "I didn't catch anything, so nothing was sent. Try again when you're ready.",
        'কিছু শুনতে পাইনি, তাই কিছু পাঠানো হয়নি। প্রস্তুত হলে আবার চেষ্টা করুন।',
      );
  String get voiceMemoCancelled => _t('Cancelled — nothing was sent.', 'বাতিল করা হয়েছে — কিছু পাঠানো হয়নি।');
  String get voiceMemoNoMic => _t(
        'I need permission to use the microphone before I can record a message.',
        'বার্তা রেকর্ড করতে মাইক্রোফোনের অনুমতি দরকার।',
      );
  String get voiceMemoSendButton => _t('Send', 'পাঠাও');
  String get voiceMemoCancelButton => _t('Cancel', 'বাতিল');

  // ---- Where am I (item 48) -------------------------------------------------
  String locationHere(String place) =>
      _t("You're near $place.", 'আপনি $place এর কাছে আছেন।');
  String get locationUnknown => _t(
        "I can't tell where you are right now — please check that location access is enabled.",
        'আপনার অবস্থান জানতে পারছি না। লোকেশন চালু আছে কিনা দেখুন।',
      );
  /// The fix arrived; naming it did not. Worth distinguishing out loud from
  /// [locationUnknown] — "I know where you are, I just can't name the road"
  /// is a different thing to be told than "I have no idea where you are".
  String get locationUnnamed => _t(
        "I know where you are, but I couldn't find a name for this spot.",
        'আপনি কোথায় আছেন জানি, তবে এই জায়গাটার নাম খুঁজে পেলাম না।',
      );

  // ---- Diagnostics ---------------------------------------------------------
  String get settingsDiagnosticsSection => _t('Send a report to the developers', 'ডেভেলপারদের রিপোর্ট পাঠান');
  /// Two versions, because the app must not describe a build it is not.
  ///
  /// A tester build keeps what was actually said (see `DiagnosticsConfig`),
  /// and the person pressing this button cannot read the file to discover
  /// that for themselves. Leaving the redaction promise in place on a raw
  /// build would be worse than never having made it.
  String get settingsDiagnosticsHint => DiagnosticsConfig.logRawTranscripts
      ? _t(
          'Sends what the app did during this session, so a problem you hit can be found. '
              'In this test version it includes what you actually said, and any names, numbers '
              'and locations that came up. Only send it to the ANT team.',
          'এই সেশনে অ্যাপ কী করেছে তা পাঠানো হয়, যাতে আপনার সমস্যা খুঁজে বের করা যায়। '
              'এই টেস্ট সংস্করণে আপনি যা বলেছেন, এবং যেসব নাম, নম্বর ও অবস্থান এসেছে, তাও এতে থাকে। '
              'শুধু ANT টিমকেই পাঠাবেন।',
        )
      : _t(
          'Sends what the app did during this session, so a problem you hit can be found. '
              'What you said, names, numbers and your location are replaced with their shape first — '
              'never the actual words.',
          'এই সেশনে অ্যাপ কী করেছে তা পাঠানো হয়, যাতে আপনার সমস্যা খুঁজে বের করা যায়। '
              'আপনি যা বলেছেন, নাম, নম্বর ও আপনার অবস্থান — সবই আগে ঢেকে দেওয়া হয়, আসল কথা কখনো যায় না।',
        );
  String get settingsDiagnosticsButton => _t('Send report', 'রিপোর্ট পাঠান');
  String settingsDiagnosticsReady(int lines) =>
      _t('$lines lines of this session are ready to send.', 'এই সেশনের $lines লাইন পাঠানোর জন্য প্রস্তুত।');
  String settingsDiagnosticsRecovered(int lines) => _t(
        'Your previous session was saved too — $lines more lines will be included.',
        'আপনার আগের সেশনও রাখা হয়েছে — আরও $lines লাইন এর সাথে যাবে।',
      );
  String settingsDiagnosticsFailed(String error) =>
      _t('Could not build the report: $error', 'রিপোর্ট তৈরি করা যায়নি: $error');

  String get settingsHapticsSection => _t('Vibration strength', 'কম্পনের মাত্রা');
  String get settingsHapticsHint => _t(
        'How strongly the phone buzzes for turns, arrivals and hazards. Tap a level to feel it.',
        'মোড়, পৌঁছানো ও বিপদের জন্য ফোন কতটা জোরে কাঁপবে। অনুভব করতে একটি মাত্রায় চাপ দিন।',
      );
  String hapticIntensityLabel(HapticIntensity level) => switch (level) {
        HapticIntensity.high => _t('Strong', 'জোরালো'),
        HapticIntensity.medium => _t('Medium', 'মাঝারি'),
        HapticIntensity.low => _t('Gentle', 'মৃদু'),
      };

  String get settingsOptionNarrationSection =>
      _t('Reading choices out', 'পছন্দ পড়ে শোনানো');
  String get settingsOptionNarrationSwitch => _t(
        'Read every question\'s choices out before listening. Off, they are read only when you say "options".',
        'শোনার আগে প্রতিটি প্রশ্নের পছন্দগুলো পড়ে শোনাও। বন্ধ থাকলে "বিকল্প" বললে তবেই পড়া হবে।',
      );

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
  /// Map visibility toggle. The map is off by default: this app is built
  /// for users who cannot see it, so it starts out of the way and the chat
  /// gets the whole screen until someone asks for it.
  String get mapShowSemantics => _t('Show map', 'ম্যাপ দেখান');
  String get mapHideSemantics => _t('Hide map', 'ম্যাপ লুকান');

  /// Redo-onboarding section. Exists because testers who reached the
  /// dashboard had no way back into onboarding except reinstalling the app —
  /// which for a testing round means losing the round, not just the setup.
  String get settingsRedoOnboardingSection => _t('Setup', 'সেটআপ');
  String get settingsRedoOnboardingButton =>
      _t('Go through setup again', 'আবার সেটআপ করুন');
  String get settingsRedoOnboardingExplain => _t(
        'Takes you back to the first setup question. Your saved places and '
        'contacts are kept.',
        'আপনাকে প্রথম সেটআপ প্রশ্নে ফিরিয়ে নেবে। আপনার সেভ করা জায়গা ও '
        'যোগাযোগগুলো থাকবে।',
      );
  String get settingsRedoOnboardingConfirm =>
      _t('Go through setup again?', 'আবার সেটআপ করবেন?');
  String get settingsRedoOnboardingCancel => _t('Cancel', 'বাতিল');

  String get settingsFooterNote => _t('Changes here save immediately.', 'এখানে যা পাল্টাবেন সাথে সাথে সেভ হবে।');

  String languageLabel(AppLanguage language) =>
      language == AppLanguage.bangla ? _t('Bangla', 'বাংলা') : _t('English', 'ইংরেজি');

  // ---- Module 6, the Snapshot Vision Engine --------------------------------
  //
  // Wording rule for this whole block, and it is a safety rule rather than a
  // style one: **"I could not see" and "there is nothing there" must never
  // sound alike.** A blind user who hears a confident all-clear from a scan
  // that never actually ran will step into the road. Every failure string
  // below names the failure.

  /// Spoken as a sweep starts. Plan Step 1.2.
  ///
  /// Rewritten: it used to say "hold still **and** turn your phone", which
  /// asks for two opposite things at once. The sweep is now three deliberate
  /// positions with a capture at each, so the instruction says that.
  String get visionSweepPrompt => _t(
        'I will take three looks. Point your phone where I say, and hold still.',
        'তিনবার দেখব। যেদিকে বলি ফোনটা ধরুন, আর একটু স্থির থাকুন।',
      );

  /// The three sweep positions, in order.
  ///
  /// Short because each is spoken while the user is mid-turn and waiting to
  /// stop. A long sentence here is a sentence they move through, which
  /// reintroduces the motion blur this design exists to remove.
  String visionSweepStep(int index) => switch (index) {
        0 => _t('Left.', 'বাঁয়ে।'),
        1 => _t('Straight ahead.', 'সোজা সামনে।'),
        _ => _t('Right.', 'ডানে।'),
      };

  /// Said once the last frame is in, so the user knows they may move again.
  String get visionSweepDone => _t('Got it — looking now.', 'হয়েছে — এখন দেখছি।');

  /// A single-frame scan needs no stand-still instruction — it is already
  /// taken by the time this would be said.
  String get visionLookingNow => _t('Looking…', 'দেখছি…');

  String get visionAlreadyLooking =>
      _t('I am still looking — one moment.', 'এখনও দেখছি — একটু দাঁড়ান।');

  String get visionNoCamera => _t(
        'I cannot use the camera on this phone, so I cannot look for you.',
        'এই ফোনের ক্যামেরা ব্যবহার করতে পারছি না, তাই দেখতে পারছি না।',
      );

  String get visionCaptureFailed => _t(
        'The camera did not take a picture, so I could not look. Try again.',
        'ক্যামেরা ছবি তুলতে পারেনি, তাই দেখতে পারিনি। আবার চেষ্টা করুন।',
      );

  /// Said when the edge model aborted the scan — plan Step 2.3. The long
  /// buzz has already fired by the time this is spoken.
  ///
  /// Short on purpose. This is the one sentence in the app that has to land
  /// before the user's next step, and a clause they have to listen through
  /// is a clause they are still walking during.
  String visionHazardAbort(String object) =>
      _t('Stop. $object right in front of you.', 'থামুন। সামনেই $object।');

  String get visionBudgetSpent => _t(
        'I have looked too many times just now. Ask me again in a minute.',
        'একটু আগে অনেকবার দেখেছি। এক মিনিট পরে আবার বলুন।',
      );

  /// Offline: the local model saw things but nothing could be read.
  ///
  /// The "cannot read signs without internet" half is not optional — without
  /// it this sentence implies the question was answered.
  String visionOfflineSaw(String things) => _t(
        'I can see $things. I cannot read any signs without internet.',
        'আমি $things দেখতে পাচ্ছি। ইন্টারনেট ছাড়া কোনো লেখা পড়তে পারছি না।',
      );

  String get visionOfflineNothingSeen => _t(
        'I cannot see anything I recognise, and I have no internet to look properly.',
        'চেনা কিছু দেখতে পাচ্ছি না, আর ভালো করে দেখার মতো ইন্টারনেটও নেই।',
      );

  String visionCountedObject(String label, int count) =>
      count <= 1 ? _t('a $label', '$labelটি') : _t('$count ${label}s', '$countটি $label');

  String get visionListSeparator => _t(', ', ', ');

  /// The verified bus answer — route number from the sign, destination from
  /// the Firestore directory. See `VisionConfig.busRouteLookupWins`.
  String visionBusVerified({required String route, required String destination}) => _t(
        'This is the $route bus, going to $destination.',
        'এটা $route, $destination যাচ্ছে।',
      );

  /// When the operator is known but which of its routes this is, is not.
  ///
  /// The BRTC case: nine corridors share one name on the signboard. Naming a
  /// destination here would be a coin flip stated as fact, to somebody who
  /// boards on the strength of it — so the sentence stops at what is true and
  /// tells them how to find out the rest.
  String visionBusNameOnly(String route) => _t(
        'This is the $route bus. I cannot tell where it goes — ask the helper.',
        'এটা $route। কোথায় যাচ্ছে বলতে পারছি না — হেলপারকে জিজ্ঞেস করুন।',
      );

  /// COCO class names, spoken.
  ///
  /// `bicycle` and `car` are deliberately vague in Bangla — the detector has
  /// no rickshaw or CNG class and routinely calls a cycle-rickshaw a bicycle
  /// and a CNG auto a car. Saying "রিকশা" on that evidence would be
  /// confidently wrong; "দুই চাকার গাড়ি" is merely imprecise, and imprecise
  /// is the side to err on when the listener cannot check.
  String visionObjectLabel(String? cocoLabel) => switch (cocoLabel) {
        'bus' => _t('a bus', 'বাস'),
        'truck' => _t('a truck', 'ট্রাক'),
        'car' => _t('a car', 'গাড়ি'),
        'motorcycle' => _t('a motorbike', 'মোটরসাইকেল'),
        'bicycle' => _t('a bike or rickshaw', 'সাইকেল বা রিকশা'),
        'person' => _t('a person', 'একজন মানুষ'),
        'train' => _t('a train', 'ট্রেন'),
        'traffic light' => _t('a traffic light', 'ট্রাফিক বাতি'),
        'dog' => _t('a dog', 'কুকুর'),
        'bench' => _t('a bench', 'বেঞ্চ'),
        null => _t('something', 'কিছু একটা'),
        _ => _t('something', 'কিছু একটা'),
      };

  /// Prefixes an answer served from the cooldown cache.
  ///
  /// Without it a frame up to twelve seconds old is spoken in the present
  /// tense, and the user asked again precisely because they thought something
  /// had changed. Same rule as every other string in this block: what the app
  /// actually knows has to be distinguishable from what is true now.
  String visionFromAMomentAgo(String answer) =>
      _t('A moment ago: $answer', 'একটু আগে: $answer');

  /// The ground stops ahead — a step down, a kerb, an unguarded edge.
  ///
  /// The most urgent thing this app says, and the shortest. A fall is the
  /// injury a blind pedestrian actually suffers, and a sentence they are
  /// still listening to is a sentence they are still walking through.
  ///
  /// Says "drops" rather than "stairs": the depth reading knows the ground
  /// falls away, not what is below it. Naming stairs when it is an open drain
  /// would be worse than naming neither.
  String visionGroundDrops(int paces) => paces <= 1
      ? _t('Stop. The ground drops right in front of you.',
          'থামুন। ঠিক সামনেই নিচু হয়ে গেছে।')
      : _t('Careful — the ground drops about $paces paces ahead.',
          'সাবধান — প্রায় $paces পা সামনে নিচু হয়ে গেছে।');

  /// The camera button on the input row.
  ///
  /// A visible control for a feature otherwise reachable only by voice or by
  /// holding a volume key. Those two serve a blind user well and serve nobody
  /// else: a low-vision user reads the screen, and a sighted companion
  /// helping someone at a kerb has no way to discover the scan at all.
  String get visionScanSemantics => _t('Look around with the camera', 'ক্যামেরা দিয়ে চারপাশ দেখুন');
  String get visionScanHint => _t('Tap to look', 'দেখতে চাপুন');
  String get visionScanBusy => _t('Looking now', 'এখন দেখছি');

  /// Spoken while a ride scan runs.
  String get visionLookingForRide => _t('Looking for a ride…', 'একটা গাড়ি খুঁজছি…');

  /// No rickshaw, CNG or taxi in view.
  String get visionNoRideSeen => _t(
        'I cannot see a rickshaw or CNG right now.',
        'এখন কোনো রিকশা বা সিএনজি দেখতে পাচ্ছি না।',
      );

  /// Offered after a ride is spotted — the user cannot wave, so the app
  /// shows and speaks the request for them. Reuses the Passerby Helper
  /// overlay, which already exists for exactly this shape of problem.
  String visionOfferHail(String destination) => destination.isEmpty
      ? _t('Shall I show a sign asking for a ride?',
          'গাড়ি চাই লেখা দেখাব?')
      : _t('Shall I show a sign asking for a ride to $destination?',
          '$destination যাব লেখা দেখাব?');

  /// What the passerby/driver sees, in large type, and what is spoken aloud.
  String visionHailSign(String destination) => destination.isEmpty
      ? _t('I need a ride. I cannot see.', 'আমার একটা গাড়ি লাগবে। আমি দেখতে পাই না।')
      : _t('I need a ride to $destination. I cannot see.',
          'আমি $destination যাব। আমি দেখতে পাই না।');

  /// Offered after a scan spots a durable ground hazard — never filed
  /// automatically. See `SnapshotVisionService._reportableKinds`.
  String visionOfferReport(String hazard) => _t(
        'I saw $hazard. Should I report it so others know?',
        '$hazard দেখলাম। অন্যদের জানাতে রিপোর্ট করব?',
      );
}
