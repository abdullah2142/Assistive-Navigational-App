import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/config/maps_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/routing_service.dart';
import '../../../core/services/place_categories.dart';
import '../../../core/widgets/google_places_attribution.dart';
import '../../../core/widgets/map_unavailable_placeholder.dart';
import '../../onboarding/models/saved_place.dart';
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
    this.savedPlaces = const [],
  });

  final AppLanguage language;

  /// Injectable so the search bar can be exercised without a network.
  final RoutingService? routing;
  final List<SavedPlace> savedPlaces;

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
  List<PlacePrediction> _results = const [];
  String _placesSessionToken = newPlacesSessionToken();
  bool _searching = false;
  bool _resolving = false;
  bool _programmaticCameraMove = false;
  List<NearbyRefuge> _nearbyPlaces = const [];

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
      var found = await _routing.autocompletePlaces(
        query,
        sessionToken: _placesSessionToken,
        origin: gmaps.LatLng(_centre.latitude, _centre.longitude),
        languageCode: widget.language.name == 'bangla' ? 'bn' : 'en',
        limit: 5,
      );
      if (found.isEmpty) {
        // Address-only queries can still use Google's address geocoder (or
        // the configured OSM fallback) when Places has no prediction.
        final addresses = await _routing.geocodeCandidates(query, limit: 5);
        if (!mounted) return;
        setState(() {
          _results = const [];
          _legacyResults = addresses;
        });
        if (addresses.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(Dashboard.of(widget.language).pathSearchNoResults),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _legacyResults = const [];
        _results = found;
      });
    } catch (e) {
      debugPrint('[MapPicker] search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  List<GeocodeCandidate> _legacyResults = const [];

  Future<void> _choosePrediction(PlacePrediction prediction) async {
    setState(() => _resolving = true);
    try {
      final candidate = await _routing.resolvePlacePrediction(
        prediction,
        sessionToken: _placesSessionToken,
      );
      if (!mounted) return;
      if (candidate != null) {
        _goTo(candidate);
        return;
      }
      final addresses = await _routing.geocodeCandidates(
        prediction.label,
        limit: 1,
      );
      if (addresses.isNotEmpty) _goTo(addresses.first);
    } catch (e) {
      debugPrint('[MapPicker] selected prediction failed: $e');
    } finally {
      // Place Details ends the current Autocomplete session. This screen stays
      // open, so a later search needs its own fresh token.
      _placesSessionToken = newPlacesSessionToken();
      if (mounted) setState(() => _resolving = false);
    }
  }

  /// Moves the map to a chosen result and adopts its name.
  void _goTo(GeocodeCandidate candidate) {
    setState(() {
      _centre = candidate.location;
      _centreLabel = candidate.label;
      _results = const [];
      _legacyResults = const [];
      _nearbyPlaces = const [];
      _search.text = candidate.spokenLabel;
    });
    if (MapsConfig.useOsmTiles) {
      _osmController.move(_toLL(candidate.location), _initialZoom);
    } else {
      final controller = _googleController;
      if (controller != null) {
        _programmaticCameraMove = true;
        controller
            .animateCamera(
              gmaps.CameraUpdate.newLatLngZoom(
                candidate.location,
                _initialZoom,
              ),
            )
            .whenComplete(() => _programmaticCameraMove = false);
      }
    }
  }

  gmaps.GoogleMapController? _googleController;

  Set<gmaps.Marker> get _googleMarkers => {
    for (final place in widget.savedPlaces)
      if (place.hasCoordinates)
        gmaps.Marker(
          markerId: gmaps.MarkerId('saved:${place.label}'),
          position: gmaps.LatLng(place.lat!, place.lng!),
          infoWindow: gmaps.InfoWindow(title: place.label),
          onTap: () => _goTo(
            GeocodeCandidate(
              label: place.label,
              location: gmaps.LatLng(place.lat!, place.lng!),
            ),
          ),
        ),
    for (var i = 0; i < _nearbyPlaces.length; i++)
      gmaps.Marker(
        markerId: gmaps.MarkerId('nearby:$i'),
        position: _nearbyPlaces[i].location,
        infoWindow: gmaps.InfoWindow(title: _nearbyPlaces[i].name),
        onTap: () => _goTo(
          GeocodeCandidate(
            label: _nearbyPlaces[i].name,
            location: _nearbyPlaces[i].location,
          ),
        ),
      ),
  };

  ll.LatLng _toLL(gmaps.LatLng p) => ll.LatLng(p.latitude, p.longitude);

  /// Returns the point, and the name if the search found one.
  ///
  /// The name matters as much as the point for a *saved* place: "Rayer
  /// Bazar" is something the user can say back to the assistant later, where
  /// a pair of coordinates is not. A pin dropped by panning alone has no
  /// name and that is fine — the caller falls back to whatever the user
  /// typed.
  Future<void> _confirm() async {
    if (_resolving) return;
    setState(() => _resolving = true);
    var label = _centreLabel.trim();
    if (label.isEmpty) {
      try {
        final found = await _routing
            .describeLocation(_centre)
            .timeout(const Duration(seconds: 6));
        label = found?.spokenLabel ?? '';
      } catch (e) {
        debugPrint('[MapPicker] reverse geocode failed: $e');
      }
    }
    if (!mounted) return;
    setState(() => _resolving = false);
    final d = Dashboard.of(widget.language);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(d.pathPinConfirm),
        content: Text(
          label.isEmpty
              ? d.pathPinConfirmUnknown
              : d.pathPinConfirmPrompt(label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(d.pathPinUsePoint),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    Navigator.of(context).pop(
      DestinationChoice(
        method: DestinationMethod.pinned,
        text: label.isEmpty ? null : label,
        latitude: _centre.latitude,
        longitude: _centre.longitude,
      ),
    );
  }

  Future<void> _openMapMenu(Dashboard d) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                d.pathMapMenu,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (widget.savedPlaces.isNotEmpty) ...[
              ListTile(title: Text(d.pathSavedPlaces)),
              for (final place in widget.savedPlaces)
                ListTile(
                  leading: const Icon(Icons.bookmark_outline_rounded),
                  title: Text(place.label),
                  subtitle: place.address.isEmpty ? null : Text(place.address),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _selectSavedPlace(place);
                  },
                ),
            ],
            ListTile(title: Text(d.pathNearbyPlaces)),
            for (final category in placeCategories)
              ListTile(
                leading: const Icon(Icons.near_me_outlined),
                title: Text(d.pathCategoryLabel(category.id)),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _loadNearby(category, d);
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectSavedPlace(SavedPlace place) async {
    if (place.hasCoordinates) {
      _goTo(
        GeocodeCandidate(
          label: place.label,
          location: gmaps.LatLng(place.lat!, place.lng!),
        ),
      );
      return;
    }
    final address = place.address.trim();
    if (address.isEmpty) return;
    try {
      final matches = await _routing.geocodeCandidates(address);
      if (!mounted) return;
      if (matches.isNotEmpty) {
        _goTo(
          GeocodeCandidate(
            label: place.label,
            location: matches.first.location,
          ),
        );
      }
    } catch (e) {
      debugPrint('[MapPicker] saved place lookup failed: $e');
    }
  }

  Future<void> _loadNearby(PlaceCategory category, Dashboard d) async {
    setState(() {
      _searching = true;
    });
    try {
      final places = await _routing.nearbyOfCategory(
        origin: _centre,
        category: category,
      );
      if (!mounted) return;
      setState(() {
        _nearbyPlaces = places;
        _searching = false;
      });
      if (places.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(d.pathSearchNoResults)));
        return;
      }
      await showModalBottomSheet<void>(
        context: context,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(title: Text(d.pathCategoryLabel(category.id))),
              for (final place in places)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(
                    place.name.isEmpty
                        ? d.pathCategoryLabel(category.id)
                        : place.name,
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _goTo(
                      GeocodeCandidate(
                        label: place.name.isEmpty
                            ? d.pathCategoryLabel(category.id)
                            : place.name,
                        location: place.location,
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('[MapPicker] nearby lookup failed: $e');
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.language);
    return Scaffold(
      appBar: AppBar(
        title: Text(d.pathPinOnMap),
        actions: [
          IconButton(
            tooltip: d.pathMapMenu,
            onPressed: () => _openMapMenu(d),
            icon: const Icon(Icons.menu_rounded),
          ),
        ],
      ),
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
                  child: Icon(
                    Icons.place_rounded,
                    size: 48,
                    color: AppColors.danger,
                  ),
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
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
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
                      if (_results.isNotEmpty || _legacyResults.isNotEmpty)
                        Card(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      0,
                                      8,
                                      12,
                                      4,
                                    ),
                                    child: const GooglePlacesAttribution(),
                                  ),
                                ),
                                for (final r in _results)
                                  ListTile(
                                    dense: true,
                                    title: Text(r.mainText),
                                    subtitle: r.secondaryText.isEmpty
                                        ? null
                                        : Text(
                                            r.secondaryText,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                    onTap: () => _choosePrediction(r),
                                  ),
                                for (final r in _legacyResults)
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
                                _centreLabel.isEmpty
                                    ? d.pathPinInstruction
                                    : _centreLabel,
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
                    onPressed: _resolving ? null : _confirm,
                    icon: const Icon(Icons.directions_rounded),
                    label: _resolving
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(d.pathPinConfirm),
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
            _centre = gmaps.LatLng(
              camera.center.latitude,
              camera.center.longitude,
            );
            _centreLabel = '';
          },
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.ant.assistive.ant_app',
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
          ),
          MarkerLayer(
            markers: [
              for (final place in widget.savedPlaces)
                if (place.hasCoordinates)
                  Marker(
                    point: ll.LatLng(place.lat!, place.lng!),
                    width: 44,
                    height: 44,
                    child: IconButton(
                      tooltip: place.label,
                      onPressed: () => _goTo(
                        GeocodeCandidate(
                          label: place.label,
                          location: gmaps.LatLng(place.lat!, place.lng!),
                        ),
                      ),
                      icon: const Icon(
                        Icons.bookmark,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
              for (var i = 0; i < _nearbyPlaces.length; i++)
                Marker(
                  point: _toLL(_nearbyPlaces[i].location),
                  width: 44,
                  height: 44,
                  child: IconButton(
                    tooltip: _nearbyPlaces[i].name,
                    onPressed: () => _goTo(
                      GeocodeCandidate(
                        label: _nearbyPlaces[i].name,
                        location: _nearbyPlaces[i].location,
                      ),
                    ),
                    icon: const Icon(Icons.place, color: AppColors.danger),
                  ),
                ),
            ],
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
      initialCameraPosition: gmaps.CameraPosition(
        target: _centre,
        zoom: _initialZoom,
      ),
      onMapCreated: (c) => _googleController = c,
      markers: _googleMarkers,
      myLocationEnabled: true,
      myLocationButtonEnabled: true,
      zoomControlsEnabled: true,
      onCameraMoveStarted: () {
        if (!_programmaticCameraMove) _centreLabel = '';
      },
      onCameraMove: (position) => _centre = position.target,
    );
  }
}
