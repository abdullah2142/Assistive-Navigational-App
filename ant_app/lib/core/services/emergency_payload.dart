import '../localization/app_language.dart';

/// What an emergency SMS actually says.
///
/// Separated from sending so the text a frightened relative receives at 11pm
/// is pinned by tests rather than assembled inline at the one moment nobody
/// will be watching. Every constraint below came from asking what that
/// person can do with the message in the sixty seconds after reading it.
///
/// ## Why this returns a list
///
/// A single GSM-7 SMS holds 160 characters. Bangla is outside GSM-7, so a
/// Bangla message is encoded as UCS-2 and holds **70** — and a maps link
/// alone is over fifty. The obvious message ("emergency, battery, here is
/// where I am") measured 96 characters in Bangla, which the network splits
/// into two concatenated parts. Concatenated parts usually reassemble, but
/// "usually" is doing a lot of work in the one situation this feature
/// exists for, and the part that would be dropped is the tail — the
/// location.
///
/// So instead of one message that might arrive in halves, this sends
/// messages that are each **individually complete and individually within
/// one part**: the alert in the user's language, and — when the alert
/// cannot also carry it — the location on its own in pure ASCII, which
/// stays in GSM-7 and is legible to a Bangla reader anyway because it is a
/// URL.
class EmergencyPayload {
  const EmergencyPayload._();

  /// Characters in one UCS-2 (non-GSM-7) SMS part. Bangla is always this.
  static const int singlePartUcs2 = 70;

  /// Characters in one GSM-7 SMS part. Plain-ASCII messages get this.
  static const int singlePartGsm7 = 160;

  /// A maps link the recipient can tap in any messaging app.
  ///
  /// The bare `?q=lat,lng` form, not a shortened or app-specific URL: it
  /// opens in whatever map the recipient has, works in a browser with no
  /// app at all, and needs no service of ours to still be running. In an
  /// emergency the link must not depend on our infrastructure.
  ///
  /// Six decimal places is about 10 cm — far past GPS accuracy, but it
  /// costs three characters and removes any question of rounding having
  /// moved the pin to the wrong side of a road.
  static String mapsLink(double lat, double lng) =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';

  /// The characters-per-part limit that applies to [text].
  ///
  /// Decided by the text itself, not by the user's language: one non-GSM-7
  /// character forces the whole message to UCS-2, and a message that is
  /// entirely ASCII gets the roomier limit even when the app is in Bangla.
  static int limitFor(String text) =>
      text.runes.every((r) => r < 0x80) ? singlePartGsm7 : singlePartUcs2;

  /// Whether [text] fits in a single SMS part.
  static bool fitsOnePart(String text) => text.runes.length <= limitFor(text);

  /// The messages to send, in order. Each is guaranteed to fit one part.
  ///
  /// [batteryPercent] is included because it tells the recipient how long
  /// they have — a phone at 4% will stop updating its location shortly, and
  /// that changes whether you drive over or keep calling. Omitted rather
  /// than guessed when the platform will not report it.
  ///
  /// [name] identifies who is in trouble; a relative may be the contact for
  /// more than one person, and an unattributed "I need help" is a worse
  /// message. It is the first thing dropped if the alert would not
  /// otherwise fit, because "someone you know needs help, here" beats a
  /// message that arrives in pieces.
  static List<String> messages({
    required AppLanguage language,
    required String? name,
    required double? lat,
    required double? lng,
    required int? batteryPercent,
  }) {
    final hasLocation = lat != null && lng != null;
    final link = hasLocation ? mapsLink(lat, lng) : null;

    String alert({required bool withName, required bool withLink}) {
      final who = withName && name != null && name.trim().isNotEmpty ? name.trim() : null;
      final parts = <String>[];
      if (language == AppLanguage.bangla) {
        parts.add(who == null ? 'জরুরি! সাহায্য দরকার।' : 'জরুরি! $who-এর সাহায্য দরকার।');
        if (batteryPercent != null) parts.add('ব্যাটারি $batteryPercent%।');
        if (!hasLocation) parts.add('অবস্থান জানা যায়নি।');
        if (withLink && link != null) parts.add('অবস্থান: $link');
      } else {
        parts.add(who == null ? 'EMERGENCY: I need help.' : 'EMERGENCY: $who needs help.');
        if (batteryPercent != null) parts.add('Battery $batteryPercent%.');
        if (!hasLocation) parts.add('Location unavailable.');
        if (withLink && link != null) parts.add('Location: $link');
      }
      return parts.join(' ');
    }

    // Best case — one message carrying everything. True for English, and
    // for Bangla only when there is no location to carry.
    final combined = alert(withName: true, withLink: true);
    if (fitsOnePart(combined)) return [combined];

    // Otherwise split. The alert goes first so the recipient knows what
    // they are looking at before the link arrives.
    var head = alert(withName: true, withLink: false);
    if (!fitsOnePart(head)) head = alert(withName: false, withLink: false);

    if (link == null) {
      // Nothing to split off and it still does not fit. Only reachable via
      // an absurd name, and truncating beats emitting two parts.
      return [_clip(head)];
    }

    // Pure ASCII, so this is GSM-7 and comfortably one part even though the
    // app is in Bangla. A URL needs no translation.
    final location = 'Location: $link';
    return [fitsOnePart(head) ? head : _clip(head), location];
  }

  static String _clip(String text) {
    final limit = limitFor(text);
    final runes = text.runes.toList();
    if (runes.length <= limit) return text;
    return String.fromCharCodes(runes.take(limit));
  }
}
