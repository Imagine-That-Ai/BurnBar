#!/bin/bash
# Build + install + launch OpenBurnBarMobile on Alberto's iPhone 17 Pro Max.
# Usage:  scripts/dev-iphone.sh
#
# To target a different device, override DEVICE_ID before running:
#   DEVICE_ID=<UDID> scripts/dev-iphone.sh
#
# CoreDevice and Xcode sometimes expose different identifiers for the same
# phone. DEVICE_ID is the CoreDevice id used by devicectl; IOS_DEPLOY_ID is
# the classic USB UDID used by ios-deploy fallback.

set -euo pipefail

DEVICE_ID="${DEVICE_ID:-AFB07C15-AD18-5EFA-AD1C-CADB4F286797}"   # iPhone 17 Pro Max
IOS_DEPLOY_ID="${IOS_DEPLOY_ID:-00008150-00180C661EF0401C}"
BUNDLE_ID="${BUNDLE_ID:-com.openburnbar.app}"
SCHEME="${SCHEME:-OpenBurnBarMobile}"
DERIVED="${DERIVED:-build/DerivedData}"
XCODE_DESTINATION="${XCODE_DESTINATION:-generic/platform=iOS}"

cd "$(dirname "$0")/.."

if [[ -x "tools/qa/inject-app-check-debug-token.sh" ]]; then
  echo "▶ Ensuring local App Check debug token is stamped…"
  tools/qa/inject-app-check-debug-token.sh >/dev/null
fi

echo "▶ Building ${SCHEME} for ${XCODE_DESTINATION}…"
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme "${SCHEME}" \
  -destination "${XCODE_DESTINATION}" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -quiet \
  build

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app"
echo "▶ Installing ${APP_PATH}"
if xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"; then
  echo "▶ Launching ${BUNDLE_ID}"
  xcrun devicectl device process launch --device "${DEVICE_ID}" "${BUNDLE_ID}"
  echo "✅ Done."
  exit 0
fi

echo "⚠️  devicectl install failed; trying ios-deploy over USB (${IOS_DEPLOY_ID})..."
if ! command -v ios-deploy >/dev/null 2>&1; then
  echo "ios-deploy is not installed and devicectl could not install the app." >&2
  exit 1
fi

set +e
IOS_DEPLOY_OUTPUT="$(ios-deploy --id "${IOS_DEPLOY_ID}" --bundle "${APP_PATH}" --justlaunch 2>&1)"
IOS_DEPLOY_STATUS=$?
set -e

printf '%s\n' "$IOS_DEPLOY_OUTPUT"

if [ "$IOS_DEPLOY_STATUS" -eq 0 ]; then
  echo "✅ Done."
  exit 0
fi

if printf '%s\n' "$IOS_DEPLOY_OUTPUT" | grep -q "Installed package"; then
  echo "⚠️  Installed via ios-deploy, but launch did not complete. Open OpenBurnBar manually on the iPhone."
  exit 0
fi

exit "$IOS_DEPLOY_STATUS"
