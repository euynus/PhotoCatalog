#!/usr/bin/env bash
# Builds PhotoCatalog for the Mac App Store: the sandboxed app (Resources/AppStore.entitlements)
# without the GitHub updater (compiled with -D APPSTORE), signed for the store and wrapped in an
# installer package ready to upload. It runs on Apple silicon; UNIVERSAL=1 adds Intel once the AI
# code no longer uses Float16, which Swift doesn't have on x86_64.
#
#   APP_SIGN_IDENTITY="Apple Distribution: Your Name (TEAMID)" \
#   INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAMID)" \
#   PROVISIONING_PROFILE=~/Downloads/PhotoCatalog_App_Store.provisionprofile \
#     script/appstore.sh 1.0
#
# One-time setup (developer.apple.com → Certificates, Identifiers & Profiles; App Store Connect):
#   - an App ID for the bundle identifier (com.photocatalog.app unless BUNDLE_ID says otherwise)
#     and an app record for it in App Store Connect
#   - "Apple Distribution" and "Mac Installer Distribution" certificates in the login keychain
#   - a "Mac App Store Connect" provisioning profile for that App ID
#
# Upload the package with Transporter, or:
#   xcrun altool --upload-package dist/PhotoCatalog-<version>.pkg -t macos --apiKey <id> --apiIssuer <issuer>
#
# To try the sandbox locally without certificates, sign the same build ad hoc:
#   AD_HOC=1 script/appstore.sh 1.0      (makes dist/PhotoCatalog.app only, no package)
set -euo pipefail

VERSION="${1:?usage: script/appstore.sh <version, e.g. 1.0>}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/PhotoCatalog.app"
PKG="$ROOT_DIR/dist/PhotoCatalog-$VERSION.pkg"
ENTITLEMENTS="$ROOT_DIR/Resources/AppStore.entitlements"
export BUNDLE_ID="${BUNDLE_ID:-com.photocatalog.app}"

if [[ -z "${AD_HOC:-}" ]]; then
  : "${APP_SIGN_IDENTITY:?set APP_SIGN_IDENTITY to your \"Apple Distribution: …\" signing identity}"
  : "${INSTALLER_SIGN_IDENTITY:?set INSTALLER_SIGN_IDENTITY to your \"3rd Party Mac Developer Installer: …\" identity}"
  : "${PROVISIONING_PROFILE:?set PROVISIONING_PROFILE to the Mac App Store provisioning profile for $BUNDLE_ID}"
fi

APPSTORE=1 APP_VERSION="$VERSION" CONFIGURATION=release \
  "$ROOT_DIR/script/build_and_run.sh" build

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "${AD_HOC:-}" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "Ready (ad hoc, sandboxed): $APP"
  exit 0
fi

# The store build carries its profile, and its signature names the team and App ID the profile
# grants, alongside the sandbox entitlements.
security cms -D -i "$PROVISIONING_PROFILE" > "$WORK/profile.plist"
TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$WORK/profile.plist")"
PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$WORK/profile.plist")"
if [[ "$PROFILE_APP_ID" != "$TEAM_ID.$BUNDLE_ID" ]]; then
  echo "The provisioning profile is for $PROFILE_APP_ID, not $TEAM_ID.$BUNDLE_ID" >&2
  exit 1
fi
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
cp "$ENTITLEMENTS" "$WORK/signed.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
  -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$WORK/signed.entitlements"

codesign --force --options runtime --sign "$APP_SIGN_IDENTITY" --entitlements "$WORK/signed.entitlements" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$PKG"
productbuild --component "$APP" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG"

echo "Ready: $PKG"
echo "Validate and upload it with Transporter, or with xcrun altool --validate-app / --upload-package."
