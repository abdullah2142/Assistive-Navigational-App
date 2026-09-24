import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/config/routing_config.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/dhaka_places.dart';
import '../../../core/services/earcon_service.dart';
import '../../../core/services/place_categories.dart';
import '../../../core/services/routing_service.dart';
import '../../../core/widgets/google_places_attribution.dart';
import '../../../core/services/stt_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../onboarding/models/user_profile.dart';

/// How the user named the place they want to go.
enum DestinationMethod { typed, spoken, saved, pinned }

/// What the sheet hands back.
class DestinationChoice {
  const DestinationChoice({
    required this.method,
    this.text,
    this.latitude,
    this.longitude,
  });

  final DestinationMethod method;

  /// The place as a name — set for everything except [DestinationMethod.pinned].
  final String? text;

  /// Set only for [DestinationMethod.pinned].
  final double? latitude;
  final double? longitude;

  bool get isPin => latitude != null && longitude != null;
}

/// The four ways of answering "where do you want to go?".
///
/// Replaces the old "Route to Work" chip, which named a destination the
/// profile never stored and so could only ever respond by asking the
/// question this sheet now asks with its answers attached.
///
/// ## Why four and not one
///
/// The app's users do not share an input channel. A blind user answers out
/// loud. A low-vision user types, at whatever text scale they have set. A
/// sighted companion helping at a kerb points at a map, which is both faster
/// than spelling a Dhaka thana name and immune to the recognizer mangling
/// it. And a place already saved should never need naming again. Offering
/// only the one that suits the author is how a control ends up unusable for
/// most of the people it was built for.
///
/// Every row is a full-width 56dp target with its own semantics label, and
/// the list is ordered by how little sight it needs: speak first.
class DestinationSheet extends ConsumerStatefulWidget {
  const DestinationSheet({
    super.key,
    required this.profile,
    required this.onPickOnMap,
    this.routing,
  });

  final UserProfile profile;

  /// Opens the map in pin-picking mode. Separate from this sheet because it
  /// needs the whole screen — a map inside a bottom sheet is too small to
  /// aim at, which defeats the one thing this option is for.
  final Future<DestinationChoice?> Function() onPickOnMap;
  final RoutingService? routing;

  @override
  ConsumerState<DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends ConsumerState<DestinationSheet> {
  final _controller = TextEditingController();
  bool _listening = false;
  Timer? _searchDebounce;
  int _searchGeneration = 0;
  bool _searching = false;
  List<PlacePrediction> _results = const [];
  List<GeocodeCandidate> _legacyResults = const [];
  late final String _placesSessionToken = newPlacesSessionToken();

  late final SttService _stt = ref.read(sttServiceProvider);
  // Use Places Autocomplete (New), biased to the user's current area. Resolve
  // only a selected prediction to coordinates, using its session token.
  late final RoutingService _routing =
      widget.routing ??
      RoutingService(
        backend: RoutingBackend.google,
        allowFallback: RoutingConfig.allowOsmFallback,
      );

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _submitTyped() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context)
        .pop(DestinationChoice(method: DestinationMethod.typed, text: text));
  }

  void _searchAsYouType(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    final generation = ++_searchGeneration;
    if (query.length < 2 || categoryFor(query) != null) {
      setState(() {
        _results = const [];
        _legacyResults = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        Position? fix;
        try {
          fix = await Geolocator.getLastKnownPosition().timeout(
            const Duration(milliseconds: 500),
          );
        } catch (_) {}
        final results = await _routing.autocompletePlaces(
          query,
          sessionToken: _placesSessionToken,
          origin: fix == null ? null : LatLng(fix.latitude, fix.longitude),
          languageCode: widget.profile.language.name == 'bangla' ? 'bn' : 'en',
          limit: 5,
        );
        final legacyResults = results.isEmpty
            ? await _routing.geocodeCandidates(query, limit: 5)
            : const <GeocodeCandidate>[];
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _results = results;
          _legacyResults = legacyResults;
          _searching = false;
        });
      } catch (e) {
        debugPrint('[DestinationSheet] suggestions unavailable: $e');
        if (!mounted || generation != _searchGeneration) return;
        setState(() {
          _results = const [];
          _legacyResults = const [];
          _searching = false;
        });
      }
    });
  }

  Future<void> _chooseCandidate(PlacePrediction prediction) async {
    _searchDebounce?.cancel();
    final generation = ++_searchGeneration;
    setState(() => _searching = true);
    GeocodeCandidate? candidate;
    try {
      candidate = await _routing.resolvePlacePrediction(
        prediction,
        sessionToken: _placesSessionToken,
      );
    } catch (e) {
      debugPrint('[DestinationSheet] selected place unavailable: $e');
    }
    if (!mounted || generation != _searchGeneration) return;
    if (candidate == null) {
      setState(() => _searching = false);
      Navigator.of(context).pop(
        DestinationChoice(
          method: DestinationMethod.typed,
          text: prediction.label,
        ),
      );
      return;
    }
    Navigator.of(context).pop(
      DestinationChoice(
        method: DestinationMethod.typed,
        text: candidate.spokenLabel,
        latitude: candidate.location.latitude,
        longitude: candidate.location.longitude,
      ),
    );
  }

  void _chooseLegacyCandidate(GeocodeCandidate candidate) {
    Navigator.of(context).pop(
      DestinationChoice(
        method: DestinationMethod.typed,
        text: candidate.spokenLabel,
        latitude: candidate.location.latitude,
        longitude: candidate.location.longitude,
      ),
    );
  }

  /// Speak the destination.
  ///
  /// Closes the sheet on a final result rather than filling the field and
  /// waiting for a second tap: the user who chose this row is the one least
  /// able to find a Send button afterwards.
  Future<void> _listen(Dashboard d) async {
    if (_listening) {
      await _stt.stop();
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
      return;
    }
    setState(() => _listening = true);
    unawaited(ref.read(earconServiceProvider).play(Earcon.listening));
    try {
      await _stt.listenOnce(
        language: widget.profile.language,
        // The same hints the main microphone uses. A destination said into
        // *this* field is a place name by definition, so the user's own
        // saved labels lead — what somebody calls their own home is a far
        // stronger hint than any gazetteer entry.
        phraseHints: placeNameHints(
          savedPlaceLabels: [
            for (final p in widget.profile.savedPlaces) p.label,
          ],
          homeAddress: widget.profile.homeAddress,
          safePlaceAddress: widget.profile.safePlaceAddress,
        ),
        onResult: (text, isFinal) {
          if (!mounted) return;
          _controller.text = text;
          _controller.selection = TextSelection.collapsed(offset: text.length);
          if (isFinal && text.trim().isNotEmpty) {
            Navigator.of(context).pop(
              DestinationChoice(
                method: DestinationMethod.spoken,
                text: text.trim(),
              ),
            );
          }
        },
      );
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.profile.language);
    final saved = widget.profile.savedPlaces;

    return SafeArea(
      child: Padding(
        // Clears the keyboard when the text field has focus, so the field
        // being typed into is never the thing hidden by what is typing into it.
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    d.pathSheetTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),

              // Typing, with the microphone on the same row.
              //
              // The field is the destination for both: a spoken result fills
              // it as it arrives, so a user who can see the screen watches
              // the recognizer work and can correct it before it is sent,
              // rather than discovering the mistake in the route.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        textField: true,
                        label: d.pathSearchLabel,
                        child: TextField(
                          controller: _controller,
                          autofocus: false,
                          textInputAction: TextInputAction.search,
                          onSubmitted: (_) => _submitTyped(),
                          onChanged: _searchAsYouType,
                          // Grows down the way the chat field does, so a long
                          // Dhaka address is read in full instead of scrolling
                          // sideways past the start of itself.
                          minLines: 1,
                          maxLines: 4,
                          keyboardType: TextInputType.multiline,
                          decoration: InputDecoration(
                            hintText: d.pathSearchHint,
                            prefixIcon: const Icon(Icons.search_rounded),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Semantics(
                      button: true,
                      label: d.pathSpeak,
                      hint: d.pathSpeakHint,
                      liveRegion: _listening,
                      child: Material(
                        color: _listening
                            ? AppColors.danger
                            : AppColors.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => unawaited(_listen(d)),
                          child: SizedBox(
                            width: 52,
                            height: 52,
                            child: Icon(
                              _listening
                                  ? Icons.mic_off_rounded
                                  : Icons.mic_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_results.isNotEmpty || _legacyResults.isNotEmpty)
                Card(
                  margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 220),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        if (_results.isNotEmpty)
                          Align(
                            alignment: Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(0, 8, 12, 4),
                              child: const GooglePlacesAttribution(),
                            ),
                          ),
                        for (final result in _results)
                          ListTile(
                            leading: const Icon(Icons.place_outlined),
                            title: Text(result.mainText),
                            subtitle: result.secondaryText.isEmpty
                                ? null
                                : Text(
                                    result.secondaryText,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            onTap: () => _chooseCandidate(result),
                          ),
                        for (final result in _legacyResults)
                          ListTile(
                            leading: const Icon(Icons.place_outlined),
                            title: Text(result.spokenLabel),
                            onTap: () => _chooseLegacyCandidate(result),
                          ),
                      ],
                    ),
                  ),
                ),

              const SizedBox(height: 8),
              _SheetRow(
                icon: Icons.push_pin_rounded,
                label: d.pathPinOnMap,
                hint: d.pathPinOnMapHint,
                onTap: () async {
                  final picked = await widget.onPickOnMap();
                  if (!context.mounted) return;
                  Navigator.of(context).pop(picked);
                },
              ),

              if (saved.isNotEmpty) ...[
                const Divider(height: 24),
                for (final place in saved)
                  _SheetRow(
                    icon: Icons.bookmark_rounded,
                    label: place.label,
                    onTap: () => Navigator.of(context).pop(
                      DestinationChoice(
                        method: DestinationMethod.saved,
                        text: place.label,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.hint,
  });

  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    hint: hint,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 24),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20),
          ],
        ),
      ),
    ),
  );
}
