import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/config/maps_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/map_unavailable_placeholder.dart';
import '../widgets/destination_sheet.dart';

/// Full-screen map for choosing a destination by pointing at it.
///
/// Its own screen rather than a mode on `DashboardMapPanel`, and rather than
/// a map inside the destination sheet: aiming at a point needs the whole
/// display. A map in a bottom sheet is a few hundred pixels of Dhaka, which
/// is about two blocks — not enough to find anywhere from, and small enough
/// that the fingertip covers the thing being chosen.
///
/// ## Centre-crosshair, not tap-to-drop
///
/// The pin is fixed at the centre and the *map* moves under it, which is how
/// every ride-hailing app does this and is not a style choice. A tap drops
/// the pin where the finger is, and the finger is the one thing on screen
/// that cannot be seen around — so a tap-to-drop map is aimed blind at the
/// last moment. Panning under a fixed crosshair keeps the target visible the
/// whole time, and it gives a low-vision user a target that stays in one
/// predictable place instead of wherever they last touched.
///
/// The confirm button is a single full-width control at the bottom, away
/// from the crosshair, so confirming cannot be mistaken for aiming.
class MapPinPickerScreen extends StatefulWidget {
  const MapPinPickerScreen({
    super.key,
    required this.language,
    this.initialCentre,
  });

  final AppLanguage language;

  /// Where to open. The user's own position when it is known — starting at
  /// a city-wide view means panning across Dhaka before the map is any use.
  final gmaps.LatLng? initialCentre;

  @override
  State<MapPinPickerScreen> createState() => _MapPinPickerScreenState();
}

class _MapPinPickerScreenState extends State<MapPinPickerScreen> {
  /// Matches `DashboardMapPanel`'s fallback, so the two never disagree about
  /// where Dhaka is.
  static const _dhakaFallback = gmaps.LatLng(23.8103, 90.4125);
  static const double _initialZoom = 16;

  late gmaps.LatLng _centre = widget.initialCentre ?? _dhakaFallback;

  final _osmController = MapController();

  ll.LatLng _toLL(gmaps.LatLng p) => ll.LatLng(p.latitude, p.longitude);

  void _confirm() => Navigator.of(context).pop(
        DestinationChoice(
          method: DestinationMethod.pinned,
          latitude: _centre.latitude,
          longitude: _centre.longitude,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.language);
    return Scaffold(
      appBar: AppBar(title: Text(d.pathPinOnMap)),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                _buildMap(d),
                // The crosshair. `IgnorePointer` so it never eats a pan
                // gesture aimed at the map underneath it — which would make
                // the exact centre of the screen the one place the map
                // cannot be dragged from.
                const IgnorePointer(
                  child: Icon(Icons.place_rounded, size: 48, color: AppColors.danger),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Semantics(
                    liveRegion: true,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(d.pathPinInstruction),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Semantics(
                button: true,
                label: d.pathPinConfirm,
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: _confirm,
                    icon: const Icon(Icons.directions_rounded),
                    label: Text(d.pathPinConfirm),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMap(Dashboard d) {
    if (MapsConfig.useOsmTiles) {
      return FlutterMap(
        mapController: _osmController,
        options: MapOptions(
          initialCenter: _toLL(_centre),
          initialZoom: _initialZoom,
          // Read at the end of every gesture rather than on every frame: the
          // value is only needed when Confirm is pressed, and setState per
          // frame of a pan is a lot of rebuilds for a number nobody is
          // reading yet.
          onPositionChanged: (camera, hasGesture) {
            if (!hasGesture) return;
            _centre = gmaps.LatLng(camera.center.latitude, camera.center.longitude);
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.ant.assistive.ant_app',
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
        ],
      );
    }
    if (!MapsConfig.isConfigured) {
      return MapUnavailablePlaceholder(
        message: d.mapLiveViewLabel,
        subtitle: d.mapUnavailableSubtitle,
      );
    }
    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(target: _centre, zoom: _initialZoom),
      myLocationEnabled: true,
      myLocationButtonEnabled: true,
      zoomControlsEnabled: true,
      onCameraMove: (position) => _centre = position.target,
    );
  }
}
