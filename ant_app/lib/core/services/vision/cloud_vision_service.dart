import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../config/groq_config.dart';
import '../../config/vision_config.dart';
import '../../localization/app_language.dart';
import '../api_budget.dart';
import 'vision_backend.dart';
import 'vision_prompt.dart';
import 'vision_scene.dart';

/// Thrown when the vision allowance is spent.
///
/// A distinct type, like `AssistantBudgetExhausted`, so the caller can say
/// "I cannot look right now" rather than "something went wrong" — the two
/// need different spoken answers, and the second is the one that makes a
/// blind user give up on a feature that will work again in a minute.
class VisionBudgetExhausted implements Exception {
  const VisionBudgetExhausted();
  @override
  String toString() => 'VisionBudgetExhausted: vision call ceiling reached';
}

/// The Groq half of the Snapshot Vision Engine's cloud tier.
///
/// **The fast one.** Measured 0.57-0.89 s wall against Gemini flash-lite's
/// 1.2-6.9 s, which is the entire reason `ScanFocus.vehicle` routes here: a
/// bus asked about has already started moving, and five seconds is the
/// difference between naming it and describing where it went.
///
/// What it gives up, measured on the same degraded signboard: it kept the
/// route number `৬` and corrupted the destination (`গুলশান` -> `ঠানশান`)
/// where Gemini read both exactly. See `VisionConfig.busRouteLookupWins` for
/// the mitigation, and `GeminiVisionService` for the backend that does not
/// need it.
///
/// ## Why this does not go through `GroqAssistantService`
///
/// It is a *stateless* call. The assistant sends a system prompt, five turns
/// of history and up to 24 tool declarations on every request; none of that
/// helps describe a photograph, and all of it would be charged against the
/// same 7,000-token-per-minute input allowance this call already costs 2,142
/// of. Keeping the vision call bare is what makes it affordable at all.
class CloudVisionService implements VisionBackend {
  CloudVisionService({
    String? apiKey,
    ApiBudget? budget,
    http.Client? client,
  })  : _apiKey = apiKey ?? GroqConfig.apiKey,
        _budget = budget ?? defaultApiBudget,
        _client = client ?? http.Client();

  final String _apiKey;
  final ApiBudget _budget;
  final http.Client _client;

  @override
  String get name => 'groq:${VisionConfig.visionModel}';

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  /// **One.** Groq's chat-completions endpoint takes a single image per
  /// request, so a three-frame sweep here would be three calls and ~6,400
  /// input tokens — most of a minute's entire allowance, taken from the pool
  /// the user's conversation runs on. See [VisionBackend.maxFrames].
  @override
  int get maxFrames => 1;

  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
  }) async {
    if (!isConfigured) {
      debugPrint('[Vision] no Groq key — $name unavailable');
      return null;
    }
    if (jpegs.isEmpty) return null;
    if (!await _budget.tryConsume(BillableApi.vision)) {
      throw const VisionBudgetExhausted();
    }

    // Only the first frame. The caller has already chosen which one that is —
    // the sharpest of the sweep, by variance of the Laplacian.
    final jpeg = jpegs.first;

    final body = jsonEncode({
      'model': VisionConfig.visionModel,
      'temperature': 0,
      'max_completion_tokens': 400,
      // Verified working against this model on 21 September — a blank grey
      // frame returned well-formed JSON with empty arrays rather than
      // inventing hazards to fill them, which is the failure this guards.
      'response_format': {'type': 'json_object'},
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': VisionPrompt.build(
                focus: focus,
                language: language,
                edgeLabels: edgeLabels,
              ),
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,${base64Encode(jpeg)}'},
            },
          ],
        },
      ],
    });

    final started = DateTime.now();
    try {
      final response = await _client
          .post(
            Uri.parse('${GroqConfig.baseUrl}/chat/completions'),
            headers: {
              'Authorization': 'Bearer $_apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(VisionConfig.cloudTimeout);

      final elapsed = DateTime.now().difference(started).inMilliseconds;

      if (response.statusCode != 200) {
        // 429 is the shared-ITPM ceiling, not a bug. Logged distinctly
        // because "the app stopped answering" and "the app is rate limited
        // for the next twenty seconds" look identical from outside and only
        // one of them is worth investigating.
        debugPrint(response.statusCode == 429
            ? '[Vision] $name rate limited (shared ITPM with chat) after ${elapsed}ms'
            : '[Vision] $name HTTP ${response.statusCode} after ${elapsed}ms');
        return null;
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final usage = decoded['usage'] as Map<String, dynamic>?;
      debugPrint('[Vision] $name ok in ${elapsed}ms, '
          'prompt_tokens=${usage?['prompt_tokens']} '
          'completion=${usage?['completion_tokens']} focus=${focus.name}');

      final choices = decoded['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) return null;
      final content =
          (choices.first as Map<String, dynamic>)['message']?['content'] as String?;
      if (content == null || content.trim().isEmpty) return null;

      return VisionPrompt.parse(content, focus);
    } on TimeoutException {
      debugPrint('[Vision] $name timed out after ${VisionConfig.cloudTimeout.inSeconds}s');
      return null;
    } catch (e) {
      debugPrint('[Vision] $name call failed: $e');
      return null;
    }
  }
}
