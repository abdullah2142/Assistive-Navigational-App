import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../screens/map_pin_picker_screen.dart';
import 'destination_sheet.dart';

/// Opens the map picker and writes what was chosen into [controller].
///
/// Split out from [PlacePickerField] because onboarding already has its own
/// dictation button wired into that screen's voice loop, and replacing the
/// whole row there would mean either two microphones or unpicking a flow
/// that works. This is just the map half, to sit beside whatever else a
/// screen already offers.
///
/// The map is the only one of the three input methods that cannot produce a
/// plausible-looking wrong answer: a misheard address and a mistyped one
/// both look like addresses, where a pin is either on the right building or
/// visibly not.
class MapPickButton extends StatelessWidget {
  const MapPickButton({
    super.key,
    required this.controller,
    required this.language,
    this.onPicked,
  });

  final TextEditingController controller;
  final AppLanguage language;

  /// Called with the point when one was pinned, for callers that store
  /// coordinates alongside the name.
  final void Function(LatLng point, String label)? onPicked;

  Future<void> _pick(BuildContext context) async {
    LatLng? centre;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) centre = LatLng(last.latitude, last.longitude);
    } catch (e) {
      // Opening over Dhaka is a worse starting point than opening over the
      // user, and a far better one than not opening at all.
      debugPrint('[MapPickButton] no last-known position: $e');
    }
    if (!context.mounted) return;

    final picked = await Navigator.of(context).push<DestinationChoice>(
      MaterialPageRoute(
        builder: (_) => MapPinPickerScreen(language: language, initialCentre: centre),
      ),
    );
    if (picked == null) return;

    final name = picked.text?.trim() ?? '';
    if (name.isNotEmpty) controller.text = name;
    if (picked.isPin) {
      onPicked?.call(LatLng(picked.latitude!, picked.longitude!), name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(language);
    return Semantics(
      button: true,
      label: d.pathPinOnMap,
      hint: d.pathPinOnMapHint,
      child: IconButton.filledTonal(
        onPressed: () => _pick(context),
        icon: const Icon(Icons.map_rounded),
        tooltip: d.pathPinOnMap,
      ),
    );
  }
}
