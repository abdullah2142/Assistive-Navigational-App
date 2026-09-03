/// Whether a real Google Maps Platform API key has been configured.
///
/// Every map surface checks this flag and renders [MapUnavailablePlaceholder]
/// instead of a `GoogleMap` widget when it's false — consistent with the
/// app's "graceful degradation" philosophy (see `project_master_plan.md`).
/// Flip back to `false` if the key below stops working (quota exceeded,
/// revoked, etc.) rather than leaving broken map widgets on screen.
///
/// Key is wired into:
/// - Android: `com.google.android.geo.API_KEY` meta-data in
///   `android/app/src/main/AndroidManifest.xml`.
/// - iOS: `GMSServices.provideAPIKey(...)` in `ios/Runner/AppDelegate.swift`.
/// - Web: the Maps JS script tag in `web/index.html`.
///
/// This is a personal/experimentation key, not tied to the `ant-assistive-nav`
/// GCP project — fine for development, but replace it with a properly
/// restricted key on that project before any real release.
class MapsConfig {
  MapsConfig._();

  static const bool isConfigured = true;

  /// The same key embedded in the three native map-SDK integration points
  /// above, exposed here so Dart code can also call the Directions/Geocoding
  /// REST APIs directly (Module 4's routing — see `routing_service.dart`).
  /// Those are separate Maps Platform products from "Maps SDK for
  /// Android/iOS"/"Maps JavaScript API" and may need enabling/restricting
  /// separately on whichever GCP project this key belongs to — if routing
  /// requests start failing with a `REQUEST_DENIED` status, check that
  /// first before assuming the routing code itself is broken.
  static const String apiKey = 'AIzaSyBhpaxU8ZdJ-3xGt-fTRfChMa5zIwEJiYI';
}
