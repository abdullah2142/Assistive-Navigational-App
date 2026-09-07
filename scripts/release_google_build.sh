#!/usr/bin/env bash
#
# Builds and distributes an ANT release with Google routing switched on.
#
#   ./scripts/release_google_build.sh verify    # prove the key works, build nothing
#   ./scripts/release_google_build.sh build     # release APK with Google routing
#   ./scripts/release_google_build.sh distribute "release notes"
#
# Why a script rather than a command to paste: this build differs from a normal
# one by a --dart-define that is invisible in the artifact. Forgetting it
# produces an APK that looks identical, installs fine, and quietly uses
# OpenStreetMap for everything — the exact failure this whole migration was
# meant to end.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_DIR="ant_app"
APK="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"

PROJECT="ant-assistive-nav"
# From `firebase appdistribution:groups:list`. Not "internal" — that alias
# does not exist on this project and its absence fails as a misleading 404
# *after* a successful upload.
GROUP="fydp"

# Google routing on. Emergency dispatch stays off: testers enter their real
# family's numbers, and the voice pack's whole job is saying unexpected
# things. See lib/core/config/emergency_config.dart.
DEFINES=(
  --dart-define=ROUTING_PREFER_GOOGLE=true
)

verify() {
  echo "Checking the key answers all three billable APIs from this machine."
  echo "NOTE: expected to FAIL with REQUEST_DENIED — the key is Android-restricted."
  echo "      That failure is the restriction working. The app sends"
  echo "      X-Android-Package/X-Android-Cert, which curl here does not."
  echo
  echo "The real verification is on-device, below."
}

build() {
  echo "Building release APK with Google routing enabled..."
  ( cd "$APP_DIR" && flutter build apk --release "${DEFINES[@]}" )
  echo
  echo "Built: $APK"
  ls -lh "$APK"
  echo
  cat <<'NEXT'
Before distributing, prove Google is actually being called. Install on a
device and watch the log while asking for a route:

  adb install -r ant_app/build/app/outputs/flutter-apk/app-release.apk
  adb logcat | grep -E "Routing|ApiBudget"

  SUCCESS  no "[Routing] Google ... failed" lines, and api_usage/<YYYY-MM>
           in Firestore gains a `routes` count
  FAILURE  "[Routing] Google routing failed (directions_failed:...)"

The failure mode is silent by design: RoutingService falls back to
OpenStreetMap, so the app WILL work and give directions either way. The
Firestore counter is the only proof that Google was reached.
NEXT
}

distribute() {
  local notes="${1:-}"
  if [[ -z "$notes" ]]; then
    echo "usage: $0 distribute \"release notes\"" >&2
    exit 2
  fi
  if [[ ! -f "$APK" ]]; then
    echo "ERROR: no APK at $APK — run '$0 build' first." >&2
    exit 1
  fi
  firebase appdistribution:distribute "$APK" \
    --project "$PROJECT" \
    --groups "$GROUP" \
    --release-notes "$notes"
}

case "${1:-build}" in
  verify)     verify ;;
  build)      build ;;
  distribute) distribute "${2:-}" ;;
  *) echo "usage: $0 {verify|build|distribute}" >&2; exit 2 ;;
esac
