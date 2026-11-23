#!/usr/bin/env bash
set -euo pipefail
umask 077

require_settings() {
  local setting
  for setting in "$@"; do
    if [[ -z "${!setting:-}" ]]; then
      echo "::error::Missing release setting $setting."
      exit 1
    fi
  done
}

mode="${1:-}"
require_settings RUNNER_TEMP RELEASE_VERSION GITHUB_RUN_NUMBER GITHUB_RUN_ATTEMPT
bundle_id="${GPHOTOS_BUNDLE_ID:-org.gphotosapp.gphotos}"
project=GPhotosSync.xcodeproj
scratch="$(mktemp -d "$RUNNER_TEMP/gphotos-release.XXXXXX")"
keychain=
previous_keychains=()

cleanup() {
  if [[ -n "$keychain" ]]; then
    security list-keychains -d user -s "${previous_keychains[@]}" || true
    security delete-keychain "$keychain" || true
  fi
  rm -rf "$scratch"
}
trap 'result=$?; cleanup; exit "$result"' EXIT

install_certificate() {
  require_settings APPLE_TEAM_ID SIGNING_CERTIFICATE_BASE64 SIGNING_CERTIFICATE_PASSWORD
  local password
  password="$(openssl rand -hex 24)"
  while IFS= read -r path; do
    previous_keychains+=("$path")
  done < <(security list-keychains -d user | sed -E 's/^ *"(.*)"$/\1/')
  keychain="$scratch/signing.keychain-db"
  printf '%s' "$SIGNING_CERTIFICATE_BASE64" | base64 -D > "$scratch/signing.p12"
  security create-keychain -p "$password" "$keychain"
  security set-keychain-settings -lut 3600 "$keychain"
  security unlock-keychain -p "$password" "$keychain"
  security import "$scratch/signing.p12" -P "$SIGNING_CERTIFICATE_PASSWORD" \
    -f pkcs12 -k "$keychain" -T /usr/bin/codesign
  rm "$scratch/signing.p12"
  unset SIGNING_CERTIFICATE_BASE64 SIGNING_CERTIFICATE_PASSWORD
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
  security list-keychains -d user -s "$keychain"
}

install_profile() {
  local secret="$1" id="$2" extension="$3"
  local profile="$scratch/$id.$extension" info="$scratch/$id.plist" app_id uuid
  if [[ -z "${!secret:-}" ]]; then
    echo "::error::Configure $secret in the release environment."
    exit 1
  fi
  printf '%s' "${!secret}" | base64 -D > "$profile"
  unset "$secret"
  security cms -D -i "$profile" > "$info"
  app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$info" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$info")"
  if [[ "${app_id#*.}" != "$id" || \
    "$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$info")" != "$APPLE_TEAM_ID" ]]; then
    echo "::error::$secret must be a profile for $id on the configured team."
    exit 1
  fi
  uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$info")"
  if [[ ! "$uuid" =~ ^[A-Fa-f0-9-]{36}$ ]]; then
    echo "::error::$secret has an invalid profile UUID."
    exit 1
  fi
  local profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  mkdir -p "$profile_dir"
  cp "$profile" "$profile_dir/$uuid.$extension"
  profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$info")"
}

prepare_api_key() {
  require_settings ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_BASE64
  api_key="$scratch/AuthKey.p8"
  printf '%s' "$ASC_KEY_BASE64" | base64 -D > "$api_key"
  unset ASC_KEY_BASE64
}

archive() {
  local scheme="$1" platform="$2" identity="$3"
  shift 3
  xcodebuild archive -project "$project" -scheme "$scheme" \
    -configuration Release -destination "generic/platform=$platform" -archivePath "$scratch/GPhotos.xcarchive" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    GPHOTOS_BUNDLE_ID="$bundle_id" MARKETING_VERSION="$RELEASE_VERSION" \
    CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER.$GITHUB_RUN_ATTEMPT" "$@"
}

case "$mode" in
  macos)
    install_certificate
    install_profile MAC_PROFILE_BASE64 "$bundle_id.mac" provisionprofile
    archive GPhotosSyncMac macOS 'Developer ID Application' \
      GPHOTOS_MAC_PROFILE="$profile_name" ENABLE_HARDENED_RUNTIME=YES \
      CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp
    app="$scratch/GPhotos.xcarchive/Products/Applications/GPhotosSyncMac.app"
    codesign --verify --deep --strict "$app"
    codesign -dvv "$app" 2> "$scratch/signature.txt"
    if ! grep -q '^Authority=Developer ID Application:' "$scratch/signature.txt"; then
      echo "::error::The archived app does not have a Developer ID Application signature."
      exit 1
    fi
    mkdir -p dist
    ditto "$app" dist/GPhotos.app
    ;;
  notarize)
    prepare_api_key
    app=dist/GPhotos.app
    upload="$scratch/notarization.zip"
    ditto -c -k --keepParent "$app" "$upload"
    xcrun notarytool submit "$upload" --key "$api_key" --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" --wait --timeout 25m --output-format json > "$scratch/notary.json"
    if ! jq -e '.status == "Accepted"' "$scratch/notary.json" >/dev/null; then
      jq -r '"Notarization request \(.id): \(.status)"' "$scratch/notary.json"
      exit 1
    fi
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    codesign --verify --deep --strict "$app"
    spctl --assess --type execute --verbose "$app"
    (
      cd dist
      zip="GPhotos-$RELEASE_VERSION-macOS.zip"
      ditto -c -k --sequesterRsrc --keepParent GPhotos.app "$zip"
      shasum -a 256 "$zip" > "$zip.sha256"
    )
    ;;
  testflight)
    install_certificate
    install_profile IOS_APP_PROFILE_BASE64 "$bundle_id" mobileprovision
    app_profile="$profile_name"
    install_profile IOS_SHARE_PROFILE_BASE64 "$bundle_id.share" mobileprovision
    share_profile="$profile_name"
    install_profile IOS_UPLOAD_PROFILE_BASE64 "$bundle_id.uploads" mobileprovision
    upload_profile="$profile_name"
    install_profile IOS_WIDGETS_PROFILE_BASE64 "$bundle_id.widgets" mobileprovision
    widgets_profile="$profile_name"
    prepare_api_key
    archive GPhotosSync iOS 'Apple Distribution' \
      GPHOTOS_IOS_APP_PROFILE="$app_profile" GPHOTOS_IOS_SHARE_PROFILE="$share_profile" \
      GPHOTOS_IOS_UPLOAD_PROFILE="$upload_profile" GPHOTOS_IOS_WIDGETS_PROFILE="$widgets_profile"

    jq -n --arg team "$APPLE_TEAM_ID" --arg bundle "$bundle_id" \
      --arg app "$app_profile" --arg share "$share_profile" --arg upload "$upload_profile" --arg widgets "$widgets_profile" \
      '{
        method: "app-store-connect", destination: "upload", teamID: $team,
        signingStyle: "manual", signingCertificate: "Apple Distribution",
        manageAppVersionAndBuildNumber: false,
        provisioningProfiles: {
          ($bundle): $app, ($bundle + ".share"): $share,
          ($bundle + ".uploads"): $upload, ($bundle + ".widgets"): $widgets
        }
      }' > "$scratch/export.json"
    plutil -convert xml1 -o "$scratch/export.plist" "$scratch/export.json"
    xcodebuild -exportArchive -archivePath "$scratch/GPhotos.xcarchive" \
      -exportPath "$scratch/upload" -exportOptionsPlist "$scratch/export.plist" \
      -authenticationKeyPath "$api_key" -authenticationKeyID "$ASC_KEY_ID" \
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    ;;
  *)
    echo "Usage: $0 {macos|notarize|testflight}" >&2
    exit 2
    ;;
esac
