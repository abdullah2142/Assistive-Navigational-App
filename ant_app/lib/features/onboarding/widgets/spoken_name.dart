// `characters` comes via Flutter's own re-export rather than a direct import:
// it is only a transitive dependency here, and `depend_on_referenced_packages`
// rightly objects to importing one of those by name. Not an accident — leaving
// it as `package:characters/characters.dart` fails analysis.
import 'package:flutter/widgets.dart';

/// Spells a dictated name out so it can be checked by ear.
///
/// The emergency-contact read-back already speaks the phone number one digit
/// at a time, for a reason it states plainly: a dictated number is easy for
/// STT to get subtly wrong, and this is the contact somebody's life may run
/// through. Testers confirmed that half works.
///
/// The name had no equivalent, and it needs one more than the number does.
/// Reported against the step that asks for "a relative's real name": the
/// read-back came out misspelled. It could not have been caught, either —
/// the name was only ever *pronounced*, and "Rahima", "Rohima" and "Raheema"
/// are the same sound. A user who cannot see the screen had no way to tell a
/// correct transcription from a wrong one, so the read-back was asking them
/// to confirm something they could not actually check.
///
/// Speaking the name **and then** spelling it gives both: the pronunciation
/// to recognise it by, and the letters to verify it by.
///
/// Split by grapheme cluster, not by code unit, which is the whole difficulty
/// in Bangla. `'রাহিমা'.split('')` yields `র া হ ি ম া` — bare vowel signs
/// that mean nothing said aloud and are not how anyone spells a name. The
/// grapheme clusters are `রা হি মা`: the syllables, which is exactly how a
/// Bangla speaker spells one out. Conjuncts hold together for the same
/// reason — `আব্দুল্লাহ` is `আ ব্দু ল্লা হ`.
///
/// Word boundaries are kept, so a full name is spelled one word at a time
/// rather than as one unbroken run of letters.
String spelledOutName(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words
      .map((word) => word.characters.join(' '))
      // A pause between words. TTS engines read a comma as a beat, which is
      // what keeps "Rahima Khatun" from arriving as one twelve-letter run.
      .join(', ');
}
