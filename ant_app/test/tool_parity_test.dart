// The two assistant backends must offer the model the same abilities.
//
// `GroqAssistantService` and `GeminiAssistantService` are two independent
// implementations of one contract — identical `converse` signatures, the same
// `AssistantTurn` out, the same `FunctionCallExecutor` underneath. That is
// what makes Gemini a usable revert path, and what would make a Groq -> Gemini
// fallback a dozen lines rather than a rewrite.
//
// It is also a standing liability, and the services' own doc comments say so:
// the system prompt and the tool list are written **twice**, by hand, in two
// incompatible schema languages (Gemini's `FunctionDeclaration`/`Schema`
// objects and OpenAI's raw-JSON tool shape), because the two are not similar
// enough to share a builder without obscuring both.
//
// Nothing enforces that they stay in step. Today the drift is dormant, since
// only Groq actually runs — a tool missing from Gemini is a latent bug nobody
// meets. The moment a fallback exists it stops being latent and becomes the
// worst kind of live bug: the same sentence behaves differently depending on
// which backend happened to answer, and it only happens under load, which is
// exactly when nobody can reproduce it.
//
// This file is the enforcement. It caught nothing when written — `look_around`
// had already been added to both — which is the point: it exists so the
// *next* tool cannot be added to one and forgotten in the other.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ant_app/core/services/gemini_assistant_service.dart';
import 'package:ant_app/core/services/groq_assistant_service.dart';

/// One tool, reduced to the shape both backends can be compared on.
///
/// Descriptions are deliberately **not** compared. They are prose aimed at a
/// model, they have been tuned per-backend on purpose (the Groq copies are
/// visibly trimmed for that tier's token ceiling), and asserting they match
/// would either fail permanently or force the prompts to stop being tuned.
/// What must match is what the model can *do*: the name, the arguments it may
/// pass, which are mandatory, and the closed sets it must choose from.
class ToolShape {
  ToolShape({
    required this.name,
    required this.parameters,
    required this.required,
    required this.enums,
  });

  final String name;
  final Set<String> parameters;
  final Set<String> required;

  /// Parameter name -> its allowed values, for parameters declared as enums.
  ///
  /// Compared because this is the drift that hurts most quietly. `update_setting`
  /// carries a fifteen-value enum of setting names; adding one to Groq alone
  /// means the setting is changeable on one backend and silently rejected on
  /// the other, with no error anywhere — the model simply never learns the
  /// value exists.
  final Map<String, Set<String>> enums;

  @override
  String toString() => 'ToolShape($name, params=$parameters, required=$required)';
}

ToolShape _fromJson(Map<String, Object?> fn) {
  final params = fn['parameters'] as Map<String, Object?>?;
  final props = (params?['properties'] as Map<String, Object?>?) ?? const {};
  return ToolShape(
    name: fn['name']! as String,
    parameters: props.keys.toSet(),
    required: ((params?['required'] as List<Object?>?) ?? const [])
        .map((e) => e! as String)
        .toSet(),
    enums: {
      for (final entry in props.entries)
        if (entry.value is Map &&
            (entry.value! as Map)['enum'] is List)
          entry.key: ((entry.value! as Map)['enum'] as List)
              .map((e) => '$e')
              .toSet(),
    },
  );
}

Map<String, ToolShape> _groqTools() => {
      for (final tool in GroqAssistantService.allTools)
        () {
          final fn = (tool['function'] as Map).cast<String, Object?>();
          return fn['name']! as String;
        }(): _fromJson((tool['function'] as Map).cast<String, Object?>()),
    };

Map<String, ToolShape> _geminiTools() => {
      for (final decl in GeminiAssistantService.functionDeclarations)
        decl.name: _fromJson(decl.toJson()),
    };

/// Divergences that are deliberate, with the reason they were accepted.
///
/// An allowlist rather than a loosened assertion, so that *this* difference
/// is permitted and every other one still fails. An entry here is a claim
/// that somebody weighed the drift and chose it; it is not a place to put
/// a failure that is merely inconvenient.
const knownEnumDivergences = {
  // Groq declares `subCategory` as a free string where Gemini declares a
  // 25-value enum. Deliberate, and documented at the declaration: the enum
  // cost ~120 tokens — over half that tool's declaration — to enumerate
  // values a user almost never names precisely, against a per-minute input
  // ceiling this backend actually hits.
  //
  // Safe specifically because `FunctionCallExecutor._prefillFrom` treats an
  // unrecognised sub-category as absent rather than as an error, so the
  // worst case is the Reporting Hub opening one level higher up. The enum
  // was buying exactness in a field whose whole contract is that exactness
  // is optional.
  //
  // Note the asymmetry is the safe direction: the backend that *ships* is
  // the permissive one. Were it reversed, Gemini could emit a value Groq's
  // schema forbids.
  'open_hazard_report.subCategory',
};

void main() {
  late Map<String, ToolShape> groq;
  late Map<String, ToolShape> gemini;

  setUp(() {
    groq = _groqTools();
    gemini = _geminiTools();
  });

  group('both backends declare the same tools', () {
    test('neither has a tool the other is missing', () {
      final onlyGroq = groq.keys.toSet().difference(gemini.keys.toSet());
      final onlyGemini = gemini.keys.toSet().difference(groq.keys.toSet());
      expect(
        onlyGroq,
        isEmpty,
        reason: 'declared to Groq but not Gemini — a fallback turn would lose '
            'these abilities entirely: $onlyGroq',
      );
      expect(
        onlyGemini,
        isEmpty,
        reason: 'declared to Gemini but not Groq — these are dead today, since '
            'Groq is what ships: $onlyGemini',
      );
    });

    test('the list is not accidentally empty', () {
      // Both sides are built by static initialisers. If one ever fails to
      // populate, every other assertion here passes vacuously — two empty
      // sets are equal.
      expect(groq, isNotEmpty);
      expect(gemini, isNotEmpty);
      expect(groq.length, greaterThan(20), reason: 'expected the full tool set');
    });
  });

  group('each tool takes the same arguments on both', () {
    test('parameter names match', () {
      final mismatched = <String, String>{};
      for (final name in groq.keys.toSet().intersection(gemini.keys.toSet())) {
        final g = groq[name]!.parameters;
        final m = gemini[name]!.parameters;
        if (!const SetEquality().equals(g, m)) {
          mismatched[name] = 'groq=$g gemini=$m';
        }
      }
      expect(mismatched, isEmpty,
          reason: 'a model calling these with the arguments one backend '
              'documents would be rejected by the other: $mismatched');
    });

    test('required arguments match', () {
      // Asymmetry here is worse than a missing tool, because it fails *late*.
      // A parameter mandatory on Groq and optional on Gemini means the Gemini
      // path can produce a call the executor then has to reject — and the
      // executor's rejections are spoken to a blind user as an apology, not
      // surfaced as the schema bug they are.
      final mismatched = <String, String>{};
      for (final name in groq.keys.toSet().intersection(gemini.keys.toSet())) {
        final g = groq[name]!.required;
        final m = gemini[name]!.required;
        if (!const SetEquality().equals(g, m)) {
          mismatched[name] = 'groq=$g gemini=$m';
        }
      }
      expect(mismatched, isEmpty, reason: 'required-argument drift: $mismatched');
    });


    test('enum values match', () {
      final mismatched = <String, String>{};
      for (final name in groq.keys.toSet().intersection(gemini.keys.toSet())) {
        final g = groq[name]!.enums;
        final m = gemini[name]!.enums;
        for (final param in {...g.keys, ...m.keys}) {
          final gv = g[param] ?? const <String>{};
          final mv = m[param] ?? const <String>{};
          if (knownEnumDivergences.contains('$name.$param')) continue;
          if (!const SetEquality().equals(gv, mv)) {
            mismatched['$name.$param'] =
                'only-groq=${gv.difference(mv)} only-gemini=${mv.difference(gv)}';
          }
        }
      }
      expect(mismatched, isEmpty,
          reason: 'a value the model may choose on one backend and not the '
              'other: $mismatched');
    });

    test('no allowlisted divergence has quietly been fixed', () {
      // An allowlist nobody prunes becomes a list of things that used to be
      // true. If a divergence is resolved, the entry has to go, or it sits
      // there silently permitting a future regression of the same shape.
      final stale = <String>[];
      for (final key in knownEnumDivergences) {
        final parts = key.split('.');
        final tool = parts.first;
        final param = parts.last;
        final gv = groq[tool]?.enums[param] ?? const <String>{};
        final mv = gemini[tool]?.enums[param] ?? const <String>{};
        if (const SetEquality().equals(gv, mv)) stale.add(key);
      }
      expect(stale, isEmpty,
          reason: 'these no longer diverge — remove them from '
              'knownEnumDivergences: $stale');
    });
  });

  group('every declared tool is actually reachable', () {
    test('the keyword filter never offers a tool that does not exist', () {
      // `_getRelevantTools` selects by name from a hand-written keyword table.
      // A typo there — or a tool renamed on one side only — silently makes
      // that whole keyword group offer nothing, and the symptom is not an
      // error: it is the assistant quietly being unable to do something, for
      // the subset of phrasings that route through the broken group. That is
      // indistinguishable from the model simply choosing not to act.
      const phrases = [
        'take me to Gulshan', 'change the theme to dark', 'save this place',
        'tell my caretaker i am late', 'report a broken footpath',
        'what bus is this', 'is the path clear', 'open the map',
        'add my sister to my contacts', 'help me', 'yes', '',
        'ম্যাপ টা বন্ধ করো', 'আমার বোনের নাম্বার সেভ করো', 'সামনে কী আছে',
        'বাঁচাও', 'অন্য একটা রাস্তা দেখাও', 'লেখা বড় করো',
      ];
      final declared = groq.keys.toSet();
      for (final phrase in phrases) {
        final offered = GroqAssistantService.toolNamesFor(phrase);
        expect(offered.difference(declared), isEmpty,
            reason: '"$phrase" offers tools that are not declared anywhere');
      }
    });

    test('the executor handles every declared tool', () {
      // A source scan rather than a call, deliberately: invoking the executor
      // for real would need Firebase, a location fix and a live profile for
      // most of these, and the thing worth checking is far narrower than that
      // — whether the name appears in the executor at all.
      //
      // The bug it guards is specific and has a shape: `FunctionCallExecutor`
      // falls through to `{'ok': false, 'error': 'unknown function'}`, so a
      // tool declared to the model and never handled does not crash and does
      // not log. The model calls it, the executor shrugs, and the user is told
      // something vague went wrong. Item 51 in `task.md` is exactly this —
      // `cancel_route` was declared and handled nowhere, and the route stayed
      // on the map while the user was told it had been cancelled.
      final source = File('lib/core/services/function_call_executor.dart')
          .readAsStringSync();
      final unhandled = [
        for (final name in groq.keys)
          if (!source.contains("'$name'")) name,
      ];
      expect(unhandled, isEmpty,
          reason: 'declared to the model but absent from the executor — these '
              'would return "unknown function" at runtime: $unhandled');
    });
  });
}

/// Local set comparison, so this file does not pull in `collection` just for
/// one predicate.
class SetEquality {
  const SetEquality();
  bool equals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}
