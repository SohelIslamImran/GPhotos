#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mode="${1:-macos}"
case "$mode" in
  macos)
    scheme=GPhotosSyncMac
    destination=platform=macOS
    ;;
  ios)
    scheme=GPhotosSync
    destination='generic/platform=iOS Simulator'
    ;;
  *)
    echo "Usage: $0 [macos|ios]" >&2
    exit 2
    ;;
esac

xcodegen generate
args=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  args+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM" -allowProvisioningUpdates)
else
  args+=(CODE_SIGNING_ALLOWED=NO)
fi
if [[ -n "${GPHOTOS_BUNDLE_ID:-}" ]]; then
  args+=("GPHOTOS_BUNDLE_ID=$GPHOTOS_BUNDLE_ID")
fi
xcodebuild -project GPhotosSync.xcodeproj -scheme "$scheme" \
  -destination "$destination" -derivedDataPath .build/"$mode" "${args[@]}" build
