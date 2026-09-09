/// A place the user asked to save, with something still missing.
///
/// ## Why this exists
///
/// Saving a place is a two- or three-slot request — a name, and a location
/// that is either "here" or an address — and users do not supply all of it in
/// one breath. Reported from the device, twice over:
///
/// > "i say add a new place, it asks where and what to call it, i only say
/// > hospital, expecting to be asked about address of it, it then gives me
/// > list of places with hospital keyword in it"
///
/// and
///
/// > "it asks me to tell the name of the place id like to add, i say it, and
/// > it goes back to routing me straight to that place on the map"
///
/// Both are the same failure: the answer to the assistant's own question was
/// read as a *fresh command* rather than as the missing slot, so it went to
/// the destination matcher and the save was abandoned silently. The user
/// could enter the conversation but never finish it.
///
/// `DestinationClarification` already solves exactly this shape for
/// `request_route`. This is the same idea for `save_place`, deliberately kept
/// separate: the questions are different (a *name* is whatever the user wants
/// to call it and cannot be wrong; an address can be) and conflating them
/// would mean one of the two got the other's retry budget and wording.
class PendingPlaceSave {
  const PendingPlaceSave({this.label, this.address, this.attempts = 0});

  /// What to call it, once the user has said. Null while that is the
  /// outstanding question.
  final String? label;

  /// A written address, when the place is not where the user is standing.
  final String? address;

  /// How many questions have been asked. Bounded for the same reason
  /// `DestinationClarification` bounds its own: somebody standing on a
  /// footpath being interrogated about a place they have already described
  /// is not being helped.
  final int attempts;

  static const int maxAttempts = 3;

  bool get isExhausted => attempts >= maxAttempts;

  /// What the assistant should ask next, or null when nothing is missing.
  PlaceSaveQuestion? get nextQuestion {
    if (label == null || label!.trim().isEmpty) return PlaceSaveQuestion.name;
    return null;
  }

  PendingPlaceSave withLabel(String value) =>
      PendingPlaceSave(label: value, address: address, attempts: attempts + 1);

  PendingPlaceSave withAddress(String value) =>
      PendingPlaceSave(label: label, address: value, attempts: attempts + 1);

  PendingPlaceSave asked() => PendingPlaceSave(label: label, address: address, attempts: attempts + 1);
}

enum PlaceSaveQuestion { name, address }
