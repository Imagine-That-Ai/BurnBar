#!/bin/bash
# Build + relaunch the OpenBurnBar macOS dev build.
# Usage:  scripts/dev-mac.sh

set -euo pipefail

SCHEME="${SCHEME:-OpenBurnBar}"
DERIVED="${DERIVED:-build/DerivedData}"
APP_PATH="$DERIVED/Build/Products/Debug/OpenBurnBar.app"

cd "$(dirname "$0")/.."

echo "▶ Building $SCHEME for macOS…"
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -quiet \
  build

echo "▶ Quitting any running OpenBurnBar instance…"
osascript -e 'tell application "OpenBurnBar" to quit' 2>/dev/null || true
sleep 1
# Force-kill if a stale instance lingers.
pgrep -f "$(pwd)/$APP_PATH/Contents/MacOS/OpenBurnBar" | xargs -r kill 2>/dev/null || true

echo "▶ Launching $APP_PATH"
open "$APP_PATH"

sleep 2
echo "✅ Done. Running PIDs:"
pgrep -lf OpenBurnBar.app | head -3 || true
