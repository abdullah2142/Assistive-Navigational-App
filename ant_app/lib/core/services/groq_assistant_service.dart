import 'dart:async';
import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'api_budget.dart';
import '../../features/dashboard/models/chat_message.dart';
import '../../features/dashboard/models/hazard_report.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../config/groq_config.dart';
import '../localization/app_language.dart';
import 'destination_clarifier.dart';
import 'function_call_executor.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'pending_place_save.dart';
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

/// Thrown when this month's assistant call ceiling is spent.
///
/// Same role as the old `GeminiBudgetExhausted` — kept as a distinct type so
/// the failure is legible in a log rather than a generic exception, even
/// though Groq's free tier costs nothing: the cap here approximates Groq's
/// own daily rate limit (1,000 requests/day) rather than a dollar ceiling,
/// see `BillableApi.gemini` in `api_budget.dart`.
class AssistantBudgetExhausted implements Exception {
  const AssistantBudgetExhausted();

  @override
  String toString() =>
      'AssistantBudgetExhausted: this month\'s assistant call ceiling is spent '
      '(see BillableApi.gemini). Falling back to the offline matcher.';
}

/// [GeminiAssistantService]'s replacement: the same prompt, the same 24
/// function declarations (translated to OpenAI's tool-call JSON shape,
/// which Groq's `/chat/completions` endpoint speaks), the same
/// [AssistantTurn] contract — only the network layer and the underlying
/// model changed, from `gemini-3.6-flash` to Groq's `qwen/qwen3.8-27b`
/// (see `GroqConfig.chatModel` for why).
///
/// Deliberately not a rewrite of `GeminiAssistantService` in place: that
/// class (and its tests) stays as a record of the Gemini integration and an
/// easy revert path if Groq's free tier ever stops being viable. Everything
/// duplicated below (the system prompt, the tool list) must be kept in sync
/// with `GeminiAssistantService` if either changes deliberately — they are
/// two independent implementations of the same behaviour, not one shared
/// with a thin adapter, because Gemini's `Schema`/`FunctionDeclaration`
/// types and OpenAI's raw-JSON tool schema aren't compatible enough to
/// share a builder without obscuring both.
class GroqAssistantService {
  GroqAssistantService({
    required String apiKey,
    required FunctionCallExecutor executor,
    ApiBudget? budget,
    http.Client? client,
  })  : _apiKey = apiKey,
        _executor = executor,
        _budget = budget ?? defaultApiBudget,
        _client = client ?? http.Client();

  final String _apiKey;
  final FunctionCallExecutor _executor;
  final ApiBudget _budget;
  final http.Client _client;

  // Trimmed from 8 (Gemini's figure) — every point here comes straight off
  // the per-call input-token budget that Groq's free tier meters by the
  // minute (see `_sendWithRetry`'s doc comment), unlike Gemini's much larger
  // per-minute allowance where 8 cost nothing extra in practice.
  static const int _historyTurns = 5;

  Future<AssistantTurn> converse({
    required String userText,
    required UserProfile profile,
    required List<ChatMessage> recentHistory,
    Position? location,
    void Function(String partialText)? onPartialText,
    RouteChoice? activeRoute,
    List<RouteCandidate> routeAlternatives = const [],
  }) async {
    if (!await _budget.tryConsume(BillableApi.gemini)) {
      throw const AssistantBudgetExhausted();
    }

    final messages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': _buildPrompt(profile: profile, location: location),
      },
      ..._historyToMessages(recentHistory),
      {'role': 'user', 'content': userText},
    ];

    final streamed = await _sendWithRetry(messages);

    final textBuffer = StringBuffer();
    // Keyed by the streamed tool-call index — Groq (like OpenAI) streams a
    // tool call's name and arguments as separate incremental chunks rather
    // than one complete object, so each has to be accumulated before it can
    // be parsed.
    final toolCalls = <int, _StreamingToolCall>{};

    await for (final line in streamed.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data: ')) continue;
      final payload = line.substring(6).trim();
      if (payload == '[DONE]') break;
      if (payload.isEmpty) continue;

      final Map<String, dynamic> chunk;
      try {
        chunk = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }
      final choices = chunk['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) continue;
      final delta = choices.first['delta'] as Map<String, dynamic>?;
      if (delta == null) continue;

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        textBuffer.write(content);
        if (toolCalls.isEmpty) onPartialText?.call(textBuffer.toString());
      }

      final deltaCalls = delta['tool_calls'] as List<dynamic>?;
      if (deltaCalls != null) {
        for (final raw in deltaCalls) {
          final call = raw as Map<String, dynamic>;
          final index = call['index'] as int? ?? 0;
          final entry = toolCalls.putIfAbsent(index, () => _StreamingToolCall());
          final function = call['function'] as Map<String, dynamic>?;
          if (function != null) {
            final name = function['name'] as String?;
            if (name != null) entry.name = name;
            final args = function['arguments'] as String?;
            if (args != null) entry.argumentsJson.write(args);
          }
        }
      }
    }

    if (toolCalls.isEmpty) {
      return AssistantTurn(responseText: _textOrFallback(textBuffer.toString(), profile));
    }

    var workingProfile = profile;
    SuggestedChipAction? overlay;
    RouteChoice? route;
    List<RouteCandidate>? alternatives;
    HazardReportPrefill? hazardPrefill;
    DestinationClarification? clarification;
    PendingPlaceSave? placeSave;
    final confirmations = <String>[];

    for (final entry in toolCalls.values) {
      final name = entry.name;
      if (name == null) continue;
      Map<String, dynamic> args;
      try {
        final raw = entry.argumentsJson.toString();
        args = raw.trim().isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        args = {};
      }

      final applied = await _executor.execute(
        name: name,
        args: args,
        profile: workingProfile,
        location: location,
        activeRoute: route ?? activeRoute,
        routeAlternatives: alternatives ?? routeAlternatives,
      );
      workingProfile = applied.updatedProfile ?? workingProfile;
      overlay ??= applied.overlayAction;
      if (applied.route != null) route = applied.route;
      if (applied.routeAlternatives != null) alternatives = applied.routeAlternatives;
      hazardPrefill ??= applied.hazardPrefill;
      clarification ??= applied.clarification;
      placeSave ??= applied.placeSave;
      confirmations.add(applied.responseText);
    }

    return AssistantTurn(
      responseText: confirmations.join(' '),
      updatedProfile: identical(workingProfile, profile) ? null : workingProfile,
      overlayAction: overlay,
      route: route,
      routeAlternatives: alternatives,
      hazardPrefill: hazardPrefill,
      clarification: clarification,
      placeSave: placeSave,
    );
  }

  /// Sends the chat-completion request, retrying once on a 429.
  ///
  /// Confirmed live (2026-09-17 tester log, `qwen/qwen3.8-27b`): Groq's free
  /// tier caps this model at 7,000 input tokens/minute, and a single turn
  /// here — system prompt plus all 24 tool declarations plus history — costs
  /// ~5,000-5,300 input tokens. That leaves room for barely more than one
  /// call a minute, and roughly half of every tester's turns in that log
  /// died outright with `rate_limit_exceeded` and no retry — the assistant
  /// simply went silent, repeatedly, mid-conversation.
  ///
  /// Groq's error body names the exact wait (`"Please try again in
  /// 14.9s"`), so rather than a blind exponential backoff this parses that
  /// and waits almost exactly that long once, then retries — turning a dead
  /// turn into a slow one. Capped at 20s so a worst-case rate-limit window
  /// doesn't hang the whole chat UI indefinitely; past that, this throws and
  /// the caller falls back to the offline matcher exactly as it does for
  /// [AssistantBudgetExhausted].
  Future<http.StreamedResponse> _sendWithRetry(List<Map<String, dynamic>> messages, {bool isRetry = false}) async {
    final request = http.Request('POST', Uri.parse('${GroqConfig.baseUrl}/chat/completions'))
      ..headers.addAll({
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'model': GroqConfig.chatModel,
        'messages': messages,
        'tools': _tools,
        'temperature': 0.4,
        'max_completion_tokens': 1024,
        'stream': true,
      });

    final streamed = await _client.send(request);
    if (streamed.statusCode == 429 && !isRetry) {
      final body = await streamed.stream.bytesToString();
      final wait = _parseRetryAfter(body);
      if (wait != null && wait <= const Duration(seconds: 20)) {
        await Future<void>.delayed(wait);
        return _sendWithRetry(messages, isRetry: true);
      }
      throw Exception('Groq chat completion failed (429): $body');
    }
    if (streamed.statusCode >= 400) {
      final body = await streamed.stream.bytesToString();
      throw Exception('Groq chat completion failed (${streamed.statusCode}): $body');
    }
    return streamed;
  }

  /// Pulls the wait time out of Groq's own error message — e.g. "Please try
  /// again in 14.957142857s" — rather than guessing a backoff. Returns null
  /// if the body doesn't have the expected shape, so the caller can fail
  /// straight to the fallback rather than waiting on a guess.
  static Duration? _parseRetryAfter(String errorBody) {
    final match = RegExp(r'try again in ([\d.]+)s').firstMatch(errorBody);
    if (match == null) return null;
    final seconds = double.tryParse(match.group(1)!);
    if (seconds == null) return null;
    // A small buffer over the server's own figure — retrying at exactly the
    // quoted instant landed on the boundary and failed again live.
    return Duration(milliseconds: (seconds * 1000).round() + 250);
  }

  String _textOrFallback(String? text, UserProfile profile) {
    final trimmed = text?.trim() ?? '';
    if (trimmed.isNotEmpty) return trimmed;
    return profile.language == AppLanguage.bangla ? 'ঠিক আছে।' : 'Got it.';
  }

  List<Map<String, dynamic>> _historyToMessages(List<ChatMessage> history) {
    final recent = history.length > _historyTurns ? history.sublist(history.length - _historyTurns) : history;
    return recent
        .map((m) => {
              'role': m.sender == ChatSender.user ? 'user' : 'assistant',
              'content': m.text,
            })
        .toList();
  }

  /// Identical prompt to `GeminiAssistantService.buildPrompt` — see that
  /// method for the reasoning behind every rule. Kept in this file (not
  /// shared) per this class's doc comment.
  static String _buildPrompt({
    required UserProfile profile,
    Position? location,
  }) {
    final bn = profile.language == AppLanguage.bangla;
    final locationLine = location == null
        ? 'Not available right now.'
        : '${location.latitude.toStringAsFixed(5)}, ${location.longitude.toStringAsFixed(5)}';

    return '''
You are ANT, a calm, safety-focused navigational assistant for a disabled person living in Dhaka. Be warm but brief.

Profile: vision=${profile.visionLevel.name}, mobility=${profile.mobilityAid.name}, deaf/hoh=${profile.isDeafOrHardOfHearing}, crowd-anxious=${profile.crowdedPlacesAnxious}, complex-instructions-hard=${profile.complexInstructionsHard}, reply=${profile.verbosity.name} (minimalist=one short sentence; descriptive=a bit more, still concise), snapshot=${profile.snapshotConsent.name}, has-caretaker=${profile.pairedUserId != null}
${profile.magicButtonContacts.isEmpty ? '' : '''
Saved contacts (real, readable, never claim unavailable): ${profile.magicButtonContacts.map((c) => '${c.name}${c.relationship.isEmpty ? '' : ' (${c.relationship})'}: ${c.phoneNumber}').join('; ')}'''}
${profile.savedPlaces.isEmpty ? '' : '''
Saved places: ${profile.savedPlaces.map((p) => '${p.label}${p.address.isEmpty ? '' : ' (${p.address})'}').join('; ')}'''}
${profile.rememberedNotes.isEmpty ? '' : '''
Remembered about this user (treat as true, don't re-ask): ${profile.rememberedNotes.join('; ')}'''}
Live location (may be null — never invent one): $locationLine
Available now: safety-checked walking routes (request_route). Camera scanning and auto emergency-dispatch are NOT built yet — say so if asked, don't pretend.

Rules:
- Never claim to know the state of something you can't read (screen/camera/mic/connection). A half-heard command ("Screen.") is a clarify-request, not a cue to invent a status.
- ALWAYS reply in ${bn ? 'Bangla' : 'English'} regardless of the user's language, unless they ask you to switch. Minimalist style = one short plain sentence.
- 6-digit code + not yet paired → pair_with_caretaker. Want to pair, no code yet → ask for it.
- Setting change requested (text size, theme, language, verbosity, voice, vision level, mobility aid, deaf/hearing mode, snapshot, crowd/complex sensitivity, addresses, wake word) → call update_setting, don't just claim it. `theme` is ONLY "light"/"dark" — never invent a colour menu (red/blue/green etc.); that feature doesn't exist.
- Show passerby message / report hazard → call the matching function.
- Go somewhere / directions / a bare place name right after you asked where → request_route with that destination. Already on a route, wants a different road → request_alternative_route. Came off route / "re-route" / "which way from here" → replan_route.
- Real emergency → tell them to use the Magic Button or call for help directly; you can't dial for them yet.
- Caretaker should be told something → send_caretaker_message (their own words). Wants to be checked on, nothing specific to say → alert_caretaker. Wants to send their own voice → record_caretaker_voice_memo.
- "Where am I" / lost → describe_current_location. Never guess a street from raw coordinates.
- Show/hide map → open_map/close_map (not a route action).
- Durable personal fact in passing → remember_about_me. Asked to forget → forget_about_me. Never claim to remember without calling it.
- Use earlier messages (this session and past ones) — don't re-ask what's already known, and don't contradict what you yourself already said earlier this session; if you would, trust the more recent statement and stay consistent.
- No contact book / address lookup exists. Never say a number "isn't saved with me" (implies it might be) — say plainly you can't look it up. add_emergency_contact is for adding a Magic Button contact, not looking one up.
- No live POI/business database — not even for places you already routed to. Never invent specifics for "what's around here" — say you don't have that data rather than guessing plausibly.
- If the user asserts a fact about their own location/area and you lack strong contrary evidence, defer after at most one clarifying attempt — don't re-argue it.
- Never name a specific business/restaurant/shop yourself — you have no directory, so any name you produce is a guess. For "somewhere to eat for X taka" etc., don't suggest a name in prose — call request_route with the descriptive phrase (destination, budget, kind of place) and let the router find/name a real one.
- Act on the need, not the literal words: "I need to poop"/"my stomach hurts" → route to nearest toilet; "thirsty"/"need to sit"/"phone dying"/"need medicine" → route to whatever kind of place solves it.
- "The nearest X" already names what they want — call request_route with the whole phrase (incl. "nearest"); never list options first.
- Be a guardian, not only a map: if they're unsure/uncomfortable/asking advice, answer that before offering a route.
- Ask only when it changes what you'd do — one short question, never a list, never when a sensible default exists.
- Never confirm a route request twice. Need is already clear (urgent, named destination, or they already said yes) → call request_route immediately; asking again reads as not having heard them.
- destination must trace back to something the user actually said — never a placeholder like "another place" just to produce a call; if you don't know where, ask.
''';
  }

  /// Same 24 tools as `GeminiAssistantService._tools`, in OpenAI's
  /// `{type: "function", function: {...}}` tool-call shape.
  static final List<Map<String, dynamic>> _tools = [
    _tool('pair_with_caretaker', 'Link to a caretaker via the 6-digit code they gave. Only if not already paired.',
        properties: {'code': _str('The 6-digit pairing code.')}, required: ['code']),
    _tool('update_setting', 'Change one accessibility/app setting.',
        properties: {
          'setting': _enumStr(
            const [
              'text_size', 'theme', 'language', 'verbosity', 'voice', 'vision_level', 'mobility_aid',
              'deaf_hearing_mode', 'snapshot_consent', 'crowded_places_anxious', 'complex_instructions_hard',
              'home_address', 'safe_place_address', 'wake_word_enabled', 'voice_auto_listen',
            ],
            'Which setting.',
          ),
          'value': _str('text_size: "0.8"-"2.0". theme: "light"/"dark" (only these two). language: '
              '"english"/"bangla". verbosity: "minimalist"/"descriptive". voice: e.g. "bn-BD-female-1". '
              'vision_level: "none"/"low"/"full". mobility_aid: "whiteCane"/"wheelchair"/"unassisted". '
              'deaf_hearing_mode, crowded_places_anxious, complex_instructions_hard, wake_word_enabled, '
              'voice_auto_listen: "true"/"false". snapshot_consent: "always"/"askEachTime"/"never". '
              'home_address/safe_place_address: free text.'),
        },
        required: ['setting', 'value']),
    _tool('add_emergency_contact', 'Add a Magic Button emergency contact.',
        properties: {'name': _str('Name.'), 'phone': _str('Phone number.')}, required: ['name', 'phone']),
    _tool('remove_emergency_contact', 'Remove an emergency contact by name.',
        properties: {'name': _str('Contact to remove.')}, required: ['name']),
    _tool('add_passerby_message', 'Add a pre-written passerby message.',
        properties: {'message': _str('Message text.')}, required: ['message']),
    _tool('remove_passerby_message', 'Remove a passerby message matching the given text.',
        properties: {'message': _str('Message text to remove.')}, required: ['message']),
    _tool(
      'trigger_emergency',
      "Raise the emergency alarm: message contacts with location, call the primary one, route somewhere "
          "safer. Call for danger, injury, fear, being trapped/followed/taken against their will, or urgent "
          "help — any wording, including short 'can't' phrases ('I can't get up', 'আমি নড়তে পারছি না') "
          "treated as calls for help, not refusals. This user is blind/low-vision and can't check if you "
          "understood, so err toward calling this. Do NOT call for: incidental use of the word 'help', "
          "questions about the feature, managing contacts, or explicit refusal ('I'm fine'). Nothing sends "
          "for 5s and the user can say 'cancel'.",
    ),
    _tool('open_passerby_helper', 'Open the Passerby Helper overlay for a nearby stranger to read.'),
    _tool(
      'open_hazard_report',
      'Open the hazard report form. Pass category/subCategory only if the user already named the hazard '
          '(never guess); omit either you\'re unsure of.',
      properties: {
        'category': _enumStr(const ['crime', 'roadHazard', 'accessibilityBlock'], 'Broad kind, if said.'),
        'subCategory': _enumStr(
          const [
            'mugging', 'harassment', 'suspiciousCrowd', 'theftPickpocketing', 'stalking', 'verbalAbuse',
            'physicalAssault', 'poorLighting', 'pothole', 'flooding', 'construction', 'noSidewalk',
            'openManhole', 'brokenStreetlight', 'recklessTraffic', 'illegalParking', 'debrisFallenTree',
            'brokenRamp', 'blockedPath', 'noCurbCut', 'stairsOnly', 'narrowPassage', 'noTactilePaving',
            'elevatorOutOfService', 'blockedByVendors',
          ],
          'Exact hazard, must belong to category.',
        ),
      },
    ),
    _tool(
      'save_place',
      'Save a frequent place ("take me to <label>" later). Omit address to mean "here" — right for '
          '"here"/"this place" since many Dhaka spots have none.',
      properties: {
        'label': _str('e.g. "work", "school".'),
        'address': _str('Only if actually given.'),
        'kind': _enumStr(const ['home', 'work', 'school', 'family', 'medical', 'worship', 'other'], 'Rough category.'),
      },
      required: ['label'],
    ),
    _tool('remove_place', 'Forget a saved place.', properties: {'label': _str('Place to remove.')}, required: ['label']),
    _tool('resolve_hazard', 'Clear a reported hazard on the active route because it\'s gone — never for a new report.'),
    _tool(
      'send_caretaker_message',
      'Send the paired caretaker a written message in the user\'s own words/language — never a summary. '
          'If they haven\'t said what to pass on, ask first. Nothing to say → alert_caretaker. '
          'Danger/injury → trigger_emergency.',
      properties: {'message': _str('What they want said, in their words.')},
      required: ['message'],
    ),
    _tool('record_caretaker_voice_memo',
        'Open the recorder for a voice message to the caretaker — use when they ask for their own *voice* specifically, not a transcription.'),
    _tool('alert_caretaker',
        'Tell the paired caretaker to check on them, with current position. NOT an emergency — for danger use trigger_emergency.'),
    _tool('describe_current_location',
        'Say where they are by road/area name — "where am I". No route, no destination. Never guess a street from raw coordinates.'),
    _tool(
      'request_route',
      'Plan+show a safety-checked walking route to a named destination. Use for "go somewhere"/directions, '
          'or a bare place right after you asked where.',
      properties: {'destination': _str('As described, e.g. "Gulshan 2", "my office".')},
      required: ['destination'],
    ),
    _tool('request_alternative_route',
        'Switch to a different road to the SAME destination already active. Not for a new journey (request_route). Never ask which alternative — nothing to choose from yet.'),
    _tool('cancel_route',
        'End the current walk entirely and clear the map. Distinct from request_alternative_route (same dest, new road) and replan_route (same dest, new start).'),
    _tool(
      'remember_about_me',
      'Save a durable fact about the user (preference/limitation/routine) said in passing, or on request. '
          'Not for one-off asks or anything already in their profile.',
      properties: {'note': _str('One short sentence, their point of view.')},
      required: ['note'],
    ),
    _tool('forget_about_me', 'Remove a previously remembered note.',
        properties: {'note': _str('Words identifying the note; omit only to forget everything.')}),
    _tool('open_map', 'Show the dashboard map (incl. romanised Bangla "map dekhao"). No route change, no destination.'),
    _tool('close_map', 'Hide the map, give space back to chat. Does not cancel the journey — use cancel_route for that.'),
    _tool('replan_route',
        'Re-plan the SAME destination from where they stand now ("re-route", off-route, "which way from here"). Keeps destination, changes start — unlike request_alternative_route (keeps both, changes road).'),
  ];

  static Map<String, dynamic> _tool(
    String name,
    String description, {
    Map<String, dynamic>? properties,
    List<String>? required,
  }) {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {
          'type': 'object',
          'properties': properties ?? <String, dynamic>{},
          if (required != null && required.isNotEmpty) 'required': required,
        },
      },
    };
  }

  static Map<String, dynamic> _str(String description) => {'type': 'string', 'description': description};

  static Map<String, dynamic> _enumStr(List<String> values, String description) =>
      {'type': 'string', 'enum': values, 'description': description};
}

class _StreamingToolCall {
  String? name;
  final StringBuffer argumentsJson = StringBuffer();
}
