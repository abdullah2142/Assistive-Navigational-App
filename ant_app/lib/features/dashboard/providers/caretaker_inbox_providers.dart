import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../guardian/models/communication_message.dart';
import '../../guardian/providers/guardian_providers.dart';

/// Messages sent *to* this user by their caretaker.
///
/// Module 8's receiving half, which did not exist. `CommunicationService`,
/// the Firestore rules and the pairing transaction were all correct and all
/// tested — but `communicationsStreamProvider` was referenced only from inside
/// `lib/features/guardian/`, the caretaker's own UI. Nothing on the Disabled
/// User's device ever subscribed, so memos and snapshot requests were written
/// and nobody was listening. Reported as "caretaker er snapshot request user
/// er kache ashtese na. Not only that, communication er kono part e kaaj
/// korche na" (open_bugs item 28).
///
/// Filtered to incoming, in Dart rather than in the query: the collection is
/// keyed by the Disabled User's uid and already capped at 50 by
/// `watchMessages`, so both directions of one conversation arrive together and
/// splitting them server-side would need a composite index for no benefit.
final incomingCaretakerMessagesProvider =
    StreamProvider.family<List<CommunicationMessage>, String>((ref, myUid) {
  return ref
      .watch(communicationServiceProvider)
      .watchMessages(myUid)
      .map((all) => all.where((m) => m.toUid == myUid && m.fromUid != myUid).toList());
});
