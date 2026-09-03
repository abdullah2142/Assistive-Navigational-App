/// Which backend [RoutingService] uses for geocoding and walking directions.
///
/// **Placeholder, not the intended long-term backend**: `MapsConfig.apiKey`
/// (the key already used for map *rendering*) doesn't actually work for the
/// Geocoding or Directions REST APIs — both return `REQUEST_DENIED` when
/// called directly (confirmed live 2026-09-02: Geocoding says billing isn't
/// enabled on that key's GCP project; Directions says the legacy API isn't
/// enabled at all). Enabling those needs GCP Console access to a billing
/// account the user isn't ready to attach a card to yet.
///
/// Until that's resolved, [useOpenStreetMap] routes through free,
/// no-API-key OpenStreetMap services instead — Nominatim for geocoding,
/// the public OSRM demo server for walking directions — so the feature
/// works today rather than staying dark indefinitely. Flip this to `false`
/// (and nothing else needs to change — `RoutePlanningService`, the Gemini
/// `request_route` tool, and the map widget are all backend-agnostic) once
/// `MapsConfig`'s key actually has Geocoding/Directions access.
///
/// **Known real limitation of this placeholder, confirmed live
/// (2026-09-03)**: the public OSRM demo server's "foot" profile returns
/// byte-identical distance *and duration* to its "driving" profile on the
/// same two points — it isn't actually running a dedicated pedestrian
/// profile, just labeling car-speed results as walking ones. `RoutingService`
/// compensates by discarding OSRM's own duration and computing it from
/// distance at a fixed walking speed instead (see `_walkingSpeedMps`). The
/// route *geometry* itself is still real — drawn from OSM's actual street
/// network via genuine pathfinding — just not confirmed sidewalk-aware,
/// the same general caveat `project_master_plan.md` already flags for
/// Google's own routing in Dhaka (neither service has rich Dhaka-specific
/// pedestrian infrastructure data; that gap is what Module 5's
/// crowdsourcing is for, independent of which backend is underneath).
///
/// Neither Nominatim nor the public OSRM demo server carry any uptime
/// guarantee (their own usage policies say so explicitly) — `RoutingService`
/// surfaces their failures through the same graceful `RoutingException`
/// path as a Google failure would, so a down/rate-limited demo server
/// degrades to "couldn't plan that route" rather than crashing.
class RoutingConfig {
  RoutingConfig._();

  static const bool useOpenStreetMap = true;
}
