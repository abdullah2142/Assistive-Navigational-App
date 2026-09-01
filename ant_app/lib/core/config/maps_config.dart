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
}
