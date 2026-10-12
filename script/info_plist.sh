# shellcheck shell=bash
# The app's Info.plist. script/build_and_run.sh sources this and writes it into the bundle (every
# release and App Store build goes through that script); the tests source it to read the keys.
# write_info_plist prints it from APP_NAME, BUNDLE_ID, APP_VERSION, BUILD_NUMBER, MIN_SYSTEM_VERSION
# and COPYRIGHT, and with SDK_PATH set adds the toolchain the app was built with.

# What Xcode records about the toolchain in the Info.plist; App Store Connect checks the Xcode
# and SDK versions an upload was built with.
toolchain_plist_keys() {
  [[ -n "${SDK_PATH:-}" ]] || return 0
  local xcode_version xcode_build sdk_version sdk_build major minor patch
  xcode_version="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / {print $2}')" || true
  [[ -n "$xcode_version" ]] || return 0
  xcode_build="$(xcodebuild -version | awk '/^Build version / {print $3}')"
  sdk_version="$(xcrun --sdk "$SDK_PATH" --show-sdk-version)"
  sdk_build="$(xcrun --sdk "$SDK_PATH" --show-sdk-build-version)"
  IFS=. read -r major minor patch <<<"$xcode_version"
  cat <<KEYS
  <key>BuildMachineOSBuild</key>
  <string>$(sw_vers -buildVersion)</string>
  <key>DTCompiler</key>
  <string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformBuild</key>
  <string>$sdk_build</string>
  <key>DTPlatformName</key>
  <string>macosx</string>
  <key>DTPlatformVersion</key>
  <string>$sdk_version</string>
  <key>DTSDKBuild</key>
  <string>$sdk_build</string>
  <key>DTSDKName</key>
  <string>macosx$sdk_version</string>
  <key>DTXcode</key>
  <string>$(printf '%d%d%d' "$major" "${minor:-0}" "${patch:-0}")</string>
  <key>DTXcodeBuild</key>
  <string>$xcode_build</string>
KEYS
}

write_info_plist() {
  cat <<PLIST
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
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.photography</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT</string>
  <!-- HTTPS through the system only: exempt from export compliance documentation -->
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <!-- language models served on this Mac (Ollama, LM Studio) speak plain HTTP -->
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <!-- A .photolibrary catalog has Apple's type, whose default app is Photos. Declared as an alternate
       handler, the app is offered in Finder's Open With and can be made the default there
       (docs/features.md); it doesn't redeclare the type. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>PhotoCatalog Catalog</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.apple.photo.library</string>
      </array>
      <key>LSTypeIsPackage</key>
      <true/>
    </dict>
  </array>
$(toolchain_plist_keys)
</dict>
</plist>
PLIST
}
