import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import 'api_budget.dart';
import 'assistant_service.dart';
import '../../features/dashboard/models/chat_message.dart';
import '../../features/dashboard/models/hazard_report.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../config/gemini_config.dart';
import '../localization/app_language.dart';
import 'destination_clarifier.dart';
import 'function_call_executor.dart';
import 'vision/vision_scene.dart' show ScanFocus;
import 'pending_place_save.dart';
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

/// One completed exchange: what to show/speak, and any side effects the
/// model (or, since `LocalIntentMatcher` was added, a plain local pattern
/// match — see `FunctionCallExecutor`) asked for.
/// Thrown when this month's Gemini call ceiling is spent.
///
/// A distinct type so the failure is legible in a log rather than arriving as
/// a generic exception: "the budget stopped this" and "the network stopped
/// this" want different responses from whoever reads the diagnostics.
class GeminiBudgetExhausted implements Exception {
  const GeminiBudgetExhausted();

  @override
  String toString() =>
      'GeminiBudgetExhausted: this month\'s assistant call ceiling is spent '
      '(see BillableApi.gemini). Falling back to the offline matcher.';
}

class AssistantTurn {
  const AssistantTurn({
    required this.responseText,
    this.updatedProfile,
    this.overlayAction,
    this.route,
    this.routeAlternatives,
    this.hazardPrefill,
    this.clarification,
    this.placeSave,
    this.scanFocus,
    this.scanQuestion,
    this.triggersEmergency = false,
    this.cancelsRoute = false,
  });

  /// Non-null when the model called `look_around` — Module 6.
  ///
  /// A request rather than a result: the scan needs the camera, and the
  /// executor has no more business opening a camera than it has opening an
  /// overlay. The caller runs it, which is also what keeps the single-scan
  /// guard and the spoken "hold still" prompt in one place.
  final ScanFocus? scanFocus;

  /// The user's own question, when they asked something the [ScanFocus] enum
  /// cannot express — "what colour is the rabbit", "what is written on this
  /// page".
  ///
  /// The vision prompt was built purely from the focus, so every such
  /// question arrived as `surroundings` and was answered with a description
  /// of the path ahead. The user had asked about a rabbit and was told about
  /// a footpath, which reads as the camera not working at all.
  final String? scanQuestion;

  final String responseText;

  /// True when the model asked to end the walk.
  ///
  /// A flag, not an applied change: cancelling stops the narrator and clears
  /// the route from chat state, and the caller owns both. See
  /// [triggersEmergency], which exists for the same reason.
  final bool cancelsRoute;

  /// True when the model judged the user to be in danger.
  ///
  /// A flag rather than an executed action, because the emergency is a
  /// sequence — speak, wait, dispatch, call, alert, route — and the
  /// executor exists to apply one change and describe it. The caller runs
  /// it, exactly as it does for a locally-matched trigger, so both paths
  /// converge on one implementation and one cancel window.
  final bool triggersEmergency;

  /// Non-null only when a `update_setting`/contact/message function call
  /// actually changed something — the caller persists this via
  /// `ProfileService`.
  final UserProfile? updatedProfile;

  /// Non-null when the model called `open_passerby_helper` or
  /// `open_hazard_report` — the caller (which owns a `BuildContext`) shows
  /// that overlay, the same one the equivalent suggested chip opens.
  final SuggestedChipAction? overlayAction;

  /// Non-null when `request_route` (Module 4) successfully planned a
  /// safety-checked route — the caller surfaces it on the dashboard map.
  final RouteChoice? route;

  /// The other walking routes found alongside [route], for
  /// `request_alternative_route` to switch to. Null when this turn said
  /// nothing about routing — distinct from empty, which means "there are no
  /// others" and is worth telling the user.
  final List<RouteCandidate>? routeAlternatives;

  /// Non-null when the hazard-report overlay was opened by a command that
  /// already named the hazard ("report an open manhole") — the Hub opens
  /// straight to that hazard instead of at the top of its menu.
  final HazardReportPrefill? hazardPrefill;

  /// Non-null when the assistant just asked the user where a destination
  /// actually is, and is waiting for the answer.
  final DestinationClarification? clarification;

  /// Non-null when a save is missing a slot and the assistant has just asked
  /// for it — see [PendingPlaceSave].
  final PendingPlaceSave? placeSave;
}

/// The central brain (AI Assistant module plan, Step 2): builds a per-turn
/// contextual prompt from the user's live profile/location/app state,
/// sends it to Gemini with function-calling tools that mirror every field
/// `MySettingsScreen` can edit plus the two overlay actions, and returns
/// natural-language `response_text` for `TtsService` and the chat bubble.
///
/// Deliberately stateless at the network layer across turns — each call
/// rebuilds context from the *current* profile rather than trusting a
/// long-lived server-side session, and only the last few messages ride
/// along for short-term coherence. That keeps prompts small (see "API
/// Strategy & Cost Mitigation" in `project_master_plan.md`) and means a
/// setting changed by the paired Caretaker's Remote Management screen
/// mid-conversation is picked up on the very next turn for free.
///
/// What actually *happens* for a given function name/args (validation,
/// profile mutation, confirmation wording) lives in [FunctionCallExecutor]
/// now, not here — pulled out specifically so `ChatController` can execute
/// the exact same effect for a message `LocalIntentMatcher` recognized
/// locally (e.g. "switch to dark mode", "show my screen") without ever
/// making this class's network call, saving the latency and token cost of
/// a full Gemini round trip for the common, unambiguous cases. This class
/// still owns the *decision* of which function to call for anything the
/// local matcher isn't confident about, plus all free-form conversation.
class GeminiAssistantService implements AssistantService {
  @override
  String get backendName => 'gemini:${GeminiConfig.modelName}';

  GeminiAssistantService({
    required String apiKey,
    required FunctionCallExecutor executor,
    ApiBudget? budget,
  })  : _budget = budget ?? defaultApiBudget,
        _model = GenerativeModel(
          model: GeminiConfig.modelName,
          apiKey: apiKey,
          tools: [Tool(functionDeclarations: _tools)],
          // 400 was too tight and cut real replies short in testing — this
          // model (`gemini-3.6-flash`, a "thinking" model per the doc
          // comment on `converse`) spends part of its token budget on
          // internal reasoning before the visible reply, so a low cap can
          // exhaust itself before any answer text comes out at all.
          generationConfig: GenerationConfig(temperature: 0.4, maxOutputTokens: 1024),
        ),
        _executor = executor;

  final GenerativeModel _model;
  final FunctionCallExecutor _executor;
  final ApiBudget _budget;

  /// How many prior messages ride along as short-term context.
  static const int _historyTurns = 8;

  /// [onPartialText] fires with the accumulated text so far as each chunk
  /// streams in — purely a lower-perceived-latency UI affordance (the chat
  /// bubble fills in progressively instead of appearing all at once after
  /// the full round trip), never called once a function call has been seen
  /// in the stream. A plain-text reply's final [AssistantTurn.responseText]
  /// is just the last accumulated value; a function-call turn's is the
  /// templated confirmation built below, same as before streaming existed —
  /// [onPartialText] simply never fires for that turn, since Gemini's
  /// function-calling turns don't emit meaningful text ahead of the call
  /// itself in practice.
  @override
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    /// The route the user is currently walking, if any — `resolve_hazard`
    /// is scoped to the hazards on it. See `FunctionCallExecutor`.
    RouteChoice? activeRoute,
    /// The unused alternatives to [activeRoute], which
    /// `request_alternative_route` switches between.
    List<RouteCandidate> routeAlternatives = const [],
  }) async {
    // The money ceiling, checked before the call rather than after the bill.
    //
    // Google's budget alerts do not cap spend — they email once it is gone —
    // so the only real ceiling lives in the client, which is the same
    // reasoning `MonthlyApiBudget` already applies to the Maps APIs. See
    // `BillableApi.gemini` for how the cap was derived.
    //
    // Throwing rather than returning a canned reply, so this takes the
    // existing failure path: `ChatController` already falls back to
    // `OfflineIntentMatcher`, which still answers the safety keywords —
    // help, stop, where am I, emergency — with no model at all.
    if (!await _budget.tryConsume(BillableApi.gemini)) {
      throw const GeminiBudgetExhausted();
    }

    final contents = <Content>[
      ..._historyToContents(recentHistory),
      Content.text(buildPrompt(userText: userText, profile: profile, location: location)),
    ];

    final calls = <FunctionCall>[];
    final textBuffer = StringBuffer();
    await for (final chunk in _model.generateContentStream(contents)) {
      calls.addAll(chunk.functionCalls);
      final chunkText = chunk.text;
      if (chunkText == null || chunkText.isEmpty) continue;
      textBuffer.write(chunkText);
      if (calls.isEmpty) onPartialText?.call(textBuffer.toString());
    }

    if (calls.isEmpty) {
      return AssistantTurn(responseText: _textOrFallback(textBuffer.toString(), profile));
    }

    var workingProfile = profile;
    SuggestedChipAction? overlay;
    RouteChoice? route;
    List<RouteCandidate>? alternatives;
    HazardReportPrefill? hazardPrefill;
    ScanFocus? scanFocus;
    String? scanQuestion;
    DestinationClarification? clarification;
    PendingPlaceSave? placeSave;
    final confirmations = <String>[];
    for (final call in calls) {
      final applied = await _executor.execute(
        name: call.name,
        args: call.args,
        profile: workingProfile,
        location: location,
        // A turn that plans a route and then immediately asks for a
        // different one must switch between *that* route's alternatives,
        // not the previous route's.
        activeRoute: route ?? activeRoute,
        routeAlternatives: alternatives ?? routeAlternatives,
      );
      workingProfile = applied.updatedProfile ?? workingProfile;
      overlay ??= applied.overlayAction;
      if (applied.route != null) route = applied.route;
      if (applied.routeAlternatives != null) alternatives = applied.routeAlternatives;
      hazardPrefill ??= applied.hazardPrefill;
      scanFocus ??= applied.scanFocus;
      scanQuestion ??= applied.scanQuestion;
      clarification ??= applied.clarification;
      placeSave ??= applied.placeSave;
      confirmations.add(applied.responseText);
    }

    // Deliberately not a second `generateContent` round trip to let the
    // model phrase its own confirmation — replaying a function-call turn
    // back to Gemini's "thinking" models (3.x) requires echoing the exact
    // `thoughtSignature` the model attached to that turn, and this SDK
    // version (0.4.7, predating "thinking" models) doesn't capture that
    // field on `FunctionCall` at all, so any reconstructed turn is
    // rejected with "missing thought_signature" regardless of which role
    // is used to send it (also confirmed live: the classic `role:
    // 'function'` this SDK sends for `FunctionResponse` content is itself
    // no longer accepted — "Role 'function' is not supported"). Bypassing
    // the round trip entirely is more robust against this kind of
    // API-surface drift than reverse-engineering the new contract, and as
    // a side benefit halves per-turn latency (one call instead of two).
    return AssistantTurn(
      responseText: confirmations.join(' '),
      updatedProfile: identical(workingProfile, profile) ? null : workingProfile,
      overlayAction: overlay,
      route: route,
      routeAlternatives: alternatives,
      hazardPrefill: hazardPrefill,
      scanFocus: scanFocus,
      scanQuestion: scanQuestion,
      clarification: clarification,
      placeSave: placeSave,
    );
  }

  String _textOrFallback(String? text, UserProfile profile) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    return profile.language == AppLanguage.bangla ? 'ঠিক আছে।' : 'Got it.';
  }

  List<Content> _historyToContents(List<ChatMessage> history) {
    final recent = history.length > _historyTurns ? history.sublist(history.length - _historyTurns) : history;
    return recent.map((m) => Content(m.sender == ChatSender.user ? 'user' : 'model', [TextPart(m.text)])).toList();
  }

  /// Static because it is pure — it reads nothing but its own arguments.
  ///
  /// That also makes it assertable, which matters more than it looks: the
  /// prompt is the entire implementation of several reported behaviours (item
  /// 55's indirect requests among them), and a rule quietly dropped from it
  /// fails exactly like a deleted function, with nothing to catch it.
  @visibleForTesting
  static String buildPrompt({
    required String userText,
    required UserProfile profile,
    Position? location,
  }) {
    final bn = profile.language == AppLanguage.bangla;
    final locationLine = location == null
        ? 'Not available right now.'
        : '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}';

    return '''
You are ANT, a calm, safety-focused navigational assistant for a person with a disability, living in Dhaka, Bangladesh. Be warm but brief — this user may have limited patience for long replies.

User profile:
- Vision: ${profile.visionLevel.name}
- Mobility aid: ${profile.mobilityAid.name}
- Deaf or hard of hearing: ${profile.isDeafOrHardOfHearing}
- Gets anxious in crowded places: ${profile.crowdedPlacesAnxious}
- Finds complex multi-step instructions hard to follow: ${profile.complexInstructionsHard}
- Preferred reply style: ${profile.verbosity.name} (minimalist = a single short sentence, no filler; descriptive = a bit more context, still concise)
- Snapshot-sharing permission for their caretaker: ${profile.snapshotConsent.name}
- Paired with a caretaker: ${profile.pairedUserId != null}
${profile.magicButtonContacts.isEmpty ? '' : '''
Emergency contacts already saved (these ARE stored and you can read them back):
${profile.magicButtonContacts.map((c) => '- ${c.name}${c.relationship.isEmpty ? '' : ' (${c.relationship})'}: ${c.phoneNumber}').join('\n')}'''}
${profile.savedPlaces.isEmpty ? '' : '''
Places this user has saved:
${profile.savedPlaces.map((p) => '- ${p.label}${p.address.isEmpty ? '' : ' (${p.address})'}').join('\n')}'''}

${profile.rememberedNotes.isEmpty ? '' : '''
Things this user has told you about themselves before (kept across sessions — treat as true, and use them without being asked again):
${profile.rememberedNotes.map((n) => '- $n').join('\n')}
'''}
Live location (may be stale or unavailable — never invent one if missing): $locationLine
Current app state: safety-weighted walking-route planning is available (call request_route). Live camera hazard/bus-sign scanning and emergency auto-dispatch are separate modules that are not deployed yet — if asked for those, say so briefly and don't pretend to do them.

Rules:
- Never describe the state of something you cannot actually read. You have no way to check whether a screen, the camera, the microphone or a connection is on, so do not say it is. A half-heard command ("Screen.", "Route.") is a request to clarify, not a cue to invent a status: ask which of the likely commands they meant, in one short question. A confident wrong answer is worse than a question, because the user cannot see that nothing happened.
- ALWAYS reply in ${bn ? 'Bangla' : 'English'}, regardless of what language the user's message is in, unless they explicitly ask you to switch.
- If reply style is minimalist, answer in one short plain sentence.
- If the user (not already paired) gives you a 6-digit code to link up with their caretaker, or asks to add/pair with a caretaker and mentions a code, call pair_with_caretaker. If they want to pair but haven't given a code yet, ask them for the 6-digit code their caretaker's app shows.
- The contacts and places listed above are real, saved, and readable. If the user asks what one of them is, read it back from that list. Never tell them something they have saved is not available to you — it is, it is written above.
- If the user is asking to change any setting (text size, theme, UI language, reply style, voice, vision level, mobility aid, deaf/hearing mode, snapshot permission, crowded/complex sensitivity, home or safe-place address, emergency contacts, passerby messages, the "Hey ANT" wake word), call the matching function instead of just claiming you did it. For theme, the only valid values are "light" and "dark" — there is no colour theme picker (red, blue, green etc.); if asked for one, say it does not exist.
- If the user wants to show a message to a passerby, or report a hazard, call the matching trigger function.
- If the user wants to go somewhere, asks for directions, or (right after you asked where they want to go) names a place, call request_route with that destination.
- If they are already on a route and want a different one ("another way", "I don't like this route"), call request_alternative_route.
- If they say they have come off the route, ask to "re-route", or ask which way to go from here, call replan_route.
- For a real emergency, tell them to use the physical Magic Button or call for help directly — you cannot dial or send messages on their behalf yet.
- If they want their caretaker told something, call send_caretaker_message with what they want said, in their own words. If they want to be checked on but have nothing specific to pass on, call alert_caretaker. If they want to send their own voice, call record_caretaker_voice_memo.
- If they ask where they are, what road or area this is, or say they are lost, call describe_current_location. Never guess a street name from the coordinates above.
- If they ask to see, show, open, hide or close the map, call open_map or close_map. This is not a route request.
- If they tell you something durable about themselves in passing — a preference, a limitation, a routine — call remember_about_me so it survives this conversation. If they ask you to forget something, call forget_about_me. Never claim to remember something without calling it.
- You already have their earlier messages above, including from previous sessions. Use them: do not ask again for something they have already told you. Do not contradict something you yourself said earlier this session — if you mentioned a place or fact, stay consistent with it.
- You have no access to the user's phone contacts. You cannot look up anyone's phone number from a name. If asked for a contact (a sister, a friend, etc.), say clearly that you cannot access phone contacts — and suggest the user check their own contacts app, or use add_emergency_contact if it is someone they want saved for emergencies.
- You have no real-time or general knowledge of what is inside or around any specific place. Never describe what shops, facilities or features are near a landmark, inside a building, or along a street unless you were explicitly told that in this conversation. "Some small shops and a seating area" is a guess. Say you don't have that detail.
- If the user corrects you about a local place name, area name, or whether something is nearby — accept it after at most one clarifying question. Do not re-argue with someone who is standing there. Defer to local knowledge.
- The destination you pass to request_route must trace back to something the user actually said. Never call it with a vague placeholder like "another place", "somewhere nearby" or any phrase that does not name a real destination — if you don't know where they want to go, ask.
- If the user states a budget, distance limit, or preference ("cheap", "nearby", "under 300 taka"), include that constraint verbatim in the destination field when calling request_route so the router can honour it.

Understanding what they actually need:
- **Act on the need, not the words.** People say what is wrong, not what they want you to do about it. "I need to poop", "I'm bursting", "my stomach hurts" is a request for the nearest toilet — call request_route for a nearby toilet, do not search for those words as if they were a place name. "I'm thirsty", "I need to sit down", "my phone is dying", "I need medicine" are the same shape: work out the kind of place that solves it and route there.
- **"The nearest X" is an answer, not a question.** If they ask for the closest or nearest anything, they have already told you which one they mean. Call request_route with the whole phrase including the word "nearest" — the route planner picks the closest one itself. Never read a list of options back to somebody who asked for the closest.
- **Never confirm a route request twice.** If the need is already clear — they said they urgently need something, they named a destination, or they already confirmed — call request_route immediately without asking "shall I start navigation?" or "do you want a route?". Asking again wastes the seconds somebody urgently waiting cannot afford.
- **You are a guardian, not only a map.** If somebody is unsure, uncomfortable or asking for advice, answer the question they asked before offering to take them anywhere. Not every problem is solved by walking somewhere, and offering a route to a person who asked whether it is safe to go out is not an answer.
- **Ask only when it changes what you would do.** One short question, never a list of possibilities, and never when a sensible default exists. A person standing in a Dhaka street who has just told you they urgently need a toilet should be given a route, not a questionnaire.

User's message: "$userText"
''';
  }

  /// The tool set the model is given.
  ///
  /// Exposed for tests. `trigger_emergency` takes no parameters, so its
  /// description *is* its logic — the entire specification of when to raise
  /// an alarm lives in that prose, and it is worth asserting on directly.
  @visibleForTesting
  static List<FunctionDeclaration> get functionDeclarations => _tools;

  static final List<FunctionDeclaration> _tools = [
    FunctionDeclaration(
      'pair_with_caretaker',
      'Link this user to a caretaker using the 6-digit pairing code the caretaker generated on their own '
          'device. Only relevant for a user who has no caretaker yet.',
      Schema.object(properties: {
        'code': Schema.string(description: 'The 6-digit pairing code the user read out or typed.'),
      }, requiredProperties: const ['code']),
    ),
    FunctionDeclaration(
      'update_setting',
      'Change one accessibility/app setting for the current user. Use this for any single-value preference change.',
      Schema.object(properties: {
        'setting': Schema.enumString(
          enumValues: const [
            'text_size',
            'theme',
            'language',
            'verbosity',
            'voice',
            'vision_level',
            'mobility_aid',
            'deaf_hearing_mode',
            'snapshot_consent',
            'crowded_places_anxious',
            'complex_instructions_hard',
            'home_address',
            'safe_place_address',
            'wake_word_enabled',
            'voice_auto_listen',
          ],
          description: 'Which setting to change.',
        ),
        'value': Schema.string(
          description: 'The new value. text_size: one of "0.8", "1.0", "1.25", "1.5", "2.0" '
              '— for "bigger"/"smaller" move ONE step from the current size, never jump to an end. '
              'theme: "light" or "dark". language: "english" or "bangla". verbosity: "minimalist" or '
              '"descriptive". voice: a voice id such as "bn-BD-female-1". vision_level: "none", "low", or '
              '"full". mobility_aid: "whiteCane", "wheelchair", or "unassisted". deaf_hearing_mode, '
              'crowded_places_anxious, complex_instructions_hard, wake_word_enabled, voice_auto_listen: '
              '"true" or "false". snapshot_consent: "always", "askEachTime", or "never". home_address / '
              'safe_place_address: free-text address.',
        ),
      }, requiredProperties: const ['setting', 'value']),
    ),
    FunctionDeclaration(
      'add_emergency_contact',
      'Add a new Magic Button emergency contact. Omit phone if they have not '
          'said the number — never invent one.',
      // `phone` is deliberately optional — see the Groq declaration for the
      // 23 September case where a required slot got filled with a number the
      // user never gave.
      Schema.object(properties: {
        'name': Schema.string(description: "Contact's name."),
        'phone': Schema.string(description: "Contact's phone number, only if they gave it."),
      }, requiredProperties: const ['name']),
    ),
    FunctionDeclaration(
      'remove_emergency_contact',
      'Remove an existing Magic Button emergency contact by name.',
      Schema.object(properties: {
        'name': Schema.string(description: 'Name of the contact to remove.'),
      }, requiredProperties: const ['name']),
    ),
    FunctionDeclaration(
      'add_passerby_message',
      'Add a new pre-written message to show a passerby (Passerby Helper overlay).',
      Schema.object(properties: {
        'message': Schema.string(description: 'The message text.'),
      }, requiredProperties: const ['message']),
    ),
    FunctionDeclaration(
      'remove_passerby_message',
      'Remove an existing passerby message that matches the given text.',
      Schema.object(properties: {
        'message': Schema.string(description: 'The message text to remove.'),
      }, requiredProperties: const ['message']),
    ),
    FunctionDeclaration(
      'trigger_emergency',
      "Raise the emergency alarm: message the user's emergency contacts with their location, telephone "
          "their primary contact, and guide them somewhere safer.\n\n"
          "Call this whenever the user appears to be in danger, hurt, frightened, trapped, lost and "
          "distressed, being followed, being taken somewhere against their will, or asking for urgent "
          "help — whether or not they use any particular word. Most such utterances are short, and many "
          "describe what the person CANNOT do: 'I can't get up', 'I can't breathe', 'I can't see anyone', "
          "'আমি নড়তে পারছি না'. Treat those as calls for help, not as refusals.\n\n"
          "This user is blind or has low vision and is walking in Dhaka. They cannot see the screen and "
          "cannot check whether you understood. If they sound like they might be in trouble, call this.\n\n"
          "Do NOT call it for: ordinary requests that merely contain the word help ('can you help me with "
          "the volume'), questions about the feature ('what happens if I say emergency'), managing "
          "contacts ('add my sister as an emergency contact'), or an explicit refusal ('I don't need "
          "help', 'I'm fine'). When the user is clearly asking for a route, a setting or a hazard report, "
          "use that tool instead.\n\n"
          "Erring toward calling this is the right mistake to make. Nothing is sent for five seconds, "
          "during which the user is told what is about to happen and can say 'cancel'. A false alarm "
          "costs them one word; a missed one costs everything.",
      null,
    ),
    // Module 6 — kept in sync with `GroqAssistantService`'s declaration of
    // the same tool, per that class's doc comment. Groq is what actually
    // ships; this path stays as the documented revert route.
    FunctionDeclaration(
      'look_around',
      "Use the camera to see for the user. Call when they ask what is in front of them, which bus or "
          "vehicle this is, what a sign says, whether the path is clear, or whether it is safe to cross. "
          "The user is blind — they cannot aim the camera, so never ask them to point it anywhere.",
      Schema.object(
        properties: {
          'focus': Schema.enumString(
            enumValues: const ['vehicle', 'sign', 'ahead', 'surroundings', 'hazard'],
            description: 'ahead = what is directly in front (one frame, instant) — use this for '
                '"what is in front of me". surroundings = a wide left-ahead-right sweep, only for '
                '"what is around me". vehicle = which bus/rickshaw/CNG. sign = read text. '
                'hazard = is the path walkable.',
          ),
          'question': Schema.string(
            description: "The user's own question, copied as they asked it, when it is more "
                "specific than the focus — e.g. 'what colour is the rabbit', "
                "'what is written on this page'. Omit for a general look.",
          ),
        },
        requiredProperties: const ['focus'],
      ),
    ),
    FunctionDeclaration(
      'open_passerby_helper',
      "Open the full-screen Passerby Helper overlay so a nearby stranger can read a message. Call this when "
          "the user asks to show their screen to someone or get a passerby's attention.",
      null,
    ),
    FunctionDeclaration(
      'open_hazard_report',
      'Open the hazard reporting form. Call this when the user wants to report a hazard, unsafe area, or '
          'accessibility obstruction. If the user already named what the hazard is, pass `category` and '
          '`subCategory` so the form opens straight to it instead of asking them to pick it again — omit '
          'both if they only said "report a hazard", and omit `subCategory` if you are not sure which one '
          'they meant. Never guess: a wrong value files a real report under the wrong hazard type.',
      Schema.object(properties: {
        'category': Schema.enumString(
          enumValues: ['crime', 'roadHazard', 'accessibilityBlock'],
          description: 'The broad kind of hazard, if the user said.',
        ),
        'subCategory': Schema.enumString(
          enumValues: [
            'mugging', 'harassment', 'suspiciousCrowd', 'theftPickpocketing', 'stalking',
            'verbalAbuse', 'physicalAssault', 'poorLighting',
            'pothole', 'flooding', 'construction', 'noSidewalk', 'openManhole',
            'brokenStreetlight', 'recklessTraffic', 'illegalParking', 'debrisFallenTree',
            'brokenRamp', 'blockedPath', 'noCurbCut', 'stairsOnly', 'narrowPassage',
            'noTactilePaving', 'elevatorOutOfService', 'blockedByVendors',
          ],
          description: 'The exact hazard, if the user named it. Must belong to `category`.',
        ),
        // No `requiredProperties` — both are optional, so a bare "report a
        // hazard" still opens the Hub at the top of its menu.
      }),
    ),
    FunctionDeclaration(
      'save_place',
      'Save a place the user goes to often so they can later just say "take me to <label>". Call this '
          'when they ask to remember or save somewhere. Omit `address` to save wherever they are '
          'standing right now — that is the better option whenever they say "here"/"this place", since '
          'many Dhaka locations have no address a map can look up.',
      Schema.object(properties: {
        'label': Schema.string(description: 'What the user calls it — "work", "Ma\'s house", "school".'),
        'address': Schema.string(description: 'A written address, only if the user actually gave one.'),
        'kind': Schema.enumString(
          enumValues: ['home', 'work', 'school', 'family', 'medical', 'worship', 'other'],
          description: 'Rough category, used only to understand synonyms later.',
        ),
      }, requiredProperties: const ['label']),
    ),
    FunctionDeclaration(
      'remove_place',
      'Forget a saved place. Call this when the user asks to remove or delete one of their saved places.',
      Schema.object(properties: {
        'label': Schema.string(description: 'The place to remove, as the user referred to it.'),
      }, requiredProperties: const ['label']),
    ),
    FunctionDeclaration(
      'resolve_hazard',
      'Clear a previously reported hazard on the route the user is currently walking, because they say it '
          'is no longer there (fixed, repaired, cleared away). Only call this when the user is stating the '
          'hazard is gone — never when they are reporting a new one.',
      null,
    ),
    FunctionDeclaration(
      'send_caretaker_message',
      'Send the user\'s paired caretaker a written message in the user\'s own words. Call this '
          'whenever they want something passed on — "tell my caretaker I will be home late", '
          '"let my mum know I got there safely", "message my carer that I am skipping lunch". '
          'Put what they want said into `message`, in their words and their language, not a '
          'summary of it. If they have not said what to pass on yet, ask them first rather than '
          'inventing it. For a bare "let them know I need them" with nothing to say, use '
          'alert_caretaker instead; for danger or injury use trigger_emergency.',
      Schema.object(properties: {
        'message': Schema.string(
          description: 'What the user wants said, in their own words.',
        ),
      }, requiredProperties: const ['message']),
    ),
    FunctionDeclaration(
      'record_caretaker_voice_memo',
      'Open the recorder so the user can send their caretaker a short message in their own '
          'voice. Call this when they ask to record something, to send a voice message or voice '
          'note, or to let their caretaker hear them say it. Use this rather than '
          'send_caretaker_message whenever they have asked for their *voice* specifically — do '
          'not transcribe it for them.',
      null,
    ),
    FunctionDeclaration(
      'alert_caretaker',
      'Tell the user\'s paired caretaker that they want to be checked on, and send them the '
          'user\'s current position. Call this when the user asks to let their caretaker, carer, '
          'guardian or family know something, to alert or notify them, or says they want someone '
          'told where they are. This is NOT an emergency — for danger, injury or a call for help, '
          'use trigger_emergency instead.',
      null,
    ),
    FunctionDeclaration(
      'describe_current_location',
      'Tell the user where they are right now, by name — the road and area they are standing in. '
          'Call this whenever they ask where they are, what road or area this is, or say they are lost '
          'or do not know where they have ended up. This does not plan a route and does not need a '
          'destination; it answers the question "where am I".',
      null,
    ),
    FunctionDeclaration(
      'request_route',
      'Plan a safety-checked walking route from the user\'s current location to a named destination and show it '
          'on the dashboard map. Call this whenever the user asks to go somewhere, be taken somewhere, or asks '
          'for directions/a route — including a bare place name given right after you asked "where do you want '
          'to go?".',
      Schema.object(properties: {
        'destination': Schema.string(
          description: 'The destination as the user described it (e.g. "Gulshan 2", "my office", "New Market").',
        ),
      }, requiredProperties: const ['destination']),
    ),
    FunctionDeclaration(
      'request_alternative_route',
      'Switch to a different walking route to the destination the user is already heading to. Call this '
          'when they ask for another route, a different way, or say they do not like the route you gave '
          'them. Do NOT call this to start a new journey — that is request_route — and do not ask which '
          'alternative they want, there is nothing for them to choose from until they hear it.',
      null,
    ),
    FunctionDeclaration(
      'cancel_route',
      'End the walk the user is currently on and clear the route from the map. Call this when they '
          'say to cancel or stop the trip, or that they are no longer going. This is not '
          'request_alternative_route (same destination, different road) and not replan_route (same '
          'destination, new starting point) — it abandons the journey entirely.',
      null,
    ),
    FunctionDeclaration(
      'remember_about_me',
      'Write down something the user has told you about themselves that is worth keeping for '
          'later — a preference, a limitation, a routine, a name they use for someone. Call this '
          'when they say something durable about themselves in passing ("I can\'t manage stairs", '
          '"I hate crowded markets", "my daughter picks me up on Fridays"), or when they ask you '
          'outright to remember something. Do NOT call it for one-off requests, for anything '
          'already in their profile above, or for where they want to go right now.',
      Schema.object(properties: {
        'note': Schema.string(
          description: 'One short sentence, written from their point of view, e.g. '
              '"Cannot manage stairs" or "Prefers quiet routes".',
        ),
      }, requiredProperties: const ['note']),
    ),
    FunctionDeclaration(
      'forget_about_me',
      'Remove something previously remembered about the user. Call this whenever they ask you to '
          'forget, drop or stop keeping something. Pass a few words of the note to remove; pass '
          'nothing at all only if they ask you to forget everything.',
      Schema.object(properties: {
        'note': Schema.string(description: 'Part of the note to remove.'),
      }),
    ),
    FunctionDeclaration(
      'open_map',
      'Show the map on the dashboard. Call this when the user asks to see, show or open the map '
          '— including in romanised Bangla ("map on koro", "map dekhao"). It does not plan or '
          'change a route and needs no destination.',
      null,
    ),
    FunctionDeclaration(
      'close_map',
      'Hide the map on the dashboard, giving the space back to the chat. Call this when the user '
          'asks to close, hide or put away the map ("map off koro", "map bondho koro"). This does '
          'not cancel their journey — for that, use cancel_route.',
      null,
    ),
    FunctionDeclaration(
      'replan_route',
      'Plan the same journey again from where the user is standing right now. Call this when they say '
          '"re-route", say they have gone the wrong way or come off the route, or ask which way to go from '
          'here while a route is active. This keeps the destination and changes the starting point; '
          'request_alternative_route keeps both and changes the road.',
      null,
    ),
  ];
}
