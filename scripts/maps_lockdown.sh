#!/usr/bin/env bash
#
# Locks down the Google Maps Platform key and quotas for ant-assistive-nav.
#
# Everything here is in the safe direction — it lowers limits and narrows what
# the key can do. Nothing it does can increase spend or widen access, so it is
# safe to re-run.
#
# Requires an authenticated gcloud. See scripts/README_maps_lockdown.md.
#
#   ./scripts/maps_lockdown.sh discover   # print current state, change nothing
#   ./scripts/maps_lockdown.sh restrict   # apply the key restrictions
#   ./scripts/maps_lockdown.sh quotas     # lower the per-minute rate caps
#
set -euo pipefail

PROJECT="ant-assistive-nav"
PACKAGE="com.ant.assistive.ant_app"

# Release builds are signed with the debug key (android/app/build.gradle.kts
# never got a release signingConfig), so this one fingerprint covers both
# `flutter run` and the APKs distributed through App Distribution. If a real
# release keystore is ever added, its SHA-1 must be added here too or the
# map goes blank in exactly the build the testers get.
SHA1="8F:9E:40:5C:1D:C3:D8:41:10:56:FE:19:FB:E1:78:32:F8:95:4A:FA"

# The four services this app actually calls. Anything else the key can reach
# is spend surface with no upside — see docs/google_maps_setup.md.
MAPS_SDK="maps-android-backend.googleapis.com"
GEOCODING="geocoding-backend.googleapis.com"
ROUTES="routes.googleapis.com"
PLACES="places.googleapis.com"

GCLOUD="${GCLOUD:-$HOME/google-cloud-sdk/bin/gcloud}"

need_auth() {
  if ! "$GCLOUD" auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    echo "ERROR: gcloud is not authenticated. Run:" >&2
    echo "  $GCLOUD auth login" >&2
    exit 1
  fi
}

discover() {
  need_auth
  echo "=== account ==="
  "$GCLOUD" auth list --filter=status:ACTIVE --format="value(account)"

  echo
  echo "=== enabled Maps-related services ==="
  "$GCLOUD" services list --enabled --project="$PROJECT" \
    --format="value(config.name)" 2>/dev/null \
    | grep -Ei "maps|geocod|route|place|direction" || echo "(none matched)"

  echo
  echo "=== API keys ==="
  "$GCLOUD" services api-keys list --project="$PROJECT" \
    --format="table(uid,displayName,restrictions.androidKeyRestrictions.allowedApplications[].packageName,restrictions.apiTargets[].service)"

  echo
  echo "=== quota metrics (rate limits we can lower) ==="
  for svc in "$GEOCODING" "$ROUTES" "$PLACES"; do
    echo "--- $svc ---"
    "$GCLOUD" alpha services quota list \
      --service="$svc" --consumer="projects/$PROJECT" \
      --format="value(metric,displayName,consumerQuotaLimits[].unit,consumerQuotaLimits[].quotaBuckets[].effectiveLimit)" \
      2>/dev/null || echo "(could not list — service may need enabling)"
  done
}

# Resolves the key by its value, so this cannot silently restrict the wrong
# key on a project that has several.
key_uid() {
  local want
  want=$(grep -oP "AIza[0-9A-Za-z_-]{35}" ant_app/lib/core/config/maps_config.dart | head -1)
  if [[ -z "$want" ]]; then
    echo "ERROR: could not read the key out of maps_config.dart" >&2
    exit 1
  fi
  local uid
  for uid in $("$GCLOUD" services api-keys list --project="$PROJECT" --format="value(uid)"); do
    local val
    val=$("$GCLOUD" services api-keys get-key-string "$uid" --project="$PROJECT" --format="value(keyString)" 2>/dev/null || true)
    if [[ "$val" == "$want" ]]; then
      echo "$uid"
      return 0
    fi
  done
  echo "ERROR: no key on $PROJECT matches the one in maps_config.dart." >&2
  echo "       The app is using a key from a different project." >&2
  exit 1
}

restrict() {
  need_auth
  local uid
  uid=$(key_uid)
  echo "Restricting key $uid"
  echo "  package:  $PACKAGE"
  echo "  sha1:     $SHA1"
  echo "  services: $MAPS_SDK $GEOCODING $ROUTES $PLACES"

  "$GCLOUD" services api-keys update "$uid" \
    --project="$PROJECT" \
    --allowed-application="sha1_fingerprint=$SHA1,package_name=$PACKAGE" \
    --api-target="service=$MAPS_SDK" \
    --api-target="service=$GEOCODING" \
    --api-target="service=$ROUTES" \
    --api-target="service=$PLACES"

  echo
  echo "Done. Verify:"
  echo "  $GCLOUD services api-keys describe $uid --project=$PROJECT"
}

# Rate caps, not monthly caps. Google offers no settable monthly limit for
# these APIs, so this cannot keep you inside the free tier — that job belongs
# to ApiBudget in the client (lib/core/services/api_budget.dart). What this
# does is bound how fast a bug can spend: a runaway retry loop pinned at a few
# requests a minute costs pennies an hour instead of hundreds.
quotas() {
  need_auth
  echo "Per-minute caps bound burn rate only. The monthly ceiling is ApiBudget."
  echo "Run '$0 discover' first and set the metric/unit from its output:"
  echo
  echo "  $GCLOUD alpha services quota update \\"
  echo "    --service=$GEOCODING --consumer=projects/$PROJECT \\"
  echo "    --metric=<METRIC> --unit=<UNIT> --value=10 --force"
  echo
  echo "Suggested values — comfortably above 5 testers, far below a bug:"
  echo "  geocoding 10/min   routes 10/min   places 5/min"
}

case "${1:-discover}" in
  discover) discover ;;
  restrict) restrict ;;
  quotas)   quotas ;;
  *) echo "usage: $0 {discover|restrict|quotas}" >&2; exit 2 ;;
esac
