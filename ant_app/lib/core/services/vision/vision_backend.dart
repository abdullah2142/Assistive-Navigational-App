import 'dart:typed_data';

import '../../localization/app_language.dart';
import 'vision_scene.dart';

/// One cloud vision engine. Qwen handles ordinary one-frame captures first;
/// Gemini handles complete guided sweeps first and backs up Qwen when needed.
/// See [maxFrames] for the number of images an engine can use in one request.
abstract class VisionBackend {
  /// Short name for logs, so a diagnostics file says which engine answered.
  String get name;

  bool get isConfigured;

  /// How many frames this backend will accept in a single request.
  ///
  /// **This is the whole reason the plan's Stationary Sweep survives.**
  /// Groq's chat-completions endpoint takes one image per call, so three
  /// frames means three calls — ~6,400 input tokens against a 7,000/minute
  /// ceiling *shared with the user's conversation*, which would cost them
  /// the ability to speak to the app for the following minute. That is why
  /// Gemini accepts several `inline_data` parts in one request. For an
  /// explicit sweep it receives the complete left/centre/right sequence;
  /// Qwen receives one selected frame if it is used as the fallback.
  int get maxFrames;

  /// Describes [jpegs], already downscaled by the caller.
  ///
  /// A list rather than one image even for single-frame backends, so the
  /// orchestrator has one call shape and the frame count is the backend's
  /// business — it takes what it can use and ignores the rest.
  ///
  /// Returns null when the call could not be made or could not be parsed.
  /// Never returns an empty-but-successful scene to mean failure: the caller
  /// must be able to tell "I could not see" from "there is nothing there",
  /// because for a blind user those differ by a step into the road.
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],

    /// The user's own question, when more specific than [focus]. See
    /// `VisionPrompt.build`.
    String? question,
  });
}
