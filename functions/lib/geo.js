/**
 * Geometry helpers for Module 4's `checkRouteSafety` — polyline decoding and
 * point-in-polygon testing against the Thana boundaries in `crimeZones`.
 * No external geo package: both algorithms are small, standard, and this
 * keeps the Cloud Function's cold-start light.
 */

/** Decodes a Google Maps encoded polyline into [{lat, lng}, ...]. */
function decodePolyline(encoded) {
  const points = [];
  let index = 0;
  let lat = 0;
  let lng = 0;

  while (index < encoded.length) {
    let result = 0;
    let shift = 0;
    let byte;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += (result & 1) !== 0 ? ~(result >> 1) : result >> 1;

    result = 0;
    shift = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += (result & 1) !== 0 ? ~(result >> 1) : result >> 1;

    points.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return points;
}

/** Ray-casting point-in-polygon test for a single ring of {lat, lng} points. */
function pointInRing(point, ring) {
  const { lat: y, lng: x } = point;
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const xi = ring[i].lng;
    const yi = ring[i].lat;
    const xj = ring[j].lng;
    const yj = ring[j].lat;
    const intersects = yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi;
    if (intersects) inside = !inside;
  }
  return inside;
}

/**
 * Whether `point` ({lat, lng}) falls inside a stored `geometry` — the
 * Firestore-safe shape `toFirestoreGeometry` produces: `{ polygons: [{
 * ring: [{lat, lng}, ...] }, ...] }`. Only the outer ring of each polygon
 * is checked (holes are vanishingly unlikely to matter for thana-scale
 * boundaries and aren't present in the geoBoundaries source data used
 * here).
 */
function pointInGeometry(point, geometry) {
  return geometry.polygons.some((polygon) => pointInRing(point, polygon.ring));
}

/**
 * Converts a raw GeoJSON Polygon/MultiPolygon geometry (coordinates as
 * nested `[lng, lat]` arrays) into the flat, Firestore-safe shape used by
 * `crimeZones` documents. Firestore documents cannot contain an array whose
 * elements are themselves arrays ("contains an invalid nested entity"),
 * which raw GeoJSON coordinates always are (ring -> point -> [lng, lat] is
 * already two levels of array nesting) — so every ring becomes an array of
 * `{lat, lng}` *objects* instead, and Polygon/MultiPolygon are both
 * normalized to the same `{ polygons: [{ ring }, ...] }` shape. Only outer
 * rings are kept (see `pointInGeometry`'s doc comment).
 */
function toFirestoreGeometry(geoJsonGeometry) {
  const toPoints = (ring) => ring.map(([lng, lat]) => ({ lat, lng }));
  if (geoJsonGeometry.type === 'Polygon') {
    return { polygons: [{ ring: toPoints(geoJsonGeometry.coordinates[0]) }] };
  }
  if (geoJsonGeometry.type === 'MultiPolygon') {
    return { polygons: geoJsonGeometry.coordinates.map(([outerRing]) => ({ ring: toPoints(outerRing) })) };
  }
  throw new Error(`Unsupported geometry type: ${geoJsonGeometry.type}`);
}

/**
 * Which of `zones` (each `{ ...data, geometry }`) the decoded route passes
 * through. A zone counts as "on route" if any decoded polyline point falls
 * inside it — decoded points from Google's Directions API are dense enough
 * (a vertex roughly every few dozen meters on a walking route) that this is
 * a reasonable substitute for a true line/polygon intersection test without
 * pulling in a full geometry library.
 */
function zonesOnRoute(routePoints, zones) {
  const hits = new Map();
  for (const point of routePoints) {
    for (const zone of zones) {
      if (hits.has(zone.id)) continue;
      if (pointInGeometry(point, zone.geometry)) {
        hits.set(zone.id, zone);
      }
    }
  }
  return Array.from(hits.values());
}

module.exports = { decodePolyline, pointInGeometry, zonesOnRoute, toFirestoreGeometry };
