import 'package:geolocator/geolocator.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

import '../../features/dashboard/models/chat_message.dart';
import '../../features/dashboard/models/hazard_report.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../config/gemini_config.dart';
import '../localization/app_language.dart';
import 'destination_clarifier.dart';
import 'function_call_executor.dart';
import 'route_planning_service.dart';

/// One completed exchange: what to show/speak, and any side effects the
/// model (or, since `LocalIntentMatcher` was added, a plain local pattern
/// match — see `FunctionCallExecutor`) asked for.
class AssistantTurn {
  const AssistantTurn({
    required this.responseText,
    this.updatedProfile,
    this.overlayAction,
    this.route,
    this.hazardPrefill,
    this.clarification,
  });

  final String responseText;

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

  /// Non-null when the hazard-report overlay was opened by a command that
  /// already named the hazard ("report an open manhole") — the Hub opens
  /// straight to that hazard instead of at the top of its menu.
  final HazardReportPrefill? hazardPrefill;

  /// Non-null when the assistant just asked the user where a destination
  /// actually is, and is waiting for the answer.
  final DestinationClarification? clarification;
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
class GeminiAssistantService {
  GeminiAssistantService({required String apiKey, required FunctionCallExecutor executor})
      : _model = GenerativeModel(
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
  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    /// The route the user is currently walking, if any — `resolve_hazard`
    /// is scoped to the hazards on it. See `FunctionCallExecutor`.
    RouteChoice? activeRoute,
  }) async {
    final contents = <Content>[
      ..._historyToContents(recentHistory),
      Content.text(_buildPrompt(userText: userText, profile: profile, location: location)),
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
    HazardReportPrefill? hazardPrefill;
    DestinationClarification? clarification;
    final confirmations = <String>[];
    for (final call in calls) {
      final applied = await _executor.execute(
        name: call.name,
        args: call.args,
        profile: workingProfile,
        location: location,
        activeRoute: activeRoute,
      );
      workingProfile = applied.updatedProfile ?? workingProfile;
      overlay ??= applied.overlayAction;
      route ??= applied.route;
      hazardPrefill ??= applied.hazardPrefill;
      clarification ??= applied.clarification;
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
      hazardPrefill: hazardPrefill,
      clarification: clarification,
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

  String _buildPrompt({required String userText, required UserProfile profile, Position? location}) {
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

Live location (may be stale or unavailable — never invent one if missing): $locationLine
Current app state: safety-weighted walking-route planning is available (call request_route). Live camera hazard/bus-sign scanning and emergency auto-dispatch are separate modules that are not deployed yet — if asked for those, say so briefly and don't pretend to do them.

Rules:
- ALWAYS reply in ${bn ? 'Bangla' : 'English'}, regardless of what language the user's message is in, unless they explicitly ask you to switch.
- If reply style is minimalist, answer in one short plain sentence.
- If the user (not already paired) gives you a 6-digit code to link up with their caretaker, or asks to add/pair with a caretaker and mentions a code, call pair_with_caretaker. If they want to pair but haven't given a code yet, ask them for the 6-digit code their caretaker's app shows.
- If the user is asking to change any setting (text size, theme, UI language, reply style, voice, vision level, mobility aid, deaf/hearing mode, snapshot permission, crowded/complex sensitivity, home or safe-place address, emergency contacts, passerby messages, the "Hey ANT" wake word), call the matching function instead of just claiming you did it.
- If the user wants to show a message to a passerby, or report a hazard, call the matching trigger function.
- If the user wants to go somewhere, asks for directions, or (right after you asked where they want to go) names a place, call request_route with that destination.
- For a real emergency, tell them to use the physical Magic Button or call for help directly — you cannot dial or send messages on their behalf yet.

User's message: "$userText"
''';
  }

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
          description: 'The new value. text_size: a number as text between "0.8" and "2.0". '
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
      'Add a new Magic Button emergency contact.',
      Schema.object(properties: {
        'name': Schema.string(description: "Contact's name."),
        'phone': Schema.string(description: "Contact's phone number."),
      }, requiredProperties: const ['name', 'phone']),
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
  ];
}
