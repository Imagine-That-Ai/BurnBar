#!/bin/bash
# Build + install + launch OpenBurnBarMobile on Alberto's iPhone 17 Pro Max.
# Usage:  scripts/dev-iphone.sh
#
# To target a different device, override DEVICE_ID before running:
#   DEVICE_ID=<UDID> scripts/dev-iphone.sh

set -euo pipefail

DEVICE_ID="${DEVICE_ID:-AFB07C15-AD18-5EFA-AD1C-CADB4F286797}"   # iPhone 17 Pro Max
BUNDLE_ID="${BUNDLE_ID:-com.openburnbar.app}"
SCHEME="${SCHEME:-OpenBurnBarMobile}"
DERIVED="${DERIVED:-build/DerivedData}"

cd "$(dirname "$0")/.."

echo "▶ Building $SCHEME for device $DEVICE_ID…"
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme "$SCHEME" \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -quiet \
  build

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app"
echo "▶ Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "▶ Launching $BUNDLE_ID"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "✅ Done."
