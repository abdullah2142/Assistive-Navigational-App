import 'package:flutter/foundation.dart';

import '../../config/gemini_config.dart';
import '../../localization/app_language.dart';
import '../gemini_model_cooldowns.dart';
import 'cloud_vision_service.dart' show VisionBudgetExhausted;
import 'gemini_vision_service.dart';
import 'vision_backend.dart';
import 'vision_scene.dart';

/// Gemini vision fallback chain. Rate-limited or overloaded models get a
/// reset timer and are skipped on the next request; the first model regains
/// priority automatically when its timer expires.
class GeminiVisionCascade implements VisionBackend {
  GeminiVisionCascade({
    String? apiKey,
    GeminiModelCooldowns? cooldowns,
    List<String>? modelNames,
  }) : _cooldowns = cooldowns ?? GeminiModelCooldowns.shared,
       _models = [
         for (final name in modelNames ?? GeminiConfig.frontSnapFallbackModels)
           GeminiVisionService(
             apiKey: apiKey,
             modelName: name,
             cooldowns: cooldowns,
             requestTimeout: const Duration(milliseconds: 2800),
           ),
       ];

  final GeminiModelCooldowns _cooldowns;
  final List<GeminiVisionService> _models;

  @override
  String get name => _models.map((model) => model.name).join('->');

  @override
  bool get isConfigured => _models.any((model) => model.isConfigured);

  @override
  int get maxFrames => 3;

  @override
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    String? question,
  }) async {
    var allBudgetExhausted = true;
    var attempted = false;
    for (final model in _models) {
      final cooldownKey = model.name;
      if (!model.isConfigured || _cooldowns.isCooling(cooldownKey)) {
        continue;
      }
      attempted = true;
      try {
        final scene = await model.describe(
          jpegs: jpegs,
          focus: focus,
          language: language,
          edgeLabels: edgeLabels,
          question: question,
        );
        if (scene != null) return scene;
        allBudgetExhausted = false;
      } on VisionBudgetExhausted {
        continue;
      } catch (error) {
        allBudgetExhausted = false;
        final resetAt = _cooldowns.recordFailure(cooldownKey, error);
        debugPrint(
          '[Vision] ${model.name} failed'
          '${resetAt == null ? '' : '; retry after $resetAt'}: $error',
        );
      }
    }
    if (attempted && allBudgetExhausted) {
      throw const VisionBudgetExhausted();
    }
    return null;
  }
}
