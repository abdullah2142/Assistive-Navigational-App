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

# Secrets live here, gitignored: GEMINI_API_KEY, CLOUD_STT_API_KEY.
# NOT optional. See preflight() for what happens without it.
DEFINES_FILE="$APP_DIR/dart_defines.local.json"

# Google routing on. Emergency dispatch stays off: testers enter their real
# family's numbers, and the voice pack's whole job is saying unexpected
# things. See lib/core/config/emergency_config.dart.
DEFINES=(
  --dart-define-from-file=dart_defines.local.json
  --dart-define=ROUTING_PREFER_GOOGLE=true
)

# The keys that must be compiled in, and what breaks without each.
REQUIRED_DEFINES=(
  "CLOUD_STT_API_KEY|voice input falls back to the on-device recognizer"
  "GEMINI_API_KEY|the assistant cannot answer anything"
)

# Refuses to build a release that would ship mute.
#
# This exists because it already happened. A release went out built with only
# --dart-define=ROUTING_PREFER_GOOGLE=true, so CLOUD_STT_API_KEY was empty,
# STT fell back to the on-device recognizer, and voice was dead for every
# tester. It could not be caught by using the app: the developer's own builds
# read this file, so they used Cloud STT and worked perfectly.
#
# Missing keys do not crash anything. They degrade, quietly, in a voice-first
# app for blind users — which is the worst possible way for them to fail. So
# the build stops here instead.
preflight() {
  if [[ ! -f "$DEFINES_FILE" ]]; then
    cat >&2 <<EOM
ERROR: $DEFINES_FILE is missing.

It is gitignored, so a fresh clone will not have it. Create it as:

  {
    "GEMINI_API_KEY": "...",
    "CLOUD_STT_API_KEY": "..."
  }

Building without it produces an app that installs, runs, and cannot hear.
EOM
    exit 1
  fi

  local entry name why value missing=0
  for entry in "${REQUIRED_DEFINES[@]}"; do
    IFS='|' read -r name why <<< "$entry"
    value=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" \
              "$DEFINES_FILE" "$name" 2>/dev/null || true)
    if [[ -z "$value" ]]; then
      echo "ERROR: $name is missing or empty — $why" >&2
      missing=1
    else
      echo "  ok  $name (${#value} chars)"
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

# Proves the keys actually made it into the artifact, rather than trusting
# that the flag was spelled correctly. A --dart-define typo is silent.
verify_apk() {
  local key missing=0
  echo "Checking the built APK really carries the keys..."
  for entry in "${REQUIRED_DEFINES[@]}"; do
    IFS='|' read -r name why <<< "$entry"
    key=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" \
            "$DEFINES_FILE" "$name")
    if grep -qa -- "$key" "$APK"; then
      echo "  ok  $name found in APK"
    else
      echo "  MISSING  $name is not in the APK — $why" >&2
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || {
    echo "Refusing to treat this build as releasable." >&2
    exit 1
  }
}

verify() {
  preflight
  if [[ -f "$APK" ]]; then
    verify_apk
  else
    echo "(no APK built yet — skipping artifact check)"
  fi
}

build() {
  preflight
  echo "Building release APK with Google routing enabled..."
  ( cd "$APP_DIR" && flutter build apk --release "${DEFINES[@]}" )
  echo
  echo "Built: $APK"
  ls -lh "$APK"
  echo
  verify_apk
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
  # Re-checked here as well as in build(), because the APK on disk may be
  # left over from an earlier build made without the keys.
  preflight
  verify_apk
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
