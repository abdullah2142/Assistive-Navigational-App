import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
// Both map packages export clashing names (`Polyline`, `Marker`,
// `LatLngBounds`, `MapController`, ...) — `flutter_map`'s stay unprefixed
// (this file's primary map widget now), `google_maps_flutter`'s go through
// `gmaps.` except `LatLng` itself, which stays bare since `RouteChoice.points`
// (defined in `route_planning_service.dart`, which imports the *unprefixed*
// package) is typed with it — keeping it unprefixed here too avoids needing
// `gmaps.LatLng` everywhere this widget touches route/location data.
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/config/maps_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/services/route_planning_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/map_unavailable_placeholder.dart';
import '../providers/chat_providers.dart';

/// "Clean" map style — strips POI/transit labels and icons so the only
/// things drawn are the base road network, the route line, and the safety
/// overlays layered on top by later modules (see UI module plan Step 2.2).
/// Google Maps-only (its JSON map-style format) — the OSM tile path below
/// has no equivalent styling hook, since it's just pre-rendered raster
/// tiles from the public server, not a vector style this app controls.
const String _cleanMapStyle = '''
[
  {"featureType": "poi", "elementType": "labels", "stylers": [{"visibility": "off"}]},
  {"featureType": "poi", "elementType": "geometry", "stylers": [{"visibility": "off"}]},
  {"featureType": "transit", "elementType": "labels", "stylers": [{"visibility": "off"}]},
  {"featureType": "road", "elementType": "labels.icon", "stylers": [{"visibility": "off"}]}
]
''';

// Dhaka, Bangladesh — fallback camera center when device location is
// unavailable or permission is denied.
const LatLng _dhakaFallback = LatLng(23.8103, 90.4125);

/// Same User-Agent `RoutingService` already sends to Nominatim/OSRM —
/// OpenStreetMap's tile usage policy requires every request identify the
/// calling application the same way.
const String _osmUserAgent = 'ANT-AssistiveNavigationalApp/1.0 (+https://github.com/abdullah2142/Assistive-Navigational-App)';

ll.LatLng _toLL(LatLng p) => ll.LatLng(p.latitude, p.longitude);

/// The Interactive AI-Assisted Map — bottom 40% of the Split-Mode Dashboard.
///
/// Renders via free OpenStreetMap raster tiles whenever
/// [MapsConfig.useOsmTiles] is on. That flag is purely about the *picture*
/// and is independent of `RoutingConfig`, which decides who answers
/// geocoding and directions — the app can draw OSM tiles while Google
/// plans the route, and during the Google migration it does exactly that.
/// Falls back to the original `GoogleMap` widget when the flag is off —
/// nothing else about this widget's route/location logic
/// changes either way, both paths consume the same backend-agnostic
/// `RouteChoice.points`.
class DashboardMapPanel extends ConsumerStatefulWidget {
  const DashboardMapPanel({
    super.key,
    required this.language,
    this.isFullScreen = false,
    this.onToggleFullScreen,
  });

  final AppLanguage language;

  /// Whether the parent (`SplitModeDashboardScreen`) is currently showing
  /// this panel expanded over the whole body instead of its usual 40% —
  /// only affects which icon/label the toggle button shows, the actual
  /// expand/collapse is the parent's job (it owns the split layout).
  final bool isFullScreen;

  /// Null hides the toggle button entirely — used nowhere today, but keeps
  /// this widget usable somewhere that doesn't want the control (e.g. if
  /// it's ever embedded read-only elsewhere).
  final VoidCallback? onToggleFullScreen;

  @override
  ConsumerState<DashboardMapPanel> createState() => _DashboardMapPanelState();
}

class _DashboardMapPanelState extends ConsumerState<DashboardMapPanel> {
  LatLng? _myLocation;
  gmaps.GoogleMapController? _mapController;
  final MapController _osmController = MapController();

  @override
  void initState() {
    super.initState();
    if (MapsConfig.useOsmTiles || MapsConfig.isConfigured) {
      _resolveLocation();
    }
  }

  Future<void> _resolveLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return;
      }
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() => _myLocation = LatLng(position.latitude, position.longitude));
      if (MapsConfig.useOsmTiles && _lastFittedRoute == null) {
        // Deferred a frame: `initialCenter` is read once at construction, and
        // the fix is on the location arriving afterwards — which on a real
        // device it always does (confirmed from a device log: two builds at
        // `myLocation=null` before the first fix landed). If that fix happens
        // to arrive before `FlutterMap` has attached this controller, moving
        // it now is silently lost and the user is left looking at the
        // city-centre fallback.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _lastFittedRoute != null) return;
          _osmController.move(_toLL(_myLocation!), _myLocationZoom);
        });
      }
    } catch (_) {
      // Graceful degradation — the map just falls back to the Dhaka default.
    }
  }

  /// Zoom used when the camera is showing *where the user is* rather than a
  /// whole route.
  ///
  /// Was 16, which frames a neighbourhood — several hundred metres across,
  /// with the user a dot in it. That is the wrong scale for this map's
  /// actual job: it is read over the user's shoulder by a caretaker, or
  /// glanced at by a low-vision user, to answer "where am I and what is
  /// immediately around me". 17.5 puts individual street names and the
  /// footpath the route follows at legible size.
  static const double _myLocationZoom = 17.5;

  RouteChoice? _lastFittedRoute;

  void _fitCameraToRoute(RouteChoice route) {
    if (identical(route, _lastFittedRoute)) return;
    _lastFittedRoute = route;
    var minLat = route.points.first.latitude, maxLat = route.points.first.latitude;
    var minLng = route.points.first.longitude, maxLng = route.points.first.longitude;
    for (final p in route.points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    final southwest = LatLng(minLat, minLng);
    final northeast = LatLng(maxLat, maxLng);
    if (MapsConfig.useOsmTiles) {
      _osmController.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(_toLL(southwest), _toLL(northeast)),
        padding: const EdgeInsets.all(48),
      ));
    } else {
      _mapController?.animateCamera(
        gmaps.CameraUpdate.newLatLngBounds(gmaps.LatLngBounds(southwest: southwest, northeast: northeast), 48),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.language);
    final route = ref.watch(chatControllerProvider.select((s) => s.pendingRoute));
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitCameraToRoute(route));
    }

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      // LayoutBuilder + explicit SizedBox rather than Positioned.fill:
      // google_maps_flutter's web platform view sometimes bakes in a stale
      // (narrower) size when it only ever sees "fill your parent" instead
      // of an explicit pixel size, leaving the map rendered in a strip down
      // the middle instead of the full panel width.
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: _buildMap(route),
                ),
                // Massive Directional Overlay — Module 4 is the first module
                // to feed this real turn instructions (Module 2's own note:
                // previously always a static "forward" arrow). Rotates to
                // the active route's initial bearing; stays pointing north
                // (unrotated) with no route active, same as before.
                Semantics(
                  label: route == null
                      ? d.mapNextDirection
                      : d.mapRouteStatus(
                          safe: route.verdict.safe,
                          wasRerouted: route.wasRerouted,
                          distanceMeters: route.distanceMeters,
                        ),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(18),
                    child: Transform.rotate(
                      angle: (route?.initialBearingDegrees ?? 0) * math.pi / 180,
                      child: const Icon(Icons.north_rounded, color: Colors.white, size: 56),
                    ),
                  ),
                ),
                if (widget.onToggleFullScreen != null)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: Semantics(
                      button: true,
                      label: widget.isFullScreen ? d.mapCollapseSemantics : d.mapExpandSemantics,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: widget.onToggleFullScreen,
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Icon(
                              widget.isFullScreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildMap(RouteChoice? route) {
    final d = Dashboard.of(widget.language);
    debugPrint('[Map] building — openStreetMap=${MapsConfig.useOsmTiles} '
        'mapsConfigured=${MapsConfig.isConfigured} myLocation=$_myLocation');
    if (MapsConfig.useOsmTiles) {
      return FlutterMap(
        mapController: _osmController,
        options: MapOptions(
          initialCenter: _toLL(_myLocation ?? _dhakaFallback),
          initialZoom: _myLocationZoom,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.ant.assistive.ant_app',
            // Tile failures were completely silent — a map that renders no
            // tiles looks identical to a map that was never asked to, and
            // "the dashboard shows a blank placeholder" was reported with
            // nothing in the logs to explain it. The tile server itself
            // answers 200 to this exact User-Agent (verified directly), so
            // whatever goes wrong is client-side and needs to say so.
            errorTileCallback: (tile, error, stackTrace) {
              debugPrint('[Map] tile failed ${tile.coordinates}: $error');
            },
            // Drop failed tiles from the cache so a transient failure isn't
            // remembered as a permanent grey square.
            evictErrorTileStrategy: EvictErrorTileStrategy.dispose,
            // Deliberately not a `const` map — `flutter_map`'s tile
            // provider mutates the headers map it's given internally
            // (confirmed live: "Unsupported operation: Cannot modify
            // unmodifiable map" crash with a const literal here).
            tileProvider: NetworkTileProvider(headers: {'User-Agent': _osmUserAgent}),
          ),
          if (route != null)
            PolylineLayer(polylines: [
              Polyline(
                points: route.points.map(_toLL).toList(),
                strokeWidth: 5,
                color: route.verdict.safe ? AppColors.success : AppColors.caution,
              ),
            ]),
          if (_myLocation != null)
            MarkerLayer(markers: [
              Marker(
                point: _toLL(_myLocation!),
                width: 28,
                height: 28,
                child: const Icon(Icons.circle, color: Colors.blue, size: 16),
              ),
            ]),
        ],
      );
    }
    if (!MapsConfig.isConfigured) {
      return MapUnavailablePlaceholder(message: d.mapLiveViewLabel, subtitle: d.mapUnavailableSubtitle);
    }
    return gmaps.GoogleMap(
      initialCameraPosition:
          gmaps.CameraPosition(target: _myLocation ?? _dhakaFallback, zoom: _myLocationZoom),
      style: _cleanMapStyle,
      myLocationEnabled: true,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: false,
      compassEnabled: false,
      mapToolbarEnabled: false,
      onMapCreated: (controller) {
        _mapController = controller;
        if (route != null) _fitCameraToRoute(route);
      },
      polylines: route == null
          ? const {}
          : {
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('active_route'),
                points: route.points,
                width: 5,
                color: route.verdict.safe ? AppColors.success : AppColors.caution,
              ),
            },
    );
  }
}
