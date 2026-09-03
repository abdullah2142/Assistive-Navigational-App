import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gmaps;
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/config/maps_config.dart';
import '../../../core/config/routing_config.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/map_unavailable_placeholder.dart';
import '../providers/guardian_providers.dart';

const String _osmUserAgent = 'ANT-AssistiveNavigationalApp/1.0 (+https://github.com/abdullah2142/Assistive-Navigational-App)';

/// The Overwatch Map — live GPS + battery for the paired disabled user.
///
/// Shows an empty state until Module 8's background isolate starts writing
/// `liveLocations/{uid}` (see [LiveLocation]'s doc comment).
class OverwatchMapPanel extends ConsumerWidget {
  const OverwatchMapPanel({super.key, required this.disabledUserUid});

  final String disabledUserUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locationAsync = ref.watch(liveLocationStreamProvider(disabledUserUid));
    final theme = Theme.of(context);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 220,
        child: locationAsync.when(
          data: (location) {
            if (location == null) {
              return const MapUnavailablePlaceholder(
                message: 'Waiting for the first location update…',
              );
            }
            if (!RoutingConfig.useOpenStreetMap && !MapsConfig.isConfigured) {
              return MapUnavailablePlaceholder(
                message: 'Last known: ${location.lat.toStringAsFixed(4)}, ${location.lng.toStringAsFixed(4)}',
              );
            }
            return Stack(
              children: [
                Positioned.fill(
                  // See `DashboardMapPanel`'s doc comment — same
                  // `RoutingConfig.useOpenStreetMap`-gated swap, so a
                  // caretaker isn't left staring at an empty Google map
                  // either while there's no working Maps Platform key.
                  child: RoutingConfig.useOpenStreetMap
                      ? _buildOsmMap(location.lat, location.lng)
                      : _buildGoogleMap(location.lat, location.lng),
                ),
                if (location.batteryPercent != null)
                  Positioned(
                    top: 12,
                    right: 12,
                    child: _BatteryBadge(percent: location.batteryPercent!),
                  ),
              ],
            );
          },
          loading: () => Container(
            color: AppColors.divider.withValues(alpha: 0.4),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(),
          ),
          error: (e, st) => Container(
            color: AppColors.divider.withValues(alpha: 0.4),
            alignment: Alignment.center,
            child: Text('Couldn\'t load location: $e', style: theme.textTheme.bodySmall),
          ),
        ),
      ),
    );
  }

  Widget _buildOsmMap(double lat, double lng) {
    final target = ll.LatLng(lat, lng);
    return FlutterMap(
      options: MapOptions(initialCenter: target, initialZoom: 16),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.ant.assistive.ant_app',
          // See `DashboardMapPanel`'s identical fix — a `const` headers map
          // crashes here ("Cannot modify unmodifiable map"), since
          // `flutter_map`'s tile provider mutates it internally.
          tileProvider: NetworkTileProvider(headers: {'User-Agent': _osmUserAgent}),
        ),
        MarkerLayer(markers: [
          Marker(point: target, width: 28, height: 28, child: const Icon(Icons.person_pin_circle, color: Colors.red, size: 28)),
        ]),
      ],
    );
  }

  Widget _buildGoogleMap(double lat, double lng) {
    final target = gmaps.LatLng(lat, lng);
    return gmaps.GoogleMap(
      initialCameraPosition: gmaps.CameraPosition(target: target, zoom: 16),
      markers: {gmaps.Marker(markerId: const gmaps.MarkerId('disabledUser'), position: target)},
      zoomControlsEnabled: false,
      myLocationButtonEnabled: false,
    );
  }
}

class _BatteryBadge extends StatelessWidget {
  const _BatteryBadge({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    final color = percent <= 20 ? AppColors.danger : AppColors.success;
    return Semantics(
      label: 'Battery $percent percent',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.battery_std_rounded, size: 16, color: Colors.white),
            const SizedBox(width: 4),
            Text('$percent%', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
