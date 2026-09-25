#!/usr/bin/env bash
# Builds a signed, notarized PhotoCatalog.app and a zip ready to publish as a GitHub release,
# which "Check for Updates…" then offers to everyone on an older version.
#
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=photocatalog \
#     script/release.sh 1.1
#
# One-time setup:
#   - a "Developer ID Application" certificate in the login keychain (Apple Developer account)
#   - a notarytool profile holding your credentials:
#       xcrun notarytool store-credentials photocatalog --apple-id you@example.com \
#         --team-id TEAMID --password <app-specific password>
set -euo pipefail

VERSION="${1:?usage: script/release.sh <version, e.g. 1.1>}"
: "${DEVELOPER_ID:?set DEVELOPER_ID to your \"Developer ID Application: …\" signing identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile (see the header of this script)}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/PhotoCatalog.app"
ZIP="$ROOT_DIR/dist/PhotoCatalog-$VERSION.zip"

APP_VERSION="$VERSION" CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" build

# Hardened runtime, as notarization requires; the app needs no entitlements (not sandboxed,
# system frameworks only, no plug-ins).
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
# zip again so the download carries the stapled ticket and opens offline
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"

echo "Ready: $ZIP"
echo "Publish it with: gh release create v$VERSION \"$ZIP\" --title \"PhotoCatalog $VERSION\""
