#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="PhotoCatalog"
BUNDLE_ID="com.photocatalog.app"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
MODULE_CACHE="$ROOT_DIR/.build/ModuleCache"

cd "$ROOT_DIR"
mkdir -p "$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

sdk_is_compatible() {
  printf '%s\n' \
    'import SwiftUI; struct SDKProbe: View { @State private var value = 0; var body: some View { Text(String(value)) } }' \
    | command swiftc -sdk "$1" -module-cache-path "$MODULE_CACHE" -typecheck - >/dev/null 2>&1
}

resolve_sdk() {
  if [[ -n "${SDKROOT:-}" ]]; then
    local requested_sdk="$SDKROOT"
    local resolved_sdk=""
    resolved_sdk="$(cd "$requested_sdk" 2>/dev/null && pwd -P)" || true
    if [[ -z "$resolved_sdk" ]] || ! sdk_is_compatible "$resolved_sdk"; then
      echo "SDKROOT is not compatible with the active Swift toolchain: $SDKROOT" >&2
      return 1
    fi
    printf '%s\n' "$resolved_sdk"
    return
  fi

  local active=""
  active="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
  local candidates=()
  [[ -n "$active" ]] && candidates+=("$active")
  while IFS= read -r candidate; do
    candidates+=("$candidate")
  done < <(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d \
    -name 'MacOSX*.sdk' -print 2>/dev/null | sort -Vr)

  local seen=":"
  local candidate
  for candidate in "${candidates[@]}"; do
    candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" || continue
    [[ "$seen" == *":$candidate:"* ]] && continue
    seen+="$candidate:"
    if sdk_is_compatible "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  echo "No installed macOS SDK is compatible with $(swift --version | head -n 1)." >&2
  echo "Install or select a matching Xcode/Command Line Tools release." >&2
  return 1
}

SDK_PATH="$(resolve_sdk)"
export SDKROOT="$SDK_PATH"
echo "Using macOS SDK: $SDK_PATH"

swift build --sdk "$SDK_PATH"
BUILD_BINARY="$ROOT_DIR/.build/debug/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

visible_window_count() {
  /usr/bin/swift -e '
import CoreGraphics
import Foundation

let app = CommandLine.arguments.dropFirst().first ?? ""
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []

func number(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
}

let count = windows.filter { window in
    guard (window[kCGWindowOwnerName as String] as? String) == app else { return false }
    guard number(window[kCGWindowLayer as String]) == 0 else { return false }
    guard number(window[kCGWindowAlpha as String]) > 0 else { return false }
    guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return false }
    return number(bounds["Width"]) >= 100 && number(bounds["Height"]) >= 100
}.count

print(count)
' "$APP_NAME" 2>/dev/null || echo 0
}

case "$MODE" in
  build)
    ;;
  selfcheck)
    "$BUILD_BINARY" --selfcheck
    ;;
  pipeline)
    "$BUILD_BINARY" --pipeline
    ;;
  run)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    open_app
    ;;
  --debug|debug)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        WINDOW_COUNT="$(visible_window_count)"
        if [[ "$WINDOW_COUNT" -gt 0 ]]; then
          exit 0
        fi
      fi
      sleep 0.25
    done
    echo "$APP_NAME launched but no window became visible" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [build|run|verify|debug|logs|telemetry|selfcheck|pipeline]" >&2
    exit 2
    ;;
esac
