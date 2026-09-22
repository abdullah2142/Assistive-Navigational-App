import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import 'api_budget.dart';
import 'assistant_service.dart';
import '../../features/dashboard/models/chat_message.dart';
import '../../features/dashboard/models/hazard_report.dart';
import '../../features/dashboard/models/suggested_chip.dart';
import '../../features/onboarding/models/user_profile.dart';
import '../config/groq_config.dart';
import '../localization/app_language.dart';
import 'destination_clarifier.dart';
import 'function_call_executor.dart';
import 'gemini_assistant_service.dart' show AssistantTurn;
import 'vision/vision_scene.dart' show ScanFocus;
import 'pending_place_save.dart';
import 'route_planning_service.dart';
import 'routing_service.dart' show RouteCandidate;

// The named parameters below are deliberately not initializing formals:
// they are named for the caller ('store', 'tts') while the fields are
// private ('_store', '_tts'), which is the convention across this
// codebase and what makes the constructors readable at the call site.
// ignore_for_file: prefer_initializing_formals

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
class GroqAssistantService implements AssistantService {
  @override
  String get backendName => 'groq:${GroqConfig.chatModel}';

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

  @override
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
      _locationMessage(location),
      {'role': 'user', 'content': userText},
    ];

    final selectedTools = _getRelevantTools(userText);
    final selectedToolCount = selectedTools.length;

    final streamed = await _sendWithRetry(messages, selectedTools);

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
      // The usage chunk arrives last and carries no choices, so it has to be
      // read before the `choices` guard below drops it.
      //
      // This is the only ground truth about what a turn costs. Everything
      // else — the prompt trimming, the tool filtering, the cache ordering —
      // is aimed at a number nobody had measured, and the one estimate that
      // did exist was out by a factor of four.
      final usage = chunk['usage'] as Map<String, dynamic>?;
      if (usage != null) {
        final prompt = usage['prompt_tokens'];
        final completion = usage['completion_tokens'];
        // Groq reports cached prefix tokens separately when a cache hit
        // happens; those do not count against the per-minute limit, so the
        // gap between `prompt` and `cached` is what the rate limiter sees.
        final details = usage['prompt_tokens_details'] as Map<String, dynamic>?;
        final cached = details?['cached_tokens'] ?? 0;
        debugPrint('[Groq] tokens: prompt=$prompt (cached=$cached, '
            'billed≈${prompt is int && cached is int ? prompt - cached : '?'}) '
            'completion=$completion tools=$selectedToolCount');
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
    ScanFocus? scanFocus;
    String? scanQuestion;
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
      scanFocus ??= applied.scanFocus;
      scanQuestion ??= applied.scanQuestion;
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
      scanFocus: scanFocus,
      scanQuestion: scanQuestion,
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
  Future<http.StreamedResponse> _sendWithRetry(List<Map<String, dynamic>> messages, List<Map<String, dynamic>> selectedTools, {bool isRetry = false}) async {
    final request = http.Request('POST', Uri.parse('${GroqConfig.baseUrl}/chat/completions'))
      ..headers.addAll({
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({
        'model': GroqConfig.chatModel,
        'messages': messages,
        'tools': selectedTools,
        'temperature': 0.4,
        'max_completion_tokens': 1024,
        'stream': true,
        // Makes Groq append a final chunk carrying `usage` — without this a
        // streamed response reports nothing, and the only figure anyone has
        // is arithmetic over the request body.
        //
        // That arithmetic has already been wrong once: the payload was
        // believed to be ~5k tokens a turn, and measuring the serialised body
        // put it between 800 and 1,400. Which of those is right decides
        // whether this app gets one request a minute or six, so it is worth
        // hearing from the only party that actually counts — and cached
        // prefix tokens, which do not bill against TPM, are only visible
        // here.
        'stream_options': {'include_usage': true},
      });

    final streamed = await _client.send(request);
    if (streamed.statusCode == 429 && !isRetry) {
      final body = await streamed.stream.bytesToString();
      final wait = _parseRetryAfter(body);
      if (wait != null && wait <= const Duration(seconds: 20)) {
        await Future<void>.delayed(wait);
        return _sendWithRetry(messages, selectedTools, isRetry: true);
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
  /// The **stable** half of the prompt. Nothing that changes turn-to-turn
  /// may be added here.
  ///
  /// The live GPS fix used to be the last line of this string, at five
  /// decimal places — roughly one metre, so it differed on essentially every
  /// turn. Tool declarations and the system prompt render into the head of
  /// the token sequence, which means one volatile line at the top made the
  /// entire prefix behind it uncacheable: the tools, the rules, all of it.
  /// That is the mechanism behind `cached=0` on all 208 token lines of the
  /// 22 September session, and behind the per-minute budget being spent on
  /// tokens that were identical to the previous turn's.
  ///
  /// It now rides in its own message at the **end** of the conversation —
  /// see [_locationMessage] — where a change invalidates nothing in front of
  /// it. The profile lines stay because they change when the user changes a
  /// setting, which is rare and is a real prefix change.
  static String _buildPrompt({
    required UserProfile profile,
    Position? location,
  }) {
    final bn = profile.language == AppLanguage.bangla;

    return '''
You are ANT, a navigational assistant for a disabled person in Dhaka. Be brief.

Rules:
- ALWAYS reply in ${bn ? 'Bangla' : 'English'}. Be very concise.
- Unsure/half-heard input -> clarify, NEVER guess status.
- Want to go somewhere/directions -> request_route immediately, no double checking.
- Need toilet/medicine/rest -> request_route to nearest appropriate place.
- Emergency/fear/danger -> trigger_emergency.
- Caretaker memo -> send_caretaker_message. General check -> alert_caretaker.
- Where am I -> describe_current_location. Do not guess street names from coords.
- Setting changes -> update_setting. (theme is only light/dark).
  This includes turning the wake word or auto-listen off, in either language.
- Save/forget fact -> remember_about_me / forget_about_me.
  "What do you know about me" -> read back the notes you were given above.
- ANYTHING about what is visible -> look_around. Colour, text on a sign or a
  page, what an object is, how many there are, what is ahead. You have a
  camera; never answer such a question from imagination and never refuse it
  by saying you are a navigation assistant.
- The user STATING a hazard ("there is a manhole here", "the footpath is
  blocked") is a report, not a question -> open_hazard_report. They are
  telling you so the next person is warned.
- You can hold an ordinary conversation. A question that needs no tool gets a
  short, direct, friendly answer. Refusing to engage because it is not about
  navigation is wrong.
- No live POI database exists. Don't invent specific businesses.
- If your own last message asked the user a question, read their reply as the
  ANSWER to it. A word in an answer is not a command: "dangerous" replying to
  "is it safe?" is a description, not a hazard report. A clear new instruction
  is still an instruction.

Profile: vision=${profile.visionLevel.name}, mobility=${profile.mobilityAid.name}, deaf/hoh=${profile.isDeafOrHardOfHearing}, crowd-anxious=${profile.crowdedPlacesAnxious}, reply=${profile.verbosity.name}, paired=${profile.pairedUserId != null}
${profile.magicButtonContacts.isEmpty ? '' : 'Contacts: ${profile.magicButtonContacts.map((c) => '${c.name}: ${c.phoneNumber}').join('; ')}'}
${profile.savedPlaces.isEmpty ? '' : 'Saved places: ${profile.savedPlaces.map((p) => p.label).join('; ')}'}
${profile.rememberedNotes.isEmpty ? '' : 'What you know about this user:\n${profile.rememberedNotes.map((n) => '- $n').join('\n')}'}
''';
  }

  /// The volatile half: where the user is right now.
  ///
  /// Placed immediately before the user's own turn so everything ahead of it
  /// — system rules and the full tool list, ~2,400 tokens — stays a stable,
  /// cacheable prefix. Sent as a `system` message rather than folded into the
  /// user's text so it cannot be mistaken for something they said.
  static Map<String, dynamic> _locationMessage(Position? location) => {
        'role': 'system',
        'content': location == null
            ? 'Live location: Not available right now.'
            : 'Live location: ${location.latitude.toStringAsFixed(5)}, '
                '${location.longitude.toStringAsFixed(5)}',
      };

  /// The keywords that put each group of tools in front of the model.
  ///
  /// ## Why this is a table and not a chain of `if`s
  ///
  /// The first version was Latin-only, and measuring it against the 119 real
  /// utterances in `ant-diagnostics-*.txt` showed what that costs:
  ///
  ///     Bangla script   76 utterances   100% fell to the 3-tool fallback
  ///     Latin           43 utterances    48% fell to the 3-tool fallback
  ///
  /// **Every single Bangla utterance** got only `describe_current_location`,
  /// `alert_caretaker` and `trigger_emergency`. So on this app's primary
  /// language the model could not route, change a setting, save a place or
  /// open the map — not because it failed to understand, but because the
  /// tools were never offered. `ইবনে সিনার রাস্তা দেখাও` ("show me the way
  /// to Ibn Sina") got no `request_route`; `ম্যাপ টা বন্ধ করো` got no
  /// `close_map`; `লেখারো বরো করো` got no `update_setting`.
  ///
  /// `LocalIntentMatcher` hides some of this — it catches the map and
  /// text-size phrasings before the model is reached — which is very likely
  /// why it looked fine in testing. A named destination in Bangla is exactly
  /// the case that has to reach the model.
  ///
  /// ## Matching rules
  ///
  /// Latin terms are matched as **whole words**, via `containsTerm`. The
  /// substring version fired `go` inside "mango", `add` inside "address" and
  /// `set` inside "sunset" — the same trap this codebase has documented three
  /// times ("no" in "know", "male" in "female", `না` in নারায়ণগঞ্জ).
  ///
  /// Bangla terms stay **substring** matches, deliberately. Bangla attaches
  /// postpositions and case endings directly to the stem — `ম্যাপ` becomes
  /// `ম্যাপটা`, `রাস্তা` becomes `রাস্তায়` — so whole-word matching would miss
  /// most real sentences. `_mishearable` in `local_intent_matcher.dart` makes
  /// the same choice for the same reason.
  ///
  /// Over-inclusion costs tokens; under-inclusion costs the feature. When a
  /// term is ambiguous, it goes in.
  /// Every tool, on every turn, in a fixed order.
  ///
  /// ## Why the keyword filter is gone
  ///
  /// It decided what the assistant was *capable* of from a hand-written list
  /// of trigger words, and a list of trigger words cannot enumerate how
  /// people talk. It had already been patched twice for exactly this — the
  /// first version was Latin-only and dropped **100% of Bangla utterances**
  /// to a three-tool fallback — and the 22 September session shows the same
  /// failure again in new clothes, measured straight off the device log:
  ///
  /// | what was said | tools offered | what was missing |
  /// |---|---|---|
  /// | "what colour is the rabbit" | 4 | `look_around` — so it cannot use the camera and answers that it is a navigation assistant |
  /// | "what is written on this file" | 4 | `look_around` |
  /// | "what do you know about me" | 4 | `remember_about_me`, `forget_about_me` |
  /// | "there is a manhole in front of me" | 5 | `open_hazard_report` — it can look, but cannot report |
  /// | "the sidewalk is blocked" | 4 | `open_hazard_report` |
  /// | "হেই অ্যান্ট বন্ধ করো" (turn off Hey ANT) | 11 | `update_setting` |
  ///
  /// `tools=4` appears **68 times** in that session, more than any other
  /// value. Each of those turns is one where the model was asked to do
  /// something and had not been handed the tool for it — which reads to the
  /// user as a feature that used to work and stopped.
  ///
  /// ## Why sending all of them is also the cheaper option
  ///
  /// The filter existed to stay under Groq's input-token window. It was
  /// defeating the mechanism that actually solves that problem.
  ///
  /// Groq bills the per-minute window on **uncached** prefix tokens, and a
  /// prefix is only cacheable if it is byte-identical to the last one. Tool
  /// declarations render into the head of the prompt, so a tool list that
  /// changes with the user's wording changes the prefix on every turn and
  /// nothing downstream of it can ever be cached. The fixed `_coreTools`
  /// head was an attempt to keep part of it stable; it could not work,
  /// because the system prompt in front of it was volatile too (see
  /// [_buildPrompt] and the live-location line it used to end with).
  ///
  /// The measurement is unambiguous. Across **208 token lines** in the 22
  /// September session, every single one reads `cached=0`. Not a low hit
  /// rate — no hit, ever.
  ///
  /// A constant tool list plus a constant system prompt makes that whole
  /// ~2,400-token head a stable prefix: paid once, then cached, and cached
  /// tokens do not count against the window. The filter was trading
  /// correctness for a saving it was simultaneously making impossible.
  static List<Map<String, dynamic>> _getRelevantTools(String text) => _tools;

  /// The tool names [_getRelevantTools] would offer for [text].
  ///
  /// Exposed because this filter decides what the assistant is *capable* of
  /// on any given turn, and it is otherwise invisible — the first version
  /// silently removed every tool but three for all Bangla input, and nothing
  /// failed loudly enough to notice.
  /// The tools for [text] **in the order they are sent**, which is what the
  /// prompt cache keys on — see [_coreTools].
  @visibleForTesting
  static List<String> toolOrderFor(String text) =>
      _getRelevantTools(text).map((t) => t['function']['name'] as String).toList();

  /// Every tool this service declares, in declaration order.
  ///
  /// Exposed for `tool_parity_test.dart`. The duplication between this class
  /// and `GeminiAssistantService` is deliberate (see this class's doc
  /// comment) and therefore drifts silently — the two lists are written by
  /// hand in two incompatible schema languages, and nothing but a test can
  /// notice when one gains a tool the other did not.
  @visibleForTesting
  static List<Map<String, dynamic>> get allTools => _tools;

  @visibleForTesting
  static Set<String> toolNamesFor(String text) =>
      _getRelevantTools(text).map((t) => t['function']['name'] as String).toSet();

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
          // Compressed from prose to a table. Same information, and the
          // executor validates every value anyway — an unknown one is
          // rejected with a spoken reply, not applied. The five booleans used
          // to be named individually; grouping them is most of the saving.
          'value': _str('text_size one of 0.8|1.0|1.25|1.5|2.0 — for "bigger"/"smaller" move ONE step from the current size, never jump to an end | theme light|dark (no colours) | language english|bangla | '
              'verbosity minimalist|descriptive | voice e.g. bn-BD-female-1 | vision_level none|low|full | '
              'mobility_aid whiteCane|wheelchair|unassisted | snapshot_consent always|askEachTime|never | '
              'home_address, safe_place_address free text | all others true|false'),
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
    // Trimmed, but every clause that survived is load-bearing, and this one
    // is deliberately the least aggressive of the three trims.
    //
    // It is now sent on *every* turn (it is never filtered out), so its cost
    // is paid constantly — but it is also the one tool where under-calling
    // is the harmful direction. The "can't" clause is item 43: Bangla negates
    // after the verb, so "আমি নড়তে পারছি না" is a cry for help that reads as
    // a refusal to a model scanning for negation. The "err toward calling"
    // instruction is there because the user cannot see whether anything
    // happened. Neither comes out.
    _tool(
      'trigger_emergency',
      "Raise the emergency alarm: messages contacts with location, calls the primary one, routes to "
          "safety. Call for danger, injury, fear, being trapped/followed/taken, or urgent help, in any "
          "wording. Short \"can't\" phrases (\"I can't get up\", \"আমি নড়তে পারছি না\") are calls for "
          "help, not refusals. The user is blind and cannot check whether you understood, so err toward "
          "calling. Do NOT call for the word 'help' in passing, questions about the feature, managing "
          "contacts, or a clear \"I'm fine\". A 5s cancel window follows.",
    ),
    // Module 6. One tool with a `focus` argument rather than four separate
    // ones (scan_bus / read_sign / describe_scene / check_path), because
    // every declaration is input tokens against a per-minute ceiling the
    // conversation itself is spending — see `VisionConfig.framesUploadedPerScan`.
    // The four behaviours differ only in prompt and framing, which is an
    // argument, not four tools.
    _tool(
      'look_around',
      'Use the camera to see for the user. Call when they ask what is in front of them, which bus or '
          'vehicle this is, what a sign says, whether the path is clear, or whether it is safe to cross. '
          'The user is blind — they cannot aim the camera, so never ask them to point it anywhere.',
      properties: {
        'focus': _enumStr(
          const ['vehicle', 'sign', 'surroundings', 'hazard'],
          'vehicle = which bus/rickshaw/CNG and where it goes. sign = read text. '
              'hazard = is the path walkable. surroundings = describe the scene.',
        ),
        // Without this, the camera only ever answered the four canned
        // questions the focus enum names. "What colour is the rabbit" and
        // "what is written on this file" both arrived as `surroundings` and
        // came back as a description of the path ahead — reported on
        // 22 September as scene description giving no answer.
        'question': _str(
          "The user's own question, copied as they asked it, when it is more "
          "specific than the focus — e.g. 'what colour is the rabbit', "
          "'what is written on this page'. Omit for a general look.",
        ),
      },
      required: ['focus'],
    ),
    _tool('open_passerby_helper', 'Open the Passerby Helper overlay for a nearby stranger to read.'),
    // `subCategory` is a free string rather than a 25-value enum, which was
    // ~120 tokens on its own — over half this declaration, spent listing
    // values the user almost never names precisely.
    //
    // Safe because the executor already treats an unrecognised value as
    // absent: "a wrong prefill must never block the user from filing the
    // report by hand". So the enum was buying exactness in a field whose
    // whole contract is that exactness is optional.
    _tool(
      'open_hazard_report',
      'Open the hazard report form. Pass category/subCategory only if the user already named the hazard '
          '(never guess); omit either you\'re unsure of.',
      properties: {
        'category': _enumStr(const ['crime', 'roadHazard', 'accessibilityBlock'], 'Broad kind, if said.'),
        'subCategory': _str('Exact hazard in camelCase if named, e.g. pothole, mugging, openManhole, '
            'blockedPath. Omit if unsure.'),
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
