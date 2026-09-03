import '../localization/app_language.dart';

/// Step 4 of the AI Assistant module plan — Graceful Offline Degradation.
///
/// When Gemini can't be reached (no signal, quota exceeded, no key
/// configured yet), the app must not just go silent. Real Vosk-style
/// bundled offline STT models are a large binary-asset undertaking of their
/// own; this is the lightweight stand-in the module plan describes as
/// "maps recognized commands to... pre-recorded audio" — here, a small
/// bilingual keyword matcher over whatever [SttService] already transcribed
/// (on-device recognition keeps working without internet), paired with
/// canned safety-relevant replies spoken through the always-available
/// on-device `TtsService`.
class OfflineIntentMatcher {
  OfflineIntentMatcher._();

  static const _help = ['help', 'সাহায্য'];
  static const _stop = ['stop', 'থাম', 'থামুন'];
  static const _whereAmI = ['where am i', 'kothay achi', 'আমি কোথায়'];
  static const _emergency = ['emergency', 'জরুরি'];

  /// Returns a canned reply if [rawText] matches a known safety keyword, or
  /// `null` if nothing matched (caller should fall back to a generic
  /// "assistant unavailable" message).
  static String? match(String rawText, AppLanguage language) {
    final text = rawText.toLowerCase();
    final bn = language == AppLanguage.bangla;

    if (_emergency.any(text.contains)) {
      return bn
          ? 'ইন্টারনেট নেই, তাই সহকারী এখন কথা বুঝতে পারছে না। জরুরি অবস্থায় ম্যাজিক বাটন চাপুন অথবা সরাসরি ফোন করুন।'
          : 'No internet, so I can\'t process that right now. For an emergency, use the Magic Button or call for help directly.';
    }
    if (_help.any(text.contains)) {
      return bn
          ? 'বেসিক সেফটি মোড চালু আছে। আপনার লোকেশন এখনও আপনার কেয়ারটেকারকে দেখানো হচ্ছে।'
          : 'Basic Safety Mode is active. Your location is still visible to your caretaker.';
    }
    if (_stop.any(text.contains)) {
      return bn ? 'ঠিক আছে, থামছি।' : 'Okay, stopping.';
    }
    if (_whereAmI.any(text.contains)) {
      return bn
          ? 'ইন্টারনেট নেই বলে এখন বিস্তারিত বলতে পারছি না, তবে আপনার লোকেশন ট্র্যাক হচ্ছে।'
          : 'I can\'t reach the AI service right now, but your location is still being tracked.';
    }
    return null;
  }
}
