/// Whether the Magic Button actually contacts anybody.
///
/// ## Why this exists, and why it defaults to off
///
/// Module 9 sends an SMS to the user's family and then telephones them.
/// Every part of that is worth testing with real people — is the
/// announcement clear? does five seconds feel like enough to say "cancel"?
/// is the vibration distinguishable from the others? — and none of those
/// questions need a single message to actually leave the phone.
///
/// The risk of leaving it live during testing is not hypothetical. A tester
/// completing onboarding enters their **real** emergency contacts. The
/// voice-command pack's entire job is saying unexpected things. And the
/// physical trigger is Volume Down held for three seconds, which is close
/// to indistinguishable from someone fiddling with the volume while testing
/// speech output. The first time that misfires, somebody's mother gets a
/// message saying her child is in danger, and a phone call, from code that
/// has never run on hardware.
///
/// So the default is a rehearsal: the whole sequence runs, everything is
/// spoken, the cancel window behaves exactly as it will in earnest, and the
/// dispatch step says what it *would* have done instead of doing it. That
/// is the version testers should have.
///
/// ## Turning it on
///
/// ```
/// flutter run --dart-define=EMERGENCY_LIVE_DISPATCH=true
/// ```
///
/// Do that on a device you control, with your own number as the only
/// contact, before it ever goes out live. Enable it for real distribution
/// only once someone has watched a real message arrive and a real phone
/// ring — this is the one feature in the app where "the tests pass" is not
/// evidence that it works.
class EmergencyConfig {
  const EmergencyConfig._();

  /// True when SMS and calls are really sent.
  static const bool liveDispatch =
      bool.fromEnvironment('EMERGENCY_LIVE_DISPATCH', defaultValue: false);

  /// True when the sequence runs but contacts nobody.
  static bool get isRehearsal => !liveDispatch;
}
