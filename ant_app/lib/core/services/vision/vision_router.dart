import 'package:flutter/foundation.dart';

import '../../localization/app_language.dart';
import 'cloud_vision_service.dart' show VisionBudgetExhausted;
import 'vision_backend.dart';
import 'vision_scene.dart';

/// Chooses a cloud backend per question, and tries the other one if it fails.
///
/// ## Why routing by focus rather than by exhaustion
///
/// A plain "fall back when the primary is out" would leave every scan on the
/// fast-but-less-accurate engine until something broke. The two backends do
/// not differ by quality — they differ by *which* quality, in opposite
/// directions, and the questions differ the same way:
///
///  * **"Which bus is this?"** has a deadline measured in seconds. Groq
///    answered in 0.57-0.89 s against Gemini's 1.2-6.9 s, and a bus asked
///    about five seconds ago is a bus that has left. Accuracy is worth less
///    than arriving in time, and `VisionConfig.busRouteLookupWins` already
///    repairs the one thing Groq gets wrong here.
///  * **"What does that sign say?"** and **"is the path clear?"** have no
///    deadline and reward exactly what Groq gives up. Gemini read a degraded
///    Bangla signboard 3/3 exactly where Groq corrupted a destination name,
///    at half the tokens, on a pool that is not the conversation's — and it
///    takes all three sweep frames in one call, which is what restores the
///    plan's Stationary Sweep.
///
/// So the routing is not a preference ordering. It is two different right
/// answers.
///
/// ## What the fallback adds on top
///
/// Either backend failing hands the whole scan to the other, which is the
/// part that matters when a free tier misbehaves — and both of these do, in
/// documented ways: Groq returns 429 on a per-minute ceiling it shares with
/// the user's conversation (twelve times in one logged tester session), and
/// Gemini's tier answers 503 under load (ten calls out of ten on
/// `3.7-flash`, which is why the model here is pinned to flash-lite).
///
/// A scan that falls back is slower. A scan that does not happen is a blind
/// user standing at a kerb with no answer.
class VisionRouter {
  VisionRouter({required this.groq, required this.gemini});

  /// The fast backend. Null when no Groq key is configured.
  final VisionBackend? groq;

  /// The accurate, multi-frame backend. Null when no Gemini key is configured.
  final VisionBackend? gemini;

  /// Whether any cloud tier exists at all. False means the app is edge-only
  /// and must say so rather than implying it looked.
  bool get hasAnyBackend => _usable(groq) != null || _usable(gemini) != null;

  static VisionBackend? _usable(VisionBackend? b) =>
      (b != null && b.isConfigured) ? b : null;

  /// The backends to try for [focus], best first.
  ///
  /// Public so the caller can ask how many frames to capture before it takes
  /// any — see [framesNeededFor].
  List<VisionBackend> orderFor(ScanFocus focus) {
    final fast = _usable(groq);
    final accurate = _usable(gemini);
    // Only the bus question races a deadline. Terrain in particular wants the
    // accurate backend: `stairs going down` and `a ramp` are a one-word
    // difference with opposite consequences.
    final preferFast = focus == ScanFocus.vehicle;
    final ordered = preferFast ? [fast, accurate] : [accurate, fast];
    return [for (final b in ordered) ?b];
  }

  /// How many frames to capture for [focus].
  ///
  /// Asked *before* the camera opens, because the answer changes what the
  /// capture does: a sweep is only worth three frames if a backend that can
  /// use three is going to be tried. With Gemini unavailable this collapses to
  /// one and the sweep degrades to the single-frame behaviour the Groq-only
  /// build had — correctly, rather than by taking two frames it will throw
  /// away.
  ///
  /// Always at least one, so a caller with no backend at all still captures
  /// and can run the offline edge pass.
  int framesNeededFor(ScanFocus focus, {required int sweepFrames}) {
    if (focus != ScanFocus.surroundings) return 1;
    final best = orderFor(focus).fold<int>(1, (m, b) => b.maxFrames > m ? b.maxFrames : m);
    return best.clamp(1, sweepFrames);
  }

  /// Describes [jpegs], trying each backend for [focus] in turn.
  ///
  /// Returns null only when every backend failed. A backend is passed as many
  /// frames as it will take and no more — the list is ordered sharpest-first
  /// by the caller, so a single-frame backend receiving three gets the best
  /// one.
  Future<VisionScene?> describe({
    required List<Uint8List> jpegs,
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    /// The user's own question, when more specific than [focus]. See
    /// `VisionPrompt.build`.
    String? question,
  }) async {
    final backends = orderFor(focus);
    if (backends.isEmpty) {
      debugPrint('[Vision] no cloud backend configured');
      return null;
    }

    // Set only when *every* backend refused on budget rather than failing.
    // The two want different spoken answers: "I have looked too many times
    // just now" is true and actionable, where "I could not see" sends
    // somebody to check their signal for no reason.
    var allExhausted = true;

    for (var i = 0; i < backends.length; i++) {
      final backend = backends[i];
      try {
        final scene = await backend.describe(
          jpegs: jpegs,
          focus: focus,
          language: language,
          edgeLabels: edgeLabels,
          question: question,
        );
        if (scene != null) {
          if (i > 0) {
            debugPrint('[Vision] ${backend.name} answered after '
                '${backends.first.name} failed');
          }
          return scene;
        }
        allExhausted = false;
        debugPrint('[Vision] ${backend.name} gave no answer'
            '${i + 1 < backends.length ? ' — trying ${backends[i + 1].name}' : ''}');
      } on VisionBudgetExhausted {
        debugPrint('[Vision] ${backend.name} budget spent'
            '${i + 1 < backends.length ? ' — trying ${backends[i + 1].name}' : ''}');
      } catch (e) {
        allExhausted = false;
        debugPrint('[Vision] ${backend.name} threw: $e');
      }
    }

    // Rethrown rather than returned as null so the caller can say the honest
    // thing. Only when nothing was left to try and every refusal was a budget
    // one — a single backend running out while the other is merely broken is
    // not "you have looked too many times".
    if (allExhausted) throw const VisionBudgetExhausted();
    return null;
  }
}
