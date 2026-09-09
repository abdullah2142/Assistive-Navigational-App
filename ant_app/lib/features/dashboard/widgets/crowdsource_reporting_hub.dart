import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/providers/tts_providers.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/services/wake_word_service.dart';
import '../../../core/services/voice_cancel_window.dart';
import '../../../core/services/tts_service.dart';
import '../../../core/utils/ai_text_summarizer.dart';
import '../../onboarding/models/disability_profile_enums.dart';
import '../models/hazard_report.dart';
import '../providers/dashboard_providers.dart';

/// The Crowdsource Reporting Hub — a glassmorphism overlay with three
/// drill-down categories, per UI module plan Step 4.2. Any category's
/// sub-option list ends in an "Other" entry (see
/// `Dashboard.isOtherSubCategoryKey`), which opens a free-text (or
/// dictated, once Module 3 lands) description that gets run through a
/// stub AI summary before submission.
///
/// Fully voice-first when [voiceAutoListen] is on (see
/// `UserProfile.voiceAutoListen` — the standing principle this app should
/// "dictate every step and accept a voice request at every stage" for a
/// user who can't see the screen at all, not just isolated voice buttons):
/// every step is narrated aloud and immediately followed by listening for
/// either the spoken option name or, on the final step, a "submit" voice
/// command — tapping stays available throughout regardless.
class CrowdsourceReportingHub extends ConsumerStatefulWidget {
  const CrowdsourceReportingHub({
    super.key,
    required this.reporterUid,
    required this.language,
    required this.voiceAutoListen,
    this.mobilityAid = MobilityAid.unassisted,
    this.prefill,
  });

  final String reporterUid;
  final AppLanguage language;
  final bool voiceAutoListen;

  /// Set when a voice command already said what the hazard is ("report an
  /// open manhole") — those steps are skipped rather than asked again. See
  /// [HazardReportPrefill].
  final HazardReportPrefill? prefill;

  /// Reorders the Accessibility Block sub-category list to put whatever's
  /// most likely relevant to *this* reporter first (see
  /// `_orderedSubCategoryKeys`) — a wheelchair user reporting an
  /// accessibility problem is far more often about a ramp or curb cut than
  /// a missing tactile paving strip, and vice versa for a white cane user.
  /// Doesn't touch Crime or Road Hazard, where mobility aid isn't a
  /// meaningful signal for which sub-option is most likely.
  final MobilityAid mobilityAid;

  static Future<void> show(
    BuildContext context, {
    required String reporterUid,
    required AppLanguage language,
    required bool voiceAutoListen,
    MobilityAid mobilityAid = MobilityAid.unassisted,
    HazardReportPrefill? prefill,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: true,
        pageBuilder: (_, _, _) => CrowdsourceReportingHub(
          reporterUid: reporterUid,
          language: language,
          voiceAutoListen: voiceAutoListen,
          mobilityAid: mobilityAid,
          prefill: prefill,
        ),
      ),
    );
  }

  @override
  ConsumerState<CrowdsourceReportingHub> createState() => _CrowdsourceReportingHubState();
}

class _CrowdsourceReportingHubState extends ConsumerState<CrowdsourceReportingHub> {
  late HazardCategory? _category = widget.prefill?.category;
  // Only honoured when it is a real sub-category of the prefilled category
  // — a voice command that produced something unrecognized drops the user
  // on the sub-category step to pick by hand, which is strictly better than
  // filing a report under a key nothing can read back.
  late String? _subCategoryKey = _validPrefillSubCategory();
  final _descriptionController = TextEditingController();
  bool _submitting = false;
  bool _listening = false;

  late final Dashboard _d = Dashboard.of(widget.language);

  // Captured once, here, rather than `ref.read` inside `dispose()` — `ref`
  // is unsafe to use once a widget is unmounting (a real crash this caused
  // live: "Bad state: Using 'ref' when a widget is about to or has been
  // unmounted is unsafe").
  late final SttService _stt = ref.read(sttServiceProvider);
  late final WakeWordService _wakeWord = ref.read(wakeWordServiceProvider);
  late final TtsService _tts = ref.read(ttsServiceProvider);

  // Bumped every time the step changes (category picked, sub-category
  // picked, back navigation). A step's own narrate-then-listen sequence is
  // async and checks this before acting on what it hears — otherwise a
  // user who taps ahead manually while narration/listening from the
  // *previous* step is still in flight could have that stale voice input
  // silently applied to the new step instead.
  int _stepGeneration = 0;

  static const _submitPhrasesEn = [
    'submit', 'send', 'send it', 'send this', 'submit this', 'submit report', 'done', 'finish',
  ];
  // Includes Bangla *transliterations* of the English words, not just their
  // Bangla translations. Dhaka speech mixes English command words into
  // Bangla sentences constantly, and a `bn-BD` recognizer writes them in
  // Bangla script — so a user who says "send" while the app is in Bangla
  // gets back "সেন্ড", which matched nothing here and was silently appended
  // to the hazard description instead of submitting it. Confirmed from a
  // real device log.
  static const _submitPhrasesBn = [
    'পাঠাও', 'পাঠান', 'পাঠিয়ে দাও', 'সাবমিট', 'সেন্ড', 'সেন্ড করো', 'শেষ', 'হয়ে গেছে',
  ];

  // What's actually been said so far, across possibly several separate
  // utterances with pauses in between — a user describing an incident may
  // stumble, pause to think, and continue, and every part of that should
  // count, not just whatever the single most recent utterance happened to
  // be. Reset whenever the step changes (see `_goToCategory`/
  // `_goToSubCategory`). The text field itself always mirrors this plus
  // whatever's live-updating in the current in-progress utterance.
  String _committedDescription = '';

  bool get _isOther => _subCategoryKey != null && _d.isOtherSubCategoryKey(_subCategoryKey!);

  // Priority order for Accessibility Block sub-categories, most relevant
  // first, per mobility aid — everything not named here just keeps its
  // original relative order at the end (see `_orderedSubCategoryKeys`).
  static const _wheelchairPriority = ['noCurbCut', 'brokenRamp', 'blockedByVendors', 'blockedPath', 'narrowPassage', 'elevatorOutOfService'];
  static const _whiteCanePriority = ['noTactilePaving', 'blockedPath', 'narrowPassage', 'blockedByVendors', 'stairsOnly'];

  /// [Dashboard.hazardSubCategoryKeys], reordered by relevance to
  /// [CrowdsourceReportingHub.mobilityAid] when the category is
  /// Accessibility Block — the "Other" sentinel always stays last
  /// regardless, matching every other category's convention.
  List<String> _orderedSubCategoryKeys(HazardCategory category) {
    final keys = _d.hazardSubCategoryKeys(category);
    if (category != HazardCategory.accessibilityBlock) return keys;
    final priority = switch (widget.mobilityAid) {
      MobilityAid.wheelchair => _wheelchairPriority,
      MobilityAid.whiteCane => _whiteCanePriority,
      MobilityAid.unassisted => const <String>[],
    };
    if (priority.isEmpty) return keys;
    final rest = keys.where((k) => !priority.contains(k) && !_d.isOtherSubCategoryKey(k));
    final other = keys.where(_d.isOtherSubCategoryKey);
    return [...priority.where(keys.contains), ...rest, ...other];
  }

  @override
  void initState() {
    super.initState();
    // Forces the lazy `late final _stt` initializer to run now, while `ref`
    // is still safe to use — otherwise, if the mic button here is never
    // tapped, `dispose()` ends up being the *first* access, which is
    // exactly the unsafe-`ref` crash this field was introduced to avoid.
    _stt;
    _wakeWord;
    _descriptionController.addListener(() => setState(() {}));
    // Suspended for as long as this hub is open, not merely around each
    // individual listen. Per-listen suspension let the wake-word recorder
    // reclaim the microphone in the gap between two steps — which is exactly
    // when the app is reading the hazard options aloud. It then held the mic
    // through the narration and the following listen returned nothing, so
    // the options were read out and no answer was ever taken. Reported as
    // working with auto-listen on and "Hey ANT" off, and broken with both
    // on; this is why.
    _wakeWord.suspend();
    WidgetsBinding.instance.addPostFrameCallback((_) => _narrateAndListenForStep());
  }

  @override
  void dispose() {
    // A screen's narration belongs to that screen — closing the hub has to
    // take its voice with it, or it carries on reading hazard options over
    // whatever the user went back to.
    _tts.stop();
    _stt.stop();
    _wakeWord.resume();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<bool> _speak(String text) async {
    if (!ref.read(ttsEnabledProvider)) return false;
    await _tts.speak(text, language: widget.language);
    return true;
  }

  void _goToCategory(HazardCategory? category) {
    setState(() {
      _category = category;
      _subCategoryKey = null;
      _descriptionController.clear();
      _committedDescription = '';
    });
    _narrateAndListenForStep();
  }

  void _goToSubCategory(String? key) {
    setState(() {
      _subCategoryKey = key;
      _descriptionController.clear();
      _committedDescription = '';
    });
    _narrateAndListenForStep();
  }

  String? _validPrefillSubCategory() {
    final prefill = widget.prefill;
    if (prefill?.subCategory == null) return null;
    final valid = Dashboard.of(widget.language).hazardSubCategoryKeys(prefill!.category);
    return valid.contains(prefill.subCategory) ? prefill.subCategory : null;
  }

  /// Narrates the current step aloud, then — only when
  /// `widget.voiceAutoListen` is on, matching how the Passerby picker gates
  /// its own auto-listen — starts listening for either the spoken option
  /// name (category/sub-category steps) or a "submit" voice command (the
  /// final step). Tapping stays available the whole time regardless; this
  /// only adds a voice-first path on top for a user who can't see the
  /// options to tap them at all.
  Future<void> _narrateAndListenForStep() async {
    final generation = ++_stepGeneration;
    if (widget.voiceAutoListen) await _stt.stop(); // cut off any previous step's listener first

    if (_category == null) {
      final labels = HazardCategory.values.map(_d.hazardCategoryLabel).toList();
      final spoke = await _speak(_d.crowdsourceCategoryPrompt(labels.join(', ')));
      if (!mounted || generation != _stepGeneration || !widget.voiceAutoListen) return;
      if (spoke) await Future<void>.delayed(SttService.narrationSettle);
      await _listenForOption(
        generation: generation,
        matchers: {for (final c in HazardCategory.values) _d.hazardCategoryLabel(c): () => _goToCategory(c)},
      );
      return;
    }

    if (_subCategoryKey == null) {
      final keys = _orderedSubCategoryKeys(_category!);
      final labels = keys.map(_d.hazardSubCategoryLabel).toList();
      final spoke =
          await _speak(_d.crowdsourceSubCategoryPrompt(_d.hazardCategoryLabel(_category!), labels.join(', ')));
      if (!mounted || generation != _stepGeneration || !widget.voiceAutoListen) return;
      if (spoke) await Future<void>.delayed(SttService.narrationSettle);
      await _listenForOption(
        generation: generation,
        matchers: {for (final k in keys) _d.hazardSubCategoryLabel(k): () => _goToSubCategory(k)},
      );
      return;
    }

    // Final step — describe (Other) or optional-details-then-submit.
    await _speak(_isOther ? _d.crowdsourceDescribePromptSpoken : _d.crowdsourceOptionalPromptSpoken);
    if (!mounted || generation != _stepGeneration || !widget.voiceAutoListen) return;
    await _listenForDescriptionOrSubmit(generation);
  }

  /// Keeps listening — one attempt was nowhere near enough live: a user
  /// who stumbles, hesitates, or gets a syllable dropped by the recognizer
  /// deserves as many tries as it takes, not one narrow window that goes
  /// silent forever after a single miss. Loops until either something
  /// matches, the step changes (`generation` mismatch — the user tapped an
  /// option manually, or navigated back), or the widget is gone.
  Future<void> _listenForOption({required int generation, required Map<String, VoidCallback> matchers}) async {
    while (mounted && generation == _stepGeneration) {
      if (!await _stt.ensureAvailable()) return;
      var matched = false;
      await _stt.listenOnce(
        language: widget.language,
        onResult: (text, isFinal) {
          if (!mounted || !isFinal || generation != _stepGeneration || matched) return;
          for (final entry in matchers.entries) {
            if (_fuzzyMatches(text, entry.key)) {
              matched = true;
              entry.value();
              return;
            }
          }
        },
      );
      if (matched || !mounted || generation != _stepGeneration) return;
      // A brief gap before re-listening — otherwise a run of pure silence
      // (nobody speaking at all) would restart the session back-to-back
      // with no pause, which reads as the mic never actually stopping.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Loose match, not an exact substring check: live testing showed the
  /// recognizer finalizing a near-miss of the target label often enough
  /// that requiring an exact match silently rejected a clear, correct
  /// attempt (e.g. "চলাচলে বাধা" heard back as "চলে বাধা" — a dropped
  /// syllable, unambiguous intent, but not a literal substring either way).
  /// Falls through, in order: exact substring either direction, then a
  /// majority of the label's own words each found via a partial (not just
  /// whole-word) overlap against what was heard.
  bool _fuzzyMatches(String heard, String label) {
    final heardTrim = heard.trim();
    final labelTrim = label.trim();
    if (heardTrim.isEmpty) return false;
    if (heardTrim.toLowerCase().contains(labelTrim.toLowerCase()) || heardTrim.contains(labelTrim)) return true;
    final words = labelTrim.split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
    if (words.isEmpty) return false;
    var matchedWords = 0;
    for (final word in words) {
      if (heardTrim.contains(word)) {
        matchedWords++;
        continue;
      }
      final minLen = (word.length * 0.6).ceil().clamp(2, word.length);
      for (var i = 0; i <= word.length - minLen; i++) {
        if (heardTrim.contains(word.substring(i, i + minLen))) {
          matchedWords++;
          break;
        }
      }
    }
    return matchedWords >= (words.length / 2).ceil();
  }

  /// The final step's listener does double duty: accumulates dictated
  /// description across as many separate utterances as the user needs
  /// (see `_committedDescription` — a pause to think isn't "done talking"),
  /// and recognizes a "submit" voice command to auto-submit — either using
  /// what was just dictated (phrase stripped off the end) or, if the whole
  /// utterance *was* just the submit phrase, everything accumulated so
  /// far. Loops indefinitely otherwise, same reasoning as `_listenForOption`:
  /// a single narrow window isn't enough for someone who may stumble or
  /// need a moment.
  ///
  /// Deliberately speaks a short, separate prompt between each committed
  /// utterance and the next listen — not just silently re-listening.
  /// Confirmed live as a real reliability problem without this: asking the
  /// recognizer to decide "was that whole long, run-on utterance a
  /// description, or does it end with a submit command?" in one pass was
  /// inconsistent, especially in Bangla. A short, explicit re-prompt gives
  /// every "was that a submit?" decision its own clean, short listening
  /// window instead, and doubles as the "still listening" cue the user
  /// asked for directly.
  Future<void> _listenForDescriptionOrSubmit(int generation) async {
    var first = true;
    while (mounted && generation == _stepGeneration) {
      if (!first) await _speak(_d.crowdsourceContinueOrSubmitSpoken);
      first = false;
      if (!mounted || generation != _stepGeneration) return;
      if (!await _stt.ensureAvailable()) return;
      var submitted = false;
      await _stt.listenOnce(
        language: widget.language,
        onResult: (text, isFinal) {
          if (!mounted || generation != _stepGeneration) return;
          if (!isFinal) {
            _updateDescriptionLive(text);
            return;
          }
          final extracted = _extractSubmitIntent(text);
          if (extracted == null) {
            _commitToDescription(text);
            return;
          }
          if (extracted.isNotEmpty) _commitToDescription(extracted);
          // Same fix as PasserbyMessagePicker: the live preview holds the
          // submit phrase itself, and without this it is filed as part of
          // the hazard description.
          _resetDescriptionToCommitted();
          if (!_isOther || _descriptionController.text.trim().isNotEmpty) {
            submitted = true;
            _submit(fromVoice: true);
          } else {
            _speak(_d.crowdsourceDescribePromptSpoken);
          }
        },
      );
      if (submitted || !mounted || generation != _stepGeneration) return;
    }
  }

  /// Live preview while an utterance is still in progress — shows what's
  /// already been committed plus whatever's being said right now, without
  /// committing the in-progress part yet (it might still change before
  /// `isFinal`).
  void _updateDescriptionLive(String livePartial) {
    final combined =
        [_committedDescription, livePartial].where((s) => s.trim().isNotEmpty).join(' ').trim();
    _descriptionController.text = combined;
    _descriptionController.selection = TextSelection.collapsed(offset: combined.length);
  }

  /// Drops any uncommitted live preview — see [_updateDescriptionLive].
  void _resetDescriptionToCommitted() {
    _descriptionController.text = _committedDescription;
    _descriptionController.selection =
        TextSelection.collapsed(offset: _committedDescription.length);
  }

  void _commitToDescription(String finalizedText) {
    final trimmed = finalizedText.trim();
    if (trimmed.isEmpty) return;
    _committedDescription = [_committedDescription, trimmed].where((s) => s.isNotEmpty).join(' ');
    _descriptionController.text = _committedDescription;
    _descriptionController.selection = TextSelection.collapsed(offset: _committedDescription.length);
  }

  // Bare roots (not full phrases) — used only as a *short-utterance*
  // fallback below, since a root alone is too loose to safely apply to a
  // long, free-form description that might happen to mention something
  // similar in passing.
  static const _submitRootsEn = ['submit', 'send', 'done', 'finish'];
  static const _submitRootsBn = ['পাঠা', 'সাবমিট', 'সেন্ড', 'শেষ'];

  /// Returns the description text with a trailing submit phrase stripped
  /// off (possibly empty, meaning "submit whatever was already there"), or
  /// `null` if [text] doesn't contain a submit command at all.
  String? _extractSubmitIntent(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final lower = trimmed.toLowerCase();
    for (final phrase in _submitPhrasesEn) {
      if (lower == phrase) return '';
      if (lower.endsWith(phrase)) return trimmed.substring(0, trimmed.length - phrase.length).trim();
    }
    for (final phrase in _submitPhrasesBn) {
      if (trimmed == phrase) return '';
      if (trimmed.endsWith(phrase)) return trimmed.substring(0, trimmed.length - phrase.length).trim();
    }
    // Short-utterance fuzzy fallback: `_listenForDescriptionOrSubmit` asks
    // a short, dedicated "say more, or say submit" question right before
    // each listen, so a *short* reply containing a submit root is almost
    // certainly the whole answer to that question, not a coincidental
    // mention buried in a longer description — safe to treat as pure-submit
    // even without an exact phrase match. Confirmed live as needed: a
    // recognizer near-miss on the full phrase (same class of issue
    // `_fuzzyMatches` exists for) was making this inconsistent.
    if (trimmed.split(RegExp(r'\s+')).length <= 3) {
      if (_submitRootsEn.any(lower.contains) || _submitRootsBn.any(trimmed.contains)) return '';
    }
    return null;
  }

  /// Files the report.
  ///
  /// [fromVoice] reports came through dictation, so the user has never seen
  /// what was transcribed and gets a read-back plus a window to stop it
  /// (see [VoiceCancelWindow]). A tap on the Submit button does not: the
  /// text is on screen, the person tapping it has already read it, and
  /// interrupting them to say it back out loud would be noise.
  Future<void> _submit({required bool fromVoice}) async {
    final rawDescription = _descriptionController.text.trim();
    if (_isOther && rawDescription.isEmpty) return;

    if (fromVoice) {
      final hazard = _d.hazardSubCategoryLabel(_subCategoryKey!);
      final readBack = rawDescription.isEmpty
          ? _d.cancelWindowReadBack(hazard)
          : _d.cancelWindowReadBack('$hazard. $rawDescription');
      final outcome = await VoiceCancelWindow.run(
        tts: _tts,
        stt: _stt,
        language: widget.language,
        readBack: readBack,
        isCancelled: () => !mounted,
      );
      if (!mounted) return;
      switch (outcome) {
        case CancelWindowOutcome.cancelled:
          await _speak(_d.cancelWindowCancelled);
          return;
        case CancelWindowOutcome.edit:
          // Clear and re-ask rather than appending to what was misheard —
          // the user said it was wrong, so keeping it would mean they have
          // to somehow talk their way out of text they cannot see.
          _descriptionController.clear();
          if (!mounted) return;
          setState(() {});
          // Re-narrates the final step and reopens dictation. Bumping the
          // generation happens inside, which also cancels the listener this
          // cancel window was itself running under.
          unawaited(_narrateAndListenForStep());
          return;
        case CancelWindowOutcome.proceed:
          break;
      }
      if (!mounted) return;
    }

    setState(() => _submitting = true);
    double? lat;
    double? lng;
    try {
      final position = await Geolocator.getCurrentPosition();
      lat = position.latitude;
      lng = position.longitude;
    } catch (_) {
      // Location is best-effort — a report without coordinates is still useful.
    }
    try {
      await ref.read(hazardReportServiceProvider).submitReport(HazardReport(
            reporterUid: widget.reporterUid,
            category: _category!,
            subCategory: _subCategoryKey!,
            description: _isOther ? summarizeText(rawDescription) : rawDescription,
            lat: lat,
            lng: lng,
          ));
      if (!mounted) return;
      // Spoken before popping, not just shown in a SnackBar afterward — a
      // blind user relying on this whole flow being voice-first can't see
      // that SnackBar at all (see the class doc comment).
      unawaited(_speak(_d.crowdsourceSubmitSuccess));
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_d.crowdsourceSubmitSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      unawaited(_speak(_d.crowdsourceSubmitError('$e')));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_d.crowdsourceSubmitError('$e'))),
      );
    }
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_d.crowdsourceVoiceUnavailable)));
      return;
    }
    setState(() => _listening = true);
    await _stt.listenOnce(
      language: widget.language,
      onResult: (text, isFinal) {
        // `mounted` must gate the whole callback, not just the final
        // `setState` — a pending listen session can still deliver a result
        // after this widget is gone (same crash class confirmed live in
        // the passerby message picker: writing into a disposed controller).
        if (!mounted) return;
        // Accumulates onto whatever was already dictated (see
        // `_committedDescription`) rather than replacing it — a manual
        // second tap to add more shouldn't erase the first pass.
        if (isFinal) {
          _commitToDescription(text);
          setState(() => _listening = false);
        } else {
          _updateDescriptionLive(text);
        }
      },
    );
    if (mounted) setState(() => _listening = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(color: Colors.black.withValues(alpha: 0.35)),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: 480,
                  maxHeight: MediaQuery.sizeOf(context).height * 0.85,
                ),
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.98),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_category != null)
                          Semantics(
                            button: true,
                            label: _d.crowdsourceBackSemantics,
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_rounded),
                              onPressed: () {
                                if (_subCategoryKey != null) {
                                  _goToSubCategory(null);
                                } else {
                                  _goToCategory(null);
                                }
                              },
                            ),
                          ),
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(_titleFor(), style: theme.textTheme.headlineSmall),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: _d.crowdsourceCloseSemantics,
                          child: IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        child: _category == null
                            ? _buildCategoryGrid(theme)
                            : _subCategoryKey == null
                                ? _buildSubCategoryList(theme)
                                : _buildDescriptionForm(theme),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _titleFor() {
    if (_isOther) return _d.crowdsourceDescribeItTitle;
    if (_subCategoryKey != null) return _d.hazardSubCategoryLabel(_subCategoryKey!);
    if (_category != null) return _d.hazardCategoryLabel(_category!);
    return _d.crowdsourceTitle;
  }

  Widget _buildCategoryGrid(ThemeData theme) {
    const icons = {
      HazardCategory.crime: Icons.local_police_rounded,
      HazardCategory.roadHazard: Icons.construction_rounded,
      HazardCategory.accessibilityBlock: Icons.accessible_forward_rounded,
    };
    return Column(
      children: HazardCategory.values.map((category) {
        final label = _d.hazardCategoryLabel(category);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            button: true,
            label: label,
            child: Material(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => _goToCategory(category),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
                  child: Row(
                    children: [
                      Icon(icons[category], color: theme.colorScheme.primary, size: 32),
                      const SizedBox(width: 16),
                      Text(label, style: theme.textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSubCategoryList(ThemeData theme) {
    final keys = _orderedSubCategoryKeys(_category!);
    return Column(
      children: keys.map((key) {
        final isOtherOption = _d.isOtherSubCategoryKey(key);
        final label = _d.hazardSubCategoryLabel(key);
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Semantics(
            button: true,
            label: label,
            child: Material(
              color: theme.scaffoldBackgroundColor,
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _goToSubCategory(key),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: [
                      if (isOtherOption) ...[
                        Icon(Icons.edit_note_rounded, size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Text(
                          label,
                          style: isOtherOption
                              ? theme.textTheme.titleSmall?.copyWith(fontStyle: FontStyle.italic)
                              : theme.textTheme.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildDescriptionForm(ThemeData theme) {
    final rawText = _descriptionController.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _isOther ? _d.crowdsourceDescribeHint : _d.crowdsourceOptionalDetails,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                textField: true,
                label: _d.crowdsourceDescriptionFieldSemantics,
                child: TextField(
                  controller: _descriptionController,
                  maxLines: 3,
                  decoration: InputDecoration(hintText: _d.crowdsourceDescriptionHint),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: _listening ? _d.chatListeningSemantics : _d.crowdsourceSpeakSemantics,
              hint: _d.chatSpeakHint,
              liveRegion: _listening,
              child: Material(
                color: _listening ? theme.colorScheme.error : theme.colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _toggleListening,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded, color: Colors.white, size: 20),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_isOther && rawText.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Semantics(
              liveRegion: true,
              label: '${_d.crowdsourceAiSummaryLabel}: ${summarizeText(rawText)}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        _d.crowdsourceAiSummaryLabel,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(summarizeText(rawText), style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitting || (_isOther && rawText.isEmpty)
                ? null
                : () => _submit(fromVoice: false),
            child: _submitting
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                  )
                : Text(_d.crowdsourceSubmitButton),
          ),
        ),
      ],
    );
  }
}
