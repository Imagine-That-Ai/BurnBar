#!/bin/bash
# Build + relaunch the OpenBurnBar macOS dev build.
# Usage:  scripts/dev-mac.sh

set -euo pipefail

SCHEME="${SCHEME:-OpenBurnBar}"
DERIVED="${DERIVED:-build/DerivedData}"
APP_PATH="$DERIVED/Build/Products/Debug/OpenBurnBar.app"
TMUX_SESSION="${TMUX_SESSION:-openburnbar-dev}"

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
ABS_APP_PATH="$REPO_ROOT/$APP_PATH"

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
pgrep -f "$ABS_APP_PATH/Contents/MacOS/OpenBurnBar" | xargs -r kill 2>/dev/null || true
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

echo "▶ Launching $APP_PATH"
launch_with_tmux() {
  echo "⚠️  LaunchServices did not leave OpenBurnBar running; launching in detached tmux session '$TMUX_SESSION'…"
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for the fallback launcher when LaunchServices is unavailable." >&2
    exit 1
  fi
  tmux new-session -d -s "$TMUX_SESSION" "cd \"$REPO_ROOT\" && \"$ABS_APP_PATH/Contents/MacOS/OpenBurnBar\""
}

if open "$APP_PATH"; then
  sleep 2
  if ! pgrep -f "$ABS_APP_PATH/Contents/MacOS/OpenBurnBar" >/dev/null 2>&1; then
    launch_with_tmux
  fi
else
  launch_with_tmux
fi

sleep 2
echo "✅ Done. Running PIDs:"
pgrep -lf OpenBurnBar.app | head -3 || true
