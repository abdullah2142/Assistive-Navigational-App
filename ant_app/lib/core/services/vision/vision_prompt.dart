import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../localization/app_language.dart';
import 'vision_scene.dart';

/// The prompt and the response parser, shared by every [VisionBackend].
///
/// **Deliberately shared, not duplicated.** `GroqAssistantService` and
/// `GeminiAssistantService` carry two hand-maintained copies of the chat
/// prompt and tool list, and their own doc comments admit the two "must be
/// kept in sync" — a rule nothing enforced until `tool_parity_test.dart` was
/// written, which found a real divergence on its first run.
///
/// That duplication was forced: Gemini's typed `Schema` objects and OpenAI's
/// raw-JSON tool shape are not similar enough to share a builder. Here there
/// is no such excuse. Both vision backends want the same English instructions
/// and return the same JSON, so they get one copy of each and the drift
/// cannot happen.
class VisionPrompt {
  VisionPrompt._();

  /// Written in English whatever the user speaks, with the *output* language
  /// named explicitly.
  ///
  /// Instructing a model in Bangla costs measurably more tokens for the same
  /// instruction, and on Groq every one of those comes off a per-minute
  /// ceiling shared with the user's conversation. The reply is still Bangla —
  /// that is what `say` is for.
  /// [question] is the user's own wording when it is more specific than
  /// [focus] can express, and it **replaces** the canned task.
  ///
  /// The focus enum has six values and a person has an unbounded number of
  /// questions. "What colour is the rabbit" and "what is written on this
  /// file" both reduce to `surroundings`, whose task string asks for "the
  /// path ahead, anything blocking it, and any vehicle or person close by" —
  /// so the model dutifully described a footpath and said nothing about
  /// either. Reported on 22 September as scene description giving no answers.
  ///
  /// The safety framing around it is kept either way: the honesty rules
  /// below are what stop a covered lens producing an all-clear, and they are
  /// not the model's to negotiate whatever is being asked.
  static String build({
    required ScanFocus focus,
    required AppLanguage language,
    List<String> edgeLabels = const [],
    int frameCount = 1,
    String? question,
  }) {
    final lang = language == AppLanguage.bangla ? 'Bangla (বাংলা)' : 'English';

    final framing = frameCount > 1
        ? 'These are $frameCount frames from one slow left-to-right sweep, in '
            'order. Treat them as one scene, not $frameCount scenes.'
        : '';

    // The edge detector's labels are offered as a second opinion, with its
    // known blind spot stated. COCO has no rickshaw and no CNG class, so it
    // calls a cycle-rickshaw a bicycle and a CNG auto a car — telling the
    // model that is what lets it correct the label instead of either trusting
    // it or inventing something unrelated.
    final hint = edgeLabels.isEmpty
        ? ''
        : '\nAn on-device detector labelled these, which may be wrong about '
            'rickshaws and CNG auto-rickshaws (it has no class for either and '
            'calls them bicycle/car/truck): ${edgeLabels.join(', ')}.';

    final task = switch (focus) {
      ScanFocus.vehicle =>
        'Identify the vehicle. If it is a bus, read its route number and '
            'destinations from the signboard. Say which vehicle it is and where '
            'it goes. Dhaka vehicles include buses, cycle-rickshaws, CNG '
            'auto-rickshaws, leguna and private cars — name them specifically.',
      ScanFocus.sign =>
        'Read every piece of text in the image exactly as written. Then say '
            'what it means in one short sentence.',
      ScanFocus.surroundings =>
        'Describe what is in front of this blind pedestrian in two short '
            'sentences: the path ahead, anything blocking it, and any vehicle '
            'or person close by.',
      ScanFocus.terrain =>
        'Look ONLY at the ground the person is about to walk on, and say '
            'whether it stays level. Report: steps going DOWN, steps going UP, '
            'an escalator and which way it runs, a lift or its doors, a ramp or '
            'slope, a kerb or any edge where the ground drops, an open drain or '
            'manhole, and standing water or a wet slippery floor. Say which '
            'direction and roughly how many paces away. If the ground simply '
            'continues level and unbroken, say so plainly — do not invent a '
            'hazard to have something to report. A fall is the worst thing that '
            'can happen to this person, and a false alarm every time they walk '
            'teaches them to ignore you.',
      ScanFocus.ride =>
        'Find this person a ride. List every rickshaw, CNG auto-rickshaw, taxi '
            'or leguna you can see, say roughly where each one is (left, ahead, '
            'right) and whether it looks empty or already has a passenger. Say '
            'plainly if there is none. Do not count parked or broken-down '
            'vehicles as available.',
      ScanFocus.hazard =>
        'Look only for things that could hurt or trip a blind pedestrian: open '
            'manholes, open drains, broken or dug-up pavement, construction, '
            'steps, flooding, fire, and vehicles or crowds blocking the path. '
            'Say whether the way ahead is walkable.',
    };

    // The user's own words win over the canned task, but the scene framing
    // stays: they are still blind, still in Dhaka, and the answer still has
    // to be about what is actually in the frame.
    final asked = question == null || question.trim().isEmpty ? null : question.trim();
    final instruction = asked == null
        ? task
        : 'Answer this question about what is in the image, directly and '
            'specifically: "$asked" If the image does not show enough to '
            'answer it, say exactly that and say what you can see instead.';

    return '''
You are the eyes of a blind pedestrian in Dhaka, Bangladesh. $instruction$framing$hint

Report ONLY what is actually visible. Never guess a route number, a
destination or a hazard you cannot see — this person cannot check what you
say against the street, so a confident wrong answer is worse than "I cannot
tell".

Write "say" in $lang, calm and under 25 words. Lead with anything dangerous.

Reply with JSON only:
{"say":"<sentence in $lang>",
 "hazards":[{"kind":"manhole|open_drain|construction|fire|crowd|broken_pavement|flooding|vehicle|step|obstacle|other","description":"<in $lang>","severity":1}],
 "vehicles":[{"kind":"bus|rickshaw|cng|car|motorcycle|truck|van|other","route_number":"","destination":"","raw_text":""}],
 "text_found":"<verbatim, original script>",
 "people_estimate":0}
Use empty arrays and "" when there is nothing to report.''';
  }

  /// Parses a backend's JSON into a [VisionScene].
  ///
  /// Shared for the same reason the prompt is: the contract between what the
  /// prompt asks for and what this reads is the part most likely to drift,
  /// and two copies of a parser would drift against one prompt.
  static VisionScene? parse(String raw, ScanFocus focus) {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(_stripFence(raw)) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Vision] unparseable response: $e');
      return null;
    }

    final spoken = (json['say'] as String?)?.trim() ?? '';
    // A scene with no sentence is useless — everything else here exists to
    // support that one line being spoken. Treated as a failure rather than an
    // empty success, so the caller falls back instead of saying nothing.
    if (spoken.isEmpty) return null;

    return VisionScene(
      focus: focus,
      spoken: spoken,
      textFound: (json['text_found'] as String?)?.trim() ?? '',
      peopleEstimate: _asInt(json['people_estimate']),
      capturedAt: DateTime.now(),
      hazards: [
        for (final h in (json['hazards'] as List<dynamic>? ?? const []))
          if (h is Map<String, dynamic> &&
              (h['description'] as String?)?.trim().isNotEmpty == true)
            SceneHazard(
              kind: normaliseKind(h['kind'] as String?),
              description: (h['description'] as String).trim(),
              severity: (_asInt(h['severity']) ?? 1).clamp(1, 3),
            ),
      ],
      vehicles: [
        for (final v in (json['vehicles'] as List<dynamic>? ?? const []))
          if (v is Map<String, dynamic>)
            SceneVehicle(
              kind: (v['kind'] as String?)?.trim().toLowerCase() ?? 'other',
              routeNumber: normaliseDigits((v['route_number'] as String?)?.trim()),
              destination: (v['destination'] as String?)?.trim().isEmpty ?? true
                  ? null
                  : (v['destination'] as String).trim(),
              rawText: (v['raw_text'] as String?)?.trim() ?? '',
            ),
      ],
    );
  }

  /// Bangla-Indic digits to ASCII.
  ///
  /// A route read as `৬` and a route stored as `6` are the same bus, and a
  /// lookup that missed on the numeral system would hand the user the model's
  /// unverified destination guess instead of the directory's verified one —
  /// which is exactly the substitution `VisionConfig.busRouteLookupWins`
  /// exists to prevent.
  static String? normaliseDigits(String? input) {
    if (input == null || input.isEmpty) return null;
    const bengaliZero = 0x09E6;
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= bengaliZero && rune <= bengaliZero + 9) {
        buffer.writeCharCode(0x30 + (rune - bengaliZero));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return RegExp(r'\d+').firstMatch(buffer.toString())?.group(0);
  }

  /// Maps whatever the model called a hazard onto the stable key set
  /// [SceneHazard.kind] documents, so a report filed from a scan lands in the
  /// same Firestore shape as one filed by hand.
  static String normaliseKind(String? raw) {
    final k = raw?.trim().toLowerCase() ?? '';
    if (k.isEmpty) return 'other';
    const known = {
      'manhole', 'open_drain', 'construction', 'fire', 'crowd',
      'broken_pavement', 'flooding', 'vehicle', 'step', 'obstacle',
    };
    if (known.contains(k)) return k;
    // Generous substring match: models answer in free text often enough that
    // exact-match-only would drop most real hazards into `other` and lose the
    // Module 5 report prefill.
    for (final candidate in known) {
      if (k.contains(candidate.replaceAll('_', ' ')) || k.contains(candidate)) {
        return candidate;
      }
    }
    return 'other';
  }

  static int? _asInt(Object? v) => switch (v) {
        final int i => i,
        final num n => n.toInt(),
        final String s => int.tryParse(s.trim()),
        _ => null,
      };

  /// Models wrap JSON in ``` fences often enough to be worth handling even
  /// with a JSON response format requested.
  static String _stripFence(String raw) {
    var s = raw.trim();
    if (!s.startsWith('```')) return s;
    s = s.replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '');
    final close = s.lastIndexOf('```');
    return (close == -1 ? s : s.substring(0, close)).trim();
  }
}
