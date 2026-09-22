/// Map *rendering* configuration — which tiles appear on screen.
///
/// Deliberately separate from `RoutingConfig`, which decides who answers
/// geocoding and directions. Those two used to share one flag, and they are
/// not the same decision: the app can perfectly well draw OpenStreetMap
/// tiles while asking Google for the route, and during the migration to
/// Google routing that is exactly what it does.
class MapsConfig {
  MapsConfig._();

  /// Whether a real Google Maps Platform API key has been configured.
  ///
  /// Every map surface checks this flag and renders [MapUnavailablePlaceholder]
  /// instead of a `GoogleMap` widget when it's false — consistent with the
  /// app's "graceful degradation" philosophy (see `project_master_plan.md`).
  /// Flip back to `false` if the key below stops working (quota exceeded,
  /// revoked, etc.) rather than leaving broken map widgets on screen.
  static const bool isConfigured = true;

  /// Draw OpenStreetMap raster tiles via `flutter_map` instead of the
  /// `GoogleMap` widget.
  ///
  /// **Off.** It was on while the Maps key had no billing, and stayed on
  /// afterwards because the OSM renderer was what had been verified on the
  /// target hardware (Redmi 10C, Adreno 610) after the Impeller blank-map
  /// fix. Testers then reported the obvious consequence: raster tiles give a
  /// flat, non-rotating map with none of the pan/zoom/tilt behaviour anyone
  /// expects from a map, and at a scale too coarse to see where they were.
  ///
  /// If the map ever comes back blank on that device, this is the first
  /// thing to flip — the OSM path is still complete and still tested.
  static const bool useOsmTiles = false;

  /// The Maps Platform key.
  ///
  /// Wired into:
  /// - Android: `com.google.android.geo.API_KEY` meta-data in
  ///   `android/app/src/main/AndroidManifest.xml`.
  /// - iOS: `GMSServices.provideAPIKey(...)` in `ios/Runner/AppDelegate.swift`.
  /// - Web: the Maps JS script tag in `web/index.html`.
  /// - Dart: the Geocoding, Routes and Places REST calls in
  ///   `routing_service.dart`.
  ///
  /// **This key is public.** It ships inside the APK, which means anyone
  /// holding the file can extract it — that is unavoidable for a client-side
  /// Maps key and is why Google's answer is *restriction*, not secrecy. This
  /// particular value has additionally been in public git history since
  /// commit `19c3d37`, so it must be treated as known to strangers.
  ///
  /// The protection that matters is therefore configured in Cloud Console,
  /// not here:
  /// - **Application restriction**: Android apps, package
  ///   `com.ant.assistive.ant_app` plus the SHA-1 of both the debug and the
  ///   release signing certificates.
  /// - **API restriction**: Maps SDK for Android/iOS, Geocoding API, Routes
  ///   API, Places API — and nothing else, so a scraped key cannot be spent
  ///   on some unrelated product billed to this project.
  /// - **Per-API daily quotas** below the free monthly tier, which is the
  ///   only hard spend cap Google offers. A budget alert is a notification,
  ///   not a limit.
  static const String apiKey = 'AIzaSyDhDkodAQPeZBisTKq5E3ZC_TOMoIzGPhM';

  /// Package name and signing-certificate SHA-1 the key is restricted to.
  ///
  /// ## Why the Dart code has to send these
  ///
  /// The Maps SDK proves which app it is automatically. Our Geocoding, Routes
  /// and Places calls do not go through the SDK — they are plain HTTPS from
  /// `package:http` — so an Android-restricted key **refuses them** unless the
  /// request carries these two headers itself. Verified live against the
  /// restricted key on 2026-09-07:
  ///
  /// - no headers        -> `REQUEST_DENIED` / "Android client application
  ///   `<empty>` are blocked"
  /// - with headers      -> `OK`
  /// - SHA-1 with colons -> `REQUEST_DENIED`
  ///
  /// That last line is why [androidCertSha1] is stored colon-free. It is the
  /// same fingerprint `keytool` prints, with the separators removed, and
  /// getting it wrong fails in the worst possible way: `RoutingService` falls
  /// back to OpenStreetMap, so the app keeps working and nobody notices that
  /// Google is never being called.
  ///
  /// **These must match the certificate the APK is actually signed with.**
  /// Release currently reuses the debug key (`android/app/build.gradle.kts`
  /// has no release `signingConfig`), so one value covers every build. Adding
  /// a real release keystore without updating this — and the key's
  /// restriction in Cloud Console — silently disables Google in exactly the
  /// build testers receive.
  static const String androidPackageName = 'com.ant.assistive.ant_app';
  static const String androidCertSha1 = '8F9E405C1DC3D8411056FE19FBE17832F8954AFA';

  /// Headers proving to Google which Android app is calling.
  ///
  /// Sent only to Google hosts. Nominatim, OSRM and Overpass have no use for
  /// them, and quietly telling three volunteer servers the app's signing
  /// fingerprint would be rude as well as pointless.
  static const Map<String, String> androidRestrictionHeaders = {
    'X-Android-Package': androidPackageName,
    'X-Android-Cert': androidCertSha1,
  };
}
