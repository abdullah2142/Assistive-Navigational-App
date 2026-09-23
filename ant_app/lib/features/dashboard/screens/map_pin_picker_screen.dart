import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/config/maps_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/routing_service.dart';
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
    this.routing,
  });

  final AppLanguage language;

  /// Injectable so the search bar can be exercised without a network.
  final RoutingService? routing;

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
  final _search = TextEditingController();
  late final RoutingService _routing = widget.routing ?? RoutingService();

  /// Candidates for the current query, and whether one is in flight.
  List<GeocodeCandidate> _results = const [];
  bool _searching = false;

  /// What the crosshair is currently over, once it has been named. Shown
  /// under the search bar so the user can see what they are about to pick
  /// rather than discovering it on arrival.
  String _centreLabel = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Looks up whatever was typed and offers the matches.
  ///
  /// A list rather than jumping straight to the first hit. Dhaka has several
  /// of most things, and "Lab Aid" resolves to four different buildings —
  /// picking one silently is how somebody ends up walking to the wrong one
  /// with no way to tell until they arrive.
  Future<void> _runSearch() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    setState(() => _searching = true);
    try {
      final found = await _routing.geocodeCandidates(query);
      if (!mounted) return;
      setState(() => _results = found);
      if (found.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Dashboard.of(widget.language).pathSearchNoResults)),
        );
      }
    } catch (e) {
      debugPrint('[MapPicker] search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Moves the map to a chosen result and adopts its name.
  void _goTo(GeocodeCandidate candidate) {
    setState(() {
      _centre = candidate.location;
      _centreLabel = candidate.label;
      _results = const [];
      _search.text = candidate.spokenLabel;
    });
    if (MapsConfig.useOsmTiles) {
      _osmController.move(_toLL(candidate.location), _initialZoom);
    } else {
      _googleController?.animateCamera(
        gmaps.CameraUpdate.newLatLngZoom(candidate.location, _initialZoom),
      );
    }
  }

  gmaps.GoogleMapController? _googleController;

  ll.LatLng _toLL(gmaps.LatLng p) => ll.LatLng(p.latitude, p.longitude);

  /// Returns the point, and the name if the search found one.
  ///
  /// The name matters as much as the point for a *saved* place: "Rayer
  /// Bazar" is something the user can say back to the assistant later, where
  /// a pair of coordinates is not. A pin dropped by panning alone has no
  /// name and that is fine — the caller falls back to whatever the user
  /// typed.
  void _confirm() => Navigator.of(context).pop(
        DestinationChoice(
          method: DestinationMethod.pinned,
          text: _centreLabel.isEmpty ? null : _centreLabel,
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
                  child: Column(
                    children: [
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _search,
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: (_) => _runSearch(),
                                  decoration: InputDecoration(
                                    hintText: d.pathSearchHint,
                                    border: InputBorder.none,
                                    isDense: true,
                                  ),
                                ),
                              ),
                              if (_searching)
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                )
                              else
                                IconButton(
                                  icon: const Icon(Icons.search_rounded),
                                  tooltip: d.pathSearchLabel,
                                  onPressed: _runSearch,
                                ),
                            ],
                          ),
                        ),
                      ),
                      // Candidates, when a search found several. A list
                      // rather than jumping to the first hit: Dhaka has
                      // four Lab Aids, and picking one silently is how
                      // somebody walks to the wrong building with no way to
                      // tell until they arrive.
                      if (_results.isNotEmpty)
                        Card(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final r in _results)
                                  ListTile(
                                    dense: true,
                                    title: Text(r.spokenLabel),
                                    subtitle: Text(
                                      r.label,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () => _goTo(r),
                                  ),
                              ],
                            ),
                          ),
                        )
                      else
                        Semantics(
                          liveRegion: true,
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                _centreLabel.isEmpty ? d.pathPinInstruction : _centreLabel,
                              ),
                            ),
                          ),
                        ),
                    ],
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
      onMapCreated: (c) => _googleController = c,
      myLocationEnabled: true,
      myLocationButtonEnabled: true,
      zoomControlsEnabled: true,
      onCameraMove: (position) => _centre = position.target,
    );
  }
}
