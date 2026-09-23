import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/localization/dashboard_strings.dart';
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/dhaka_places.dart';
import '../../../core/services/earcon_service.dart';
import '../../../core/services/stt_service.dart';
import '../../onboarding/models/user_profile.dart';
import '../screens/map_pin_picker_screen.dart';
import 'destination_sheet.dart';

/// One text field for naming a place, with the map and the microphone beside
/// it.
///
/// ## Why this exists as a shared widget
///
/// Every place this app stores was typed into a bare `TextField`: the home
/// address and the safe place in onboarding, the same two again in settings.
/// That is the one input method that suits the *fewest* of this app's users —
/// a blind user cannot check what the recognizer or the keyboard produced,
/// and a sighted helper setting the phone up for somebody has a map in their
/// pocket and no way to use it.
///
/// Asked for directly: adding a place you visit often should offer a full
/// search and pin-on-map interface for sighted users, alongside voice. The
/// route button already had one — `DestinationSheet` — and nothing else did.
///
/// ## What each control is for
///
/// Typing suits a low-vision user who knows the address. Speaking suits a
/// blind user, and fills the same field so a sighted helper can correct a
/// misheard word before it is saved. The map suits anyone who knows *where*
/// a place is without knowing what it is called, which in Dhaka is most
/// places — and it is the only one of the three that cannot produce a
/// plausible-looking wrong answer.
class PlacePickerField extends ConsumerStatefulWidget {
  const PlacePickerField({
    super.key,
    required this.controller,
    required this.profile,
    required this.label,
    this.hint,
    this.onPicked,
  });

  final TextEditingController controller;
  final UserProfile profile;
  final String label;
  final String? hint;

  /// Called when the map returns a point, so a caller that stores
  /// coordinates as well as a name can keep both. A saved place with
  /// coordinates needs no geocode later, which is the difference between a
  /// route that works offline and one that does not.
  final void Function(LatLng point, String label)? onPicked;

  @override
  ConsumerState<PlacePickerField> createState() => _PlacePickerFieldState();
}

class _PlacePickerFieldState extends ConsumerState<PlacePickerField> {
  bool _listening = false;
  late final SttService _stt = ref.read(sttServiceProvider);

  Future<void> _listen(Dashboard d) async {
    if (_listening) {
      await _stt.stop();
      return;
    }
    if (!await _stt.ensureAvailable()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(d.chatVoiceUnavailable)));
      return;
    }
    setState(() => _listening = true);
    unawaited(ref.read(earconServiceProvider).play(Earcon.listening));
    try {
      await _stt.listenOnce(
        language: widget.profile.language,
        // The same hints the main microphone uses. A Dhaka thana name is a
        // rare word that sounds like a common one, and the user's own saved
        // labels are a far stronger signal than any gazetteer.
        phraseHints: placeNameHints(
          savedPlaceLabels: [for (final p in widget.profile.savedPlaces) p.label],
          homeAddress: widget.profile.homeAddress,
          safePlaceAddress: widget.profile.safePlaceAddress,
        ),
        onResult: (text, isFinal) {
          if (!mounted) return;
          // Fills the field rather than committing. A sighted helper can see
          // what was heard and fix it; a blind user has it read back by the
          // screen reader before anything is saved.
          widget.controller.text = text;
          widget.controller.selection = TextSelection.collapsed(offset: text.length);
        },
      );
    } finally {
      if (mounted) setState(() => _listening = false);
    }
  }

  Future<void> _pickOnMap() async {
    LatLng? centre;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) centre = LatLng(last.latitude, last.longitude);
    } catch (e) {
      debugPrint('[PlacePicker] no last-known position: $e');
    }
    if (!mounted) return;

    final picked = await Navigator.of(context).push<DestinationChoice>(
      MaterialPageRoute(
        builder: (_) => MapPinPickerScreen(
          language: widget.profile.language,
          initialCentre: centre,
          savedPlaces: widget.profile.savedPlaces,
        ),
      ),
    );
    if (picked == null || !mounted) return;

    // A pin has coordinates and, usually, whatever the search named it. The
    // name goes in the field so the user can read back what they chose; the
    // point goes to the caller so the place never needs geocoding again.
    final name = picked.text?.trim() ?? '';
    if (name.isNotEmpty) widget.controller.text = name;
    if (picked.isPin) {
      widget.onPicked?.call(LatLng(picked.latitude!, picked.longitude!), name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.profile.language);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Semantics(
            textField: true,
            label: widget.label,
            child: TextField(
              controller: widget.controller,
              // Grows down rather than scrolling a long Dhaka address
              // sideways past its own beginning.
              minLines: 1,
              maxLines: 3,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                isDense: true,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Semantics(
          button: true,
          label: d.pathSpeak,
          hint: d.pathSpeakHint,
          liveRegion: _listening,
          child: IconButton.filledTonal(
            onPressed: () => unawaited(_listen(d)),
            icon: Icon(_listening ? Icons.mic_off_rounded : Icons.mic_rounded),
            tooltip: d.pathSpeak,
          ),
        ),
        const SizedBox(width: 4),
        Semantics(
          button: true,
          label: d.pathPinOnMap,
          hint: d.pathPinOnMapHint,
          child: IconButton.filledTonal(
            onPressed: () => unawaited(_pickOnMap()),
            icon: const Icon(Icons.map_rounded),
            tooltip: d.pathPinOnMap,
          ),
        ),
      ],
    );
  }
}
