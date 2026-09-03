import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

/// The Interactive AI-Assisted Map — bottom 40% of the Split-Mode Dashboard.
class DashboardMapPanel extends ConsumerStatefulWidget {
  const DashboardMapPanel({super.key, required this.language});

  final AppLanguage language;

  @override
  ConsumerState<DashboardMapPanel> createState() => _DashboardMapPanelState();
}

class _DashboardMapPanelState extends ConsumerState<DashboardMapPanel> {
  LatLng? _myLocation;
  GoogleMapController? _mapController;

  @override
  void initState() {
    super.initState();
    if (MapsConfig.isConfigured) {
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
    } catch (_) {
      // Graceful degradation — the map just falls back to the Dhaka default.
    }
  }

  RouteChoice? _lastFittedRoute;

  void _fitCameraToRoute(RouteChoice route) {
    if (identical(route, _lastFittedRoute) || _mapController == null) return;
    _lastFittedRoute = route;
    var minLat = route.points.first.latitude, maxLat = route.points.first.latitude;
    var minLng = route.points.first.longitude, maxLng = route.points.first.longitude;
    for (final p in route.points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng)),
        48,
      ),
    );
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
                  child: MapsConfig.isConfigured
                      ? GoogleMap(
                          initialCameraPosition: CameraPosition(target: _myLocation ?? _dhakaFallback, zoom: 16),
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
                                  Polyline(
                                    polylineId: const PolylineId('active_route'),
                                    points: route.points,
                                    width: 5,
                                    color: route.verdict.safe ? AppColors.success : AppColors.caution,
                                  ),
                                },
                        )
                      : MapUnavailablePlaceholder(message: d.mapLiveViewLabel, subtitle: d.mapUnavailableSubtitle),
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
              ],
            ),
          );
        },
      ),
    );
  }
}
