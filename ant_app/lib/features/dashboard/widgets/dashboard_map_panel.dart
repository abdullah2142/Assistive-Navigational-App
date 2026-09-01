import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../../core/config/maps_config.dart';
import '../../../core/localization/app_language.dart';
import '../../../core/localization/dashboard_strings.dart';
import '../../../core/widgets/map_unavailable_placeholder.dart';

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
class DashboardMapPanel extends StatefulWidget {
  const DashboardMapPanel({super.key, required this.language});

  final AppLanguage language;

  @override
  State<DashboardMapPanel> createState() => _DashboardMapPanelState();
}

class _DashboardMapPanelState extends State<DashboardMapPanel> {
  LatLng? _myLocation;

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

  @override
  Widget build(BuildContext context) {
    final d = Dashboard.of(widget.language);
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
                        )
                      : MapUnavailablePlaceholder(message: d.mapLiveViewLabel, subtitle: d.mapUnavailableSubtitle),
                ),
                // Massive Directional Overlay. Static "forward" arrow for now —
                // the routing engine (Modules 4-5) will drive rotation/visibility
                // off the next turn instruction once it exists.
                Semantics(
                  label: d.mapNextDirection,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(18),
                    child: const Icon(Icons.north_rounded, color: Colors.white, size: 56),
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
