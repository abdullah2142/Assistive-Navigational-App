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
  /// **On, and staying on for now.** Not for cost reasons — the Maps SDK for
  /// Android is free with unlimited map loads, so this saves nothing. It is
  /// on because this is the configuration that has actually been verified on
  /// the target hardware (Redmi 10C, Adreno 610) after the Impeller blank-map
  /// fix in `AndroidManifest.xml`. Switching the renderer would put that
  /// fix's evidence back in question, and the map is not the part of this app
  /// its users can see.
  ///
  /// Flip to `false` once someone has confirmed a `GoogleMap` widget renders
  /// on that device with Impeller disabled.
  static const bool useOsmTiles = true;

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
  static const String apiKey = 'AIzaSyBhpaxU8ZdJ-3xGt-fTRfChMa5zIwEJiYI';
}
