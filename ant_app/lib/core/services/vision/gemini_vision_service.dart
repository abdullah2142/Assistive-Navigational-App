import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../config/gemini_config.dart';
import '../../config/vision_config.dart';
import '../../localization/app_language.dart';
import '../api_budget.dart';
import 'cloud_vision_service.dart' show VisionBudgetExhausted;
import 'vision_backend.dart';
import 'vision_prompt.dart';
import 'vision_scene.dart';

/// The Gemini half of the cloud tier — **the accurate one, and the only one
/// that can carry the plan's Stationary Sweep.**
///
/// ## What it is for
///
/// Measured 21 September against `gemini-3.5-flash-lite`, the model this
/// project already ships on `testers-flashlite-prompts`, on the same rendered
/// Dhaka signboard Groq was tested with:
///
///  * **Degraded Bangla, 3/3 exact.** Blurred, rotated and low-contrast, it
///    read `৬ নং মিরপুর ১০ গুলশান - ফার্মগেট` correctly every time. Groq kept
///    the number and turned `গুলশান` into `ঠানশান` — digits survive blur,
///    conjunct Bangla letterforms do not.
///  * **Three frames in one call: 3,229 tokens, 2.4 s.** One round trip, and
///    it synthesised across all three (a shop, a route sign and an open
///    manhole) into one coherent Bangla sentence.
///  * **1,082 tokens for one image** against Groq's 2,142.
///  * On a **separate free tier**, so none of it is taken from the pool the
///    user's conversation runs on.
///
/// What it costs is latency and its spread: 1.2-6.9 s where Groq is
/// 0.57-0.89. That is why `ScanFocus.vehicle` does not come here.
///
/// ## Why this model and not a newer one
///
/// `gemini_config.dart` records the history at length and it is not
/// theoretical: `gemini-flash-latest` returned 503 "high demand" on every
/// request on 1 September, and `gemini-3.7-flash` failed ten calls out of ten
/// on 17 September. Flash-lite was chosen because it *answers*, and a burst
/// of six here came back 6/6 with no 503 at all. A vision fallback needs
/// exactly that property — it is reached when the primary has already failed,
/// so a backup that is merely usually-up is not a backup.
///
/// The pin is shared with the chat path on purpose: one model to keep an eye
/// on, and any future bump is decided once.
class GeminiVisionService implements VisionBackend {
  GeminiVisionService({
    String? apiKey,
    ApiBudget? budget,
    http.Client? client,
  })  : _apiKey = apiKey ?? GeminiConfig.apiKey,
        _budget = budget ?? defaultApiBudget,
        _client = client ?? http.Client();

  final String _apiKey;
  final ApiBudget _budget;
  final http.Client _client;

  static const String _baseUrl = 'https://generativelanguage.googleapis.com/v1beta';

  @override
  String get name => 'gemini:${GeminiConfig.modelName}';

  @override
  bool get isConfigured => _apiKey.isNotEmpty;

  /// **Three** — `VisionConfig.sweepFrameCount`, in one request.
  ///
  /// This is the capability that makes `06_module_plan_snapshot_vision.md`'s
  /// Stationary Sweep affordable again after the Groq-only design had to cut
  /// it to a single frame. Verified live, not assumed: several `inline_data`
  /// parts in one `contents` entry, 3,229 prompt tokens, 2.4 s.
  @override
  int get maxFrames => VisionConfig.sweepFrameCount;

  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
  }) async {
    if (!isConfigured) {
      debugPrint('[Vision] no Gemini key — $name unavailable');
      return null;
    }
    if (jpegs.isEmpty) return null;
    if (!await _budget.tryConsume(BillableApi.visionGemini)) {
      throw const VisionBudgetExhausted();
    }

    final frames = jpegs.take(maxFrames).toList();

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text': VisionPrompt.build(
                focus: focus,
                language: language,
                edgeLabels: edgeLabels,
                frameCount: frames.length,
              ),
            },
            for (final jpeg in frames)
              {
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': base64Encode(jpeg),
                },
              },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0,
        'maxOutputTokens': 800,
        // Asks for JSON directly rather than relying on the prompt alone.
        // Flash-lite otherwise wraps replies in markdown headings and
        // bilingual glosses — observed live during the 21 September
        // comparison — which `VisionPrompt.parse` would reject outright.
        'responseMimeType': 'application/json',
      },
    });

    final started = DateTime.now();
    try {
      final response = await _client
          .post(
            Uri.parse('$_baseUrl/models/${GeminiConfig.modelName}:generateContent?key=$_apiKey'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(VisionConfig.cloudTimeout);

      final elapsed = DateTime.now().difference(started).inMilliseconds;

      if (response.statusCode != 200) {
        // 503 is this tier's characteristic failure — overload, not quota —
        // and it is the reason the model is pinned rather than aliased. Named
        // separately so a diagnostics log distinguishes "Google is busy" from
        // "we are out of quota", which call for opposite responses.
        debugPrint(response.statusCode == 503
            ? '[Vision] $name overloaded (503) after ${elapsed}ms'
            : '[Vision] $name HTTP ${response.statusCode} after ${elapsed}ms');
        return null;
      }

      final decoded = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final usage = decoded['usageMetadata'] as Map<String, dynamic>?;
      debugPrint('[Vision] $name ok in ${elapsed}ms, '
          'frames=${frames.length} '
          'prompt_tokens=${usage?['promptTokenCount']} focus=${focus.name}');

      final candidates = decoded['candidates'] as List<dynamic>?;
      if (candidates == null || candidates.isEmpty) {
        // A safety block or an empty generation lands here. Both mean "no
        // answer", which the caller must hear as a failure so it can fall
        // back — never as an empty scene, which would read as "nothing there".
        debugPrint('[Vision] $name returned no candidates '
            '(${decoded['promptFeedback'] ?? 'no feedback'})');
        return null;
      }

      final parts = (candidates.first as Map<String, dynamic>)['content']
              ?['parts'] as List<dynamic>? ??
          const [];
      final text = parts
          .map((p) => (p as Map<String, dynamic>)['text'] as String? ?? '')
          .join()
          .trim();
      if (text.isEmpty) return null;

      return VisionPrompt.parse(text, focus);
    } on TimeoutException {
      debugPrint('[Vision] $name timed out after ${VisionConfig.cloudTimeout.inSeconds}s');
      return null;
    } catch (e) {
      debugPrint('[Vision] $name call failed: $e');
      return null;
    }
  }
}
