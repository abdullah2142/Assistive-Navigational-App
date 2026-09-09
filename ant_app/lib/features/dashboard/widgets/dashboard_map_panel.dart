import 'dart:async';
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
import '../../../core/providers/ai_assistant_providers.dart';
import '../../../core/services/navigation_narrator.dart';
import '../../../core/services/route_planning_service.dart';
import '../../../core/services/routing_service.dart' show ManeuverKind;
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

  /// Live position updates while a route is being walked.
  ///
  /// The panel used to take a single `getCurrentPosition` fix and never move
  /// again: the camera was fitted to the route once and then sat there while
  /// the user walked off the edge of it. Reported directly — the map should
  /// "automatically zoom in on me reorient on my direction, just like google
  /// maps does in drive mode".
  StreamSubscription<Position>? _positionSub;

  /// Whether the camera is tracking the user.
  ///
  /// Turned off the moment they pan or zoom by hand — a map that keeps
  /// yanking itself back is unusable for the sighted companion this view
  /// exists for — and turned back on by the recentre button.
  bool _following = false;

  /// Last heading used to orient the map, so a jittery compass does not
  /// spin it. GPS heading is only meaningful while actually moving.
  double _bearing = 0;

  /// Below this the reported heading is noise rather than a direction.
  static const double _minSpeedForBearing = 0.6;

  /// Close in, because the question this view answers while walking is
  /// "which turn is this", not "where is Dhaka".
  static const double _followZoom = 18.5;

  @override
  void initState() {
    super.initState();
    if (MapsConfig.useOsmTiles || MapsConfig.isConfigured) {
      _resolveLocation();
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  /// Starts following once a route exists, stops when it is retired.
  void _syncFollowing(RouteChoice? route) {
    if (route != null && _positionSub == null) {
      _following = true;
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 3,
        ),
      ).listen(_onPosition, onError: (Object e) => debugPrint('[Map] position stream: $e'));
    } else if (route == null && _positionSub != null) {
      _positionSub?.cancel();
      _positionSub = null;
      _following = false;
    }
  }

  void _onPosition(Position position) {
    if (!mounted) return;
    setState(() {
      _myLocation = LatLng(position.latitude, position.longitude);
      // Only trust the heading while actually moving — a stationary phone
      // reports a heading that wanders, and a map that slowly spins while
      // somebody stands still is worse than one that does not turn at all.
      if (position.speed >= _minSpeedForBearing) _bearing = position.heading;
    });
    if (_following) _moveCameraToMe();
  }

  void _moveCameraToMe() {
    final me = _myLocation;
    if (me == null) return;
    if (MapsConfig.useOsmTiles) {
      _osmController.moveAndRotate(_toLL(me), _followZoom, -_bearing);
    } else {
      _mapController?.animateCamera(
        gmaps.CameraUpdate.newCameraPosition(
          gmaps.CameraPosition(target: me, zoom: _followZoom, bearing: _bearing, tilt: 45),
        ),
      );
    }
  }

  void _recentre() {
    setState(() => _following = true);
    _moveCameraToMe();
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
      _centerOnMe();
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

  /// Moves the Google camera onto the user once their position is known.
  ///
  /// `initialCameraPosition` is read exactly once, at construction, and on a
  /// real device the first GPS fix always lands after that — so without this
  /// the Google map sat on the Dhaka city-centre fallback forever, zoomed out
  /// over the wrong part of the city. Only the OSM path had a recenter, which
  /// is why the problem appeared the moment the renderer was switched.
  ///
  /// Skipped while a route is displayed: the route fit is the more useful
  /// framing, and yanking the camera back to a dot would undo it.
  void _centerOnMe() {
    if (MapsConfig.useOsmTiles || _lastFittedRoute != null) return;
    final me = _myLocation;
    final controller = _mapController;
    if (me == null || controller == null) return;
    controller.animateCamera(
      gmaps.CameraUpdate.newCameraPosition(
        gmaps.CameraPosition(target: me, zoom: _myLocationZoom),
      ),
    );
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncFollowing(route);
      // The whole-route fit happens once, when the route arrives, so the
      // user sees where they are being taken before the camera closes in on
      // them and starts following.
      if (route != null) _fitCameraToRoute(route);
    });

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
              children: [
                SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: _buildMap(route),
                ),
                // The route readout — what replaced the "massive directional
                // overlay" Module 2 shipped.
                //
                // That was a 56dp north arrow in the middle of the map,
                // rotated to the route's *initial* bearing and never updated
                // after that. It was reported, in as many words, as
                // confusing: an arrow pointing 40 degrees off north tells a
                // sighted user nothing they can act on, it hid the map
                // underneath it, and it answered neither of the two
                // questions somebody walking actually has — how far, and
                // which way at the next corner. Both of those have had
                // answers since Modules 4-5 (the arrow's own comment
                // predicted they would); nothing was reading them.
                if (route != null)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: widget.onToggleFullScreen == null ? 12 : 60,
                    child: _RouteBanner(route: route, strings: d),
                  ),
                if (route != null && !_following)
                  Positioned(
                    bottom: 12,
                    right: 12,
                    child: Semantics(
                      button: true,
                      label: d.mapRecentreSemantics,
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _recentre,
                          child: const Padding(
                            padding: EdgeInsets.all(10),
                            child: Icon(Icons.my_location_rounded, color: Colors.white, size: 24),
                          ),
                        ),
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
          onPointerDown: (_, _) {
            if (_following) setState(() => _following = false);
          },
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
              // Drawn twice: a dark casing under a coloured core, which is
              // how every map draws a route line and the only way it stays
              // legible over both pale and dark tiles. A single stroke
              // disappeared into light-coloured roads at exactly the zoom
              // this panel uses.
              Polyline(
                points: route.points.map(_toLL).toList(),
                strokeWidth: 9,
                color: Colors.black.withValues(alpha: 0.35),
              ),
              Polyline(
                points: route.points.map(_toLL).toList(),
                strokeWidth: 5,
                color: route.verdict.safe ? AppColors.success : AppColors.caution,
              ),
            ]),
          MarkerLayer(markers: [
            if (route != null && route.points.isNotEmpty)
              Marker(
                point: _toLL(route.points.last),
                width: 36,
                height: 36,
                child: Semantics(
                  label: d.mapDestinationMarker(route.destinationLabel),
                  child: const Icon(Icons.place, color: AppColors.primary, size: 32),
                ),
              ),
            if (_myLocation != null)
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
      // All of these were off, which left a map that could not be zoomed,
      // rotated, tilted or recentred — the reason it read as a static
      // picture rather than a map. There is no accessibility argument for
      // suppressing them: a blind user is not touching the map at all, and
      // the people who do look at it (a low-vision user, a caretaker reading
      // over their shoulder) are exactly the ones the controls are for.
      myLocationButtonEnabled: true,
      zoomControlsEnabled: true,
      zoomGesturesEnabled: true,
      scrollGesturesEnabled: true,
      rotateGesturesEnabled: true,
      tiltGesturesEnabled: true,
      compassEnabled: true,
      mapToolbarEnabled: true,
      // A hand on the map wins over following it. A camera that keeps
      // yanking itself back is unusable for the sighted companion this view
      // is for; the recentre button is how they hand control back.
      onCameraMoveStarted: () {
        if (_following) setState(() => _following = false);
      },
      onMapCreated: (controller) {
        _mapController = controller;
        if (route != null) {
          _fitCameraToRoute(route);
        } else {
          // The fix usually lands before the controller does, so the
          // recenter attempt in `_resolveLocation` found no controller and
          // did nothing. Retrying here covers whichever order they arrive in.
          _centerOnMe();
        }
      },
      markers: route == null || route.points.isEmpty
          ? const {}
          : {
              gmaps.Marker(
                markerId: const gmaps.MarkerId('destination'),
                position: route.points.last,
                infoWindow: gmaps.InfoWindow(title: route.destinationLabel),
              ),
            },
      polylines: route == null
          ? const {}
          : {
              // Casing under core — see the OSM path for why.
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('active_route_casing'),
                points: route.points,
                width: 9,
                color: Colors.black.withValues(alpha: 0.35),
              ),
              gmaps.Polyline(
                polylineId: const gmaps.PolylineId('active_route'),
                points: route.points,
                width: 5,
                color: route.verdict.safe ? AppColors.success : AppColors.caution,
                zIndex: 1,
              ),
            },
    );
  }
}

/// The live route readout that sits over the top of the map.
///
/// Answers the two questions somebody walking a route actually has, in the
/// order they matter: *which way at the next corner*, and *how far is left*.
/// Both were already available — `RouteStep` has carried manoeuvres and
/// street names since Module 4, and `NavigationNarrator` has known the
/// distance to each one since Module 5 — and neither was on screen.
///
/// Reads from `NavigationController.progress`, which updates on every GPS
/// fix. Falls back to the route's own total before the first fix lands, so
/// the panel is never blank while a route is active.
class _RouteBanner extends ConsumerWidget {
  const _RouteBanner({required this.route, required this.strings});

  final RouteChoice route;
  final Dashboard strings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(navigationControllerProvider);
    return ValueListenableBuilder<NavigationProgress?>(
      valueListenable: controller.progress,
      builder: (context, progress, _) => _build(context, progress),
    );
  }

  Widget _build(BuildContext context, NavigationProgress? progress) {
    final remaining = progress?.metersRemaining ?? route.distanceMeters;
    // One label for the whole banner rather than four separate ones. A
    // screen reader reading "turn left", "250 m", "1.2 km left" as three
    // unrelated stops is harder to follow than one sentence, and this is the
    // sentence the app would say out loud anyway.
    final semanticsLabel = strings.mapRouteStatus(
      safe: route.verdict.safe,
      wasRerouted: route.wasRerouted,
      distanceMeters: remaining,
      destination: route.destinationLabel,
      via: route.viaSummary,
    );

    return Semantics(
      liveRegion: true,
      label: progress == null || progress.arrived
          ? semanticsLabel
          : '${strings.navigateTurnAhead(
              kind: progress.maneuver,
              meters: progress.metersToManeuver,
              streetName: progress.streetName,
            )} $semanticsLabel',
      // The children are already summarised above; letting the reader walk
      // into them repeats the same three facts a second time.
      excludeSemantics: true,
      child: Material(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _ManeuverBadge(progress: progress, safe: route.verdict.safe),
              const SizedBox(width: 12),
              Expanded(child: _lines(context, progress, remaining)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _lines(BuildContext context, NavigationProgress? progress, double remaining) {
    final theme = Theme.of(context);
    final headline = switch (progress) {
      null => strings.mapHeadingTo(route.destinationLabel),
      NavigationProgress(arrived: true) => strings.mapArrived,
      NavigationProgress(offRoute: true) => strings.mapOffRoute,
      final p => strings.mapManeuverLine(kind: p.maneuver, streetName: p.streetName),
    };
    // The distance to the *next turn* is the number being acted on, so it is
    // the big one; the total is context and sits under it.
    final turnDistance = progress != null && !progress.arrived && !progress.offRoute
        ? strings.mapCompactDistance(progress.metersToManeuver)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (turnDistance != null) ...[
              Text(
                turnDistance,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                headline,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          // The via is here to identify the *route*; when the next turn is
          // onto that same road it says the road name twice in two lines.
          route.viaSummary.isEmpty || route.viaSummary == progress?.streetName
              ? strings.mapRemainingLabel(remaining)
              : '${strings.mapRemainingLabel(remaining)} · ${route.viaSummary}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The manoeuvre icon.
///
/// A turn arrow, not a compass arrow. The old overlay rotated a north arrow
/// to the route's bearing, which asks the viewer to hold their own heading in
/// their head and subtract — exactly the work someone navigating an unfamiliar
/// street cannot spare. "Turn left" is a left arrow, in every map anyone has
/// used.
class _ManeuverBadge extends StatelessWidget {
  const _ManeuverBadge({required this.progress, required this.safe});

  final NavigationProgress? progress;
  final bool safe;

  @override
  Widget build(BuildContext context) {
    final colour = !safe ? AppColors.caution : AppColors.primary;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      child: Icon(_icon, color: Colors.white, size: 24),
    );
  }

  IconData get _icon {
    final p = progress;
    if (p == null) return Icons.navigation_rounded;
    if (p.arrived) return Icons.flag_rounded;
    if (p.offRoute) return Icons.error_outline_rounded;
    return switch (p.maneuver) {
      ManeuverKind.left => Icons.turn_left_rounded,
      ManeuverKind.slightLeft => Icons.turn_slight_left_rounded,
      ManeuverKind.sharpLeft => Icons.turn_sharp_left_rounded,
      ManeuverKind.right => Icons.turn_right_rounded,
      ManeuverKind.slightRight => Icons.turn_slight_right_rounded,
      ManeuverKind.sharpRight => Icons.turn_sharp_right_rounded,
      ManeuverKind.uTurn => Icons.u_turn_left_rounded,
      ManeuverKind.roundabout => Icons.roundabout_left_rounded,
      ManeuverKind.crossing => Icons.directions_walk_rounded,
      ManeuverKind.arrive => Icons.flag_rounded,
      ManeuverKind.depart || ManeuverKind.straight => Icons.straight_rounded,
    };
  }
}
