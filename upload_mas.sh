#!/bin/bash
# Validate and upload the App Store package to App Store Connect.
# Uses an App Store Connect API key (Users and Access → Integrations → App Store Connect API):
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=xxxxxxxx-xxxx-… ./upload_mas.sh dist/Readlet-1.0.0-AppStore.pkg
# The .p8 key file must be at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
# (Alternative: open the .pkg with Apple's Transporter app.)
set -e
cd "$(dirname "$0")"
[ -f .env.local ] && . ./.env.local
PKG=${1:-dist/Readlet-$(cat VERSION)-AppStore.pkg}
: "${TEAM_ID:?set TEAM_ID in environment or .env.local}"

if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
  xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  xcrun altool --upload-app   -f "$PKG" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
elif [ -d "build/mas/Readlet.xcarchive" ]; then
  cat > build/mas/UploadOptions.plist <<X
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
X
  rm -rf build/mas/upload
  xcodebuild -exportArchive -archivePath build/mas/Readlet.xcarchive -exportOptionsPlist build/mas/UploadOptions.plist -exportPath build/mas/upload -allowProvisioningUpdates
else
  echo "error: either set ASC_KEY_ID + ASC_ISSUER_ID or run ./build_mas.sh first to generate build/mas/Readlet.xcarchive"
  exit 1
fi
echo "uploaded — the build appears in App Store Connect → TestFlight after processing (10–30 min)"
