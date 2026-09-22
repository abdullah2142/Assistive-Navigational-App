import 'dart:typed_data';

import '../../localization/app_language.dart';
import 'vision_scene.dart';

/// One cloud vision engine.
///
/// Two exist because they fail in opposite directions, and the module uses
/// both on purpose rather than picking a winner. Measured 21 September on the
/// same rendered Dhaka signboard:
///
/// |                          | Groq Qwen 3.8-27B | Gemini 3.5 Flash-Lite |
/// |--------------------------|-------------------|-----------------------|
/// | latency, one image       | 0.57-0.89 s       | 1.2-6.9 s             |
/// | three images, one call   | not supported     | 2.4 s                 |
/// | degraded Bangla sign     | `গুলশান`->`ঠানশান` | exact, 3/3            |
/// | input tokens, one image  | 2,142             | 1,082                 |
/// | token pool               | shared with chat  | separate              |
///
/// So Groq owns the question with a deadline — a bus is gone in five seconds
/// — and Gemini owns the questions that reward accuracy and a wider view.
/// See [maxFrames] for the part that changes what the module can do at all.
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
  /// `VisionConfig.framesUploadedPerScan` is 1.
  ///
  /// Gemini accepts several `inline_data` parts in one request: three frames
  /// measured at 3,229 tokens and 2.4 s in a single round trip, on a pool
  /// that is not the conversation's. With that backend the sweep is
  /// affordable exactly as `06_module_plan_snapshot_vision.md` specified it.
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
  });
}
