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
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$REPO_ROOT/scripts/lib/libsignal-swift-compat.sh"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$REPO_ROOT/scripts/lib/xcode-source-classification.sh"
openburnbar_configure_xcode_process_tmpdir

cleanup() {
  local original_status="${1:-0}"
  local google_restore_status=0
  local libsignal_restore_status=0
  openburnbar_restore_google_sign_in_macos_compat || google_restore_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_restore_status=$?
  local restore_status="$google_restore_status"
  if ((restore_status == 0)); then
    restore_status="$libsignal_restore_status"
  fi
  if ((original_status == 0 && restore_status != 0)); then
    return "$restore_status"
  fi
  return "$original_status"
}
cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup "$original_status"
  exit $?
}
trap cleanup_on_exit EXIT

ABS_APP_PATH="$REPO_ROOT/$APP_PATH"
OPENBURNBAR_DEV_APP_EXEC="$ABS_APP_PATH/Contents/MacOS/OpenBurnBar"
PACKAGE_CACHE="${OPENBURNBAR_DEV_PACKAGE_CACHE:-$REPO_ROOT/.spm-cache}"

echo "▶ Building $SCHEME for macOS…"
mkdir -p "$PACKAGE_CACHE"
xcodebuild -resolvePackageDependencies \
  -project OpenBurnBar.xcodeproj \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
  -derivedDataPath "$DERIVED"
openburnbar_prepare_google_sign_in_macos_compat "$PACKAGE_CACHE"
openburnbar_prepare_libsignal_swift_compat "$REPO_ROOT"
xcodebuild \
  -project OpenBurnBar.xcodeproj \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -clonedSourcePackagesDirPath "$PACKAGE_CACHE" \
  -derivedDataPath "$DERIVED" \
  -disableAutomaticPackageResolution \
  -allowProvisioningUpdates \
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
  -quiet \
  build

echo "▶ Quitting any running OpenBurnBar instance…"
osascript -e 'tell application "OpenBurnBar" to quit' 2>/dev/null || true
sleep 1
# Force-kill if a stale instance lingers.
pgrep -f "$OPENBURNBAR_DEV_APP_EXEC" | xargs -r kill 2>/dev/null || true
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

echo "▶ Launching $APP_PATH"
launch_with_tmux() {
  echo "⚠️  LaunchServices did not leave OpenBurnBar running; launching in detached tmux session '$TMUX_SESSION'…"
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux is required for the fallback launcher when LaunchServices is unavailable." >&2
    exit 1
  fi
  tmux new-session \
    -d \
    -s "$TMUX_SESSION" \
    -c "$REPO_ROOT" \
    -e "OPENBURNBAR_DEV_APP_EXEC=$OPENBURNBAR_DEV_APP_EXEC" \
    'exec "$OPENBURNBAR_DEV_APP_EXEC"'
}

if open "$APP_PATH"; then
  sleep 2
  if ! pgrep -f "$OPENBURNBAR_DEV_APP_EXEC" >/dev/null 2>&1; then
    launch_with_tmux
  fi
else
  launch_with_tmux
fi

sleep 2
echo "✅ Done. Running PIDs:"
pgrep -lf OpenBurnBar.app | head -3 || true
