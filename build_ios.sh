#!/bin/bash
# Build Readlet for iOS / iPadOS (Simulator + Physical Device) with iCloud Sync.
#
# Usage:
#   ./build_ios.sh                   Build both Simulator (.app) and Physical Device (.app + .ipa)
#   ./build_ios.sh sim               Build Simulator .app only
#   ./build_ios.sh run-sim           Build, install, and launch on the iPhone Simulator
#   ./build_ios.sh device            Build Physical Device .app and dist/Readlet-iOS.ipa
set -e
cd "$(dirname "$0")"
[ -f .env.local ] && . ./.env.local

MODE="${1:-all}"
VERSION=$(cat VERSION)
BUILD=${BUILD:-$(( $(git rev-list --count HEAD 2>/dev/null || echo 1) + 2 ))}
NAME=Readlet
BUNDLE_ID=io.novarock.readlet
TEAM_ID="${TEAM_ID:-}"

mkdir -p build dist

prepare_ios_resources() {
  local APP_DIR="$1"
  local PLATFORM_NAME="$2"
  local SDK_NAME="$3"

  mkdir -p "$APP_DIR"
  cp Resources/PrivacyInfo.xcprivacy "$APP_DIR/" 2>/dev/null || true
  cp Resources/Acknowledgements.md "$APP_DIR/" 2>/dev/null || true
  mkdir -p "$APP_DIR/web"
  cp Resources/web/*.js "$APP_DIR/web/" 2>/dev/null || true

  for l in en zh-Hans ja; do
    mkdir -p "$APP_DIR/$l.lproj"
    printf '"CFBundleDisplayName" = "%s";\n' "$NAME" > "$APP_DIR/$l.lproj/InfoPlist.strings"
  done

  # Generate full-bleed iOS AppIcon PNGs and Assets.car from Resources/icon-ios.png (zero black border)
  local ICON_SRC="Resources/icon-ios.png"
  [ ! -f "$ICON_SRC" ] && ICON_SRC="Resources/icon.png"
  if [ -f "$ICON_SRC" ]; then
    sips -s format png -z 120 120 "$ICON_SRC" --out "$APP_DIR/AppIcon60x60@2x.png" >/dev/null 2>&1 || true
    sips -s format png -z 180 180 "$ICON_SRC" --out "$APP_DIR/AppIcon60x60@3x.png" >/dev/null 2>&1 || true
    sips -s format png -z 152 152 "$ICON_SRC" --out "$APP_DIR/AppIcon76x76@2x~ipad.png" >/dev/null 2>&1 || true
    sips -s format png -z 167 167 "$ICON_SRC" --out "$APP_DIR/AppIcon83.5x83.5@2x~ipad.png" >/dev/null 2>&1 || true

    local XCASSETS="build/Assets.xcassets/AppIcon.appiconset"
    rm -rf "build/Assets.xcassets" "build/actool-partial.plist"
    mkdir -p "$XCASSETS"
    cp "$ICON_SRC" "$XCASSETS/AppIcon-1024.png"
    cp "$APP_DIR/AppIcon60x60@2x.png" "$XCASSETS/AppIcon-120.png"
    cp "$APP_DIR/AppIcon60x60@3x.png" "$XCASSETS/AppIcon-180.png"
    cp "$APP_DIR/AppIcon76x76@2x~ipad.png" "$XCASSETS/AppIcon-152.png"
    cp "$APP_DIR/AppIcon83.5x83.5@2x~ipad.png" "$XCASSETS/AppIcon-167.png"
    cat > "$XCASSETS/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "AppIcon-120.png", "idiom" : "iphone", "scale" : "2x", "size" : "60x60" },
    { "filename" : "AppIcon-180.png", "idiom" : "iphone", "scale" : "3x", "size" : "60x60" },
    { "filename" : "AppIcon-152.png", "idiom" : "ipad", "scale" : "2x", "size" : "76x76" },
    { "filename" : "AppIcon-167.png", "idiom" : "ipad", "scale" : "2x", "size" : "83.5x83.5" },
    { "filename" : "AppIcon-1024.png", "idiom" : "ios-marketing", "scale" : "1x", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
    xcrun actool "build/Assets.xcassets" \
      --compile "$APP_DIR" \
      --platform "$SDK_NAME" \
      --minimum-deployment-target 17.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "build/actool-partial.plist" >/dev/null 2>&1 || true
  fi

  local SDK_VER=$(xcrun --sdk "$SDK_NAME" --show-sdk-version 2>/dev/null || echo 18.0)
  local SDK_BUILD=$(xcrun --sdk "$SDK_NAME" --show-sdk-build-version 2>/dev/null || echo "")
  local XC=$(xcodebuild -version 2>/dev/null | awk '/^Xcode/{print $2}' | tr -d . ; true)
  local XCB=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}'; true)
  local OSB=$(sw_vers -buildVersion 2>/dev/null || echo "")
  [ ${#XC} -eq 2 ] && XC="${XC}00"; [ ${#XC} -eq 3 ] && XC="0${XC}"

  mkdir -p "$APP_DIR/en.lproj" "$APP_DIR/zh-Hans.lproj" "$APP_DIR/ja.lproj"

  cat > "$APP_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
    <string>ja</string>
  </array>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>$PLATFORM_NAME</string>
  </array>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIDeviceFamily</key>
  <array>
    <integer>1</integer>
    <integer>2</integer>
  </array>
  <key>UIRequiredDeviceCapabilities</key>
  <array>
    <string>arm64</string>
  </array>
  <key>UILaunchScreen</key>
  <dict>
    <key>UIColorName</key><string>AccentColor</string>
  </dict>
  <key>CFBundleIcons</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon60x60</string>
      </array>
      <key>CFBundleIconName</key>
      <string>AppIcon</string>
      <key>UIPrerenderedIcon</key><false/>
    </dict>
  </dict>
  <key>CFBundleIcons~ipad</key>
  <dict>
    <key>CFBundlePrimaryIcon</key>
    <dict>
      <key>CFBundleIconFiles</key>
      <array>
        <string>AppIcon60x60</string>
        <string>AppIcon76x76</string>
        <string>AppIcon83.5x83.5</string>
      </array>
      <key>CFBundleIconName</key>
      <string>AppIcon</string>
      <key>UIPrerenderedIcon</key><false/>
    </dict>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UIBackgroundModes</key>
  <array>
    <string>audio</string>
    <string>remote-notification</string>
  </array>
  <key>UIFileSharingEnabled</key><true/>
  <key>LSSupportsOpeningDocumentsInPlace</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Hold the mic during AI narration to ask a question by voice. / AI 解读时按住麦克风语音提问。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Turns your spoken question into text. / 把你的语音提问转成文字。</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSUbiquitousContainers</key>
  <dict>
    <key>iCloud.io.novarock.readlet</key>
    <dict>
      <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
      <key>NSUbiquitousContainerName</key><string>Readlet</string>
      <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
    </dict>
  </dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>io.novarock.readlet</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>readlet</string>
      </array>
    </dict>
  </array>
  <key>DTPlatformName</key><string>$SDK_NAME</string>
  <key>DTPlatformVersion</key><string>$SDK_VER</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>${SDK_NAME}${SDK_VER}</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTXcode</key><string>$XC</string>
  <key>DTXcodeBuild</key><string>$XCB</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>BuildMachineOSBuild</key><string>$OSB</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
PLIST
  printf 'APPL????' > "$APP_DIR/PkgInfo"
}

build_simulator() {
  echo "==> Building Readlet for iOS Simulator (arm64-apple-ios17.0-simulator)…"
  local SIM_APP="build/Readlet-iOS-Simulator.app"
  rm -rf "$SIM_APP"
  prepare_ios_resources "$SIM_APP" "iPhoneSimulator" "iphonesimulator"
  xcrun --sdk iphonesimulator swiftc \
    -target arm64-apple-ios17.0-simulator \
    -parse-as-library \
    -module-name Readlet \
    -O \
    Sources/Readlet/*.swift \
    -o "$SIM_APP/$NAME"
  codesign --force --sign - "$SIM_APP"
  echo "✅ Built $SIM_APP"
}

build_device() {
  echo "==> Building Readlet for iOS Physical Device (arm64-apple-ios17.0)…"
  local DEV_APP="build/Readlet-iOS.app"
  rm -rf "$DEV_APP" "build/Readlet-iOS.app.dSYM"
  prepare_ios_resources "$DEV_APP" "iPhoneOS" "iphoneos"
  xcrun --sdk iphoneos swiftc \
    -target arm64-apple-ios17.0 \
    -parse-as-library \
    -module-name Readlet \
    -O -g \
    Sources/Readlet/*.swift \
    -o "$DEV_APP/$NAME"
  dsymutil "$DEV_APP/$NAME" -o "build/Readlet-iOS.app.dSYM" 2>/dev/null || true
  rm -rf "$DEV_APP/$NAME.dSYM"
  strip -x "$DEV_APP/$NAME" 2>/dev/null || true

  if [ -f "Resources/Readlet-iOS.mobileprovision" ]; then
    cp "Resources/Readlet-iOS.mobileprovision" "$DEV_APP/embedded.mobileprovision"
  elif [ -f "build/Readlet-iOS.mobileprovision" ]; then
    cp "build/Readlet-iOS.mobileprovision" "$DEV_APP/embedded.mobileprovision"
  fi

  SIGN_FILTER="${DEV_SIGN_IDENTITY:-Apple Development:}"
  DEV_SIGN=$(security find-identity -v -p codesigning | sed -n "s/.*\"\\(${SIGN_FILTER}[^\"]*\\)\"/\\1/p" | head -1)
  if [ -n "$DEV_SIGN" ] && [ -f "$DEV_APP/embedded.mobileprovision" ] && [ -n "$TEAM_ID" ]; then
    sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" Resources/Readlet-iOS.entitlements > build/readlet-ios.entitlements
    codesign --force --entitlements build/readlet-ios.entitlements --generate-entitlement-der --sign "$DEV_SIGN" "$DEV_APP"
  elif [ -n "$DEV_SIGN" ]; then
    codesign --force --sign "$DEV_SIGN" --generate-entitlement-der "$DEV_APP" 2>/dev/null || codesign --force --sign - "$DEV_APP"
  else
    codesign --force --sign - "$DEV_APP"
  fi

  rm -rf build/Payload "dist/Readlet-$VERSION-iOS.ipa"
  mkdir -p build/Payload
  cp -R "$DEV_APP" build/Payload/Readlet.app
  (cd build && zip -qr "../dist/Readlet-$VERSION-iOS.ipa" Payload)
  rm -rf build/Payload
  echo "✅ Built $DEV_APP and dist/Readlet-$VERSION-iOS.ipa"
}

build_appstore() {
  : "${TEAM_ID:?set TEAM_ID in environment or .env.local}"
  [ -d "build/Readlet-iOS.app" ] || build_device
  echo "==> Exporting Readlet iOS App Store .ipa via Xcode Cloud-Managed Distribution ($TEAM_ID)…"
  local ARCHIVE="build/ios-mas/$NAME-iOS.xcarchive"
  local EXPORT_DIR="build/ios-mas/export"
  rm -rf "$ARCHIVE" "$EXPORT_DIR"
  mkdir -p "$ARCHIVE/Products/Applications" "$ARCHIVE/dSYMs"
  cp -R "build/Readlet-iOS.app" "$ARCHIVE/Products/Applications/$NAME.app"
  if [ -d "build/Readlet-iOS.app.dSYM" ]; then
    cp -R "build/Readlet-iOS.app.dSYM" "$ARCHIVE/dSYMs/$NAME.app.dSYM"
  fi
  SIGN_FILTER="${DEV_SIGN_IDENTITY:-Apple Development:}"
  DEV_SIGN=$(security find-identity -v -p codesigning | sed -n "s/.*\"\\(${SIGN_FILTER}[^\"]*\\)\"/\\1/p" | head -1)
  cat > "$ARCHIVE/Info.plist" <<A
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/$NAME.app</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>SigningIdentity</key><string>$DEV_SIGN</string>
    <key>Team</key><string>$TEAM_ID</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>$NAME</string>
  <key>SchemeName</key><string>$NAME</string>
</dict></plist>
A
  cat > build/ios-mas/ExportOptions.plist <<X
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
X
  local ASC_AUTH_ARGS=()
  local P8_FILE="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID:-}.p8}"
  [ -f "$P8_FILE" ] || P8_FILE=$(ls "$HOME/.appstoreconnect/private_keys/AuthKey_"*.p8 "$HOME/.asc/keys/AuthKey_"*.p8 2>/dev/null | head -1 || true)
  if [ -n "$P8_FILE" ] && [ -f "$P8_FILE" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    ASC_AUTH_ARGS=(-authenticationKeyPath "$P8_FILE" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  fi
  PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH" xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist build/ios-mas/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" \
    -allowProvisioningUpdates \
    "${ASC_AUTH_ARGS[@]}"
  if [ -f "$EXPORT_DIR/$NAME.ipa" ]; then
    cp "$EXPORT_DIR/$NAME.ipa" "dist/Readlet-$VERSION-iOS-AppStore.ipa"
    echo "✅ Packaged dist/Readlet-$VERSION-iOS-AppStore.ipa"
  fi
}

case "$MODE" in
  sim)
    build_simulator
    ;;
  device)
    build_device
    ;;
  appstore)
    build_device
    build_appstore
    ;;
  run-sim)
    build_simulator
    SIM_UDID=$(xcrun simctl list devices available | grep -E "iPhone.*\(Booted\)" | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' | head -1)
    if [ -z "$SIM_UDID" ]; then
      SIM_UDID=$(xcrun simctl list devices available | grep -E "iPhone 1[67] Pro " | sed -E 's/.*\(([0-9A-F-]+)\).*/\1/' | head -1)
      if [ -n "$SIM_UDID" ]; then
        echo "==> Booting Simulator $SIM_UDID…"
        xcrun simctl boot "$SIM_UDID" || true
      fi
    fi
    open -a Simulator || true
    xcrun simctl install "$SIM_UDID" "build/Readlet-iOS-Simulator.app"
    xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID"
    ;;
  *)
    build_simulator
    build_device
    ;;
esac
