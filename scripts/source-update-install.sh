#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd)"
APP_NAME="OpenBurnBar.app"
CANONICAL_APP_PATH="${OPENBURNBAR_CANONICAL_APP_PATH:-/Applications/$APP_NAME}"
BUILT_APP_PATH="$ROOT_DIR/.derived-data/Build/Products/Release/$APP_NAME"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
BUNDLE_ID="com.openburnbar.app"

echo "==> Updating source checkout"
cd "$ROOT_DIR"
/usr/bin/git pull --ff-only

echo "==> Building signed OpenBurnBar"
/usr/bin/make build-signed

if [[ ! -d "$BUILT_APP_PATH" ]]; then
  echo "ERROR: Build did not produce $BUILT_APP_PATH" >&2
  exit 1
fi

echo "==> Quitting old OpenBurnBar instances"
/usr/bin/osascript -e 'tell application id "com.openburnbar.app" to quit' 2>/dev/null || true
/usr/bin/osascript -e 'tell application "OpenBurnBar" to quit' 2>/dev/null || true
/bin/sleep 2
/usr/bin/pkill -x OpenBurnBar 2>/dev/null || true
/usr/bin/pkill -x OpenBurnBarDaemon 2>/dev/null || true

echo "==> Installing $CANONICAL_APP_PATH"
/bin/mkdir -p "$(/usr/bin/dirname "$CANONICAL_APP_PATH")"
STAGE="$CANONICAL_APP_PATH.new-$$"
BACKUP="$CANONICAL_APP_PATH.bak-$$"
/bin/rm -rf "$STAGE" "$BACKUP"
/usr/bin/ditto "$BUILT_APP_PATH" "$STAGE"
if [[ -e "$CANONICAL_APP_PATH" ]]; then
  /bin/mv "$CANONICAL_APP_PATH" "$BACKUP"
fi
if /bin/mv "$STAGE" "$CANONICAL_APP_PATH"; then
  /bin/rm -rf "$BACKUP"
else
  echo "ERROR: Could not move updated app into place; rolling back." >&2
  /bin/rm -rf "$CANONICAL_APP_PATH"
  [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$CANONICAL_APP_PATH"
  /bin/rm -rf "$STAGE"
  exit 1
fi
/usr/bin/xattr -dr com.apple.quarantine "$CANONICAL_APP_PATH" 2>/dev/null || true

echo "==> Normalizing LaunchServices"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f -R -trusted "$CANONICAL_APP_PATH" 2>/dev/null || true
  "$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk -v bundle="$BUNDLE_ID" -v dest="$CANONICAL_APP_PATH" '
    function flush() {
      if (identifier == bundle && platform == "native" && path != dest && path ~ /\/OpenBurnBar\.app$/) {
        print path
      }
      path=""; identifier=""; platform=""
    }
    /^path:[[:space:]]/ {
      path=$0
      sub(/^path:[[:space:]]*/, "", path)
      sub(/[[:space:]]*\(0x[0-9a-fA-F]+\).*$/, "", path)
    }
    /^identifier:[[:space:]]/ {
      identifier=$0
      sub(/^identifier:[[:space:]]*/, "", identifier)
    }
    /^platform:[[:space:]]/ {
      platform=$0
      sub(/^platform:[[:space:]]*/, "", platform)
    }
    /^-+$/ { flush() }
    END { flush() }
  ' | while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && "$LSREGISTER" -u "$candidate" 2>/dev/null || true
  done || true
  /usr/bin/mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | while IFS= read -r candidate; do
    [[ "$candidate" == "$CANONICAL_APP_PATH" ]] && continue
    case "$candidate" in
      */OpenBurnBar.app) "$LSREGISTER" -u "$candidate" 2>/dev/null || true ;;
    esac
  done || true
  "$LSREGISTER" -f -R -trusted "$CANONICAL_APP_PATH" 2>/dev/null || true
fi

echo "==> Launching latest installed OpenBurnBar"
/usr/bin/open "$CANONICAL_APP_PATH"
echo "==> Done"
