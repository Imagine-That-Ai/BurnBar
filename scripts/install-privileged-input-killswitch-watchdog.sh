#!/usr/bin/env bash
# Installs the privileged-input kill-switch watchdog LaunchDaemon.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="com.openburnbar.privileged-input-killswitch-watchdog"
INSTALL_DIR="/Library/Application Support/OpenBurnBar/RemoteUnlock"
INSTALL_BIN="$INSTALL_DIR/openburnbar-killswitch-watchdog"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
SOURCE_PLIST="$ROOT_DIR/OpenBurnBarDaemon/Resources/PrivilegedInputKillSwitch/$LABEL.plist"
STAGING_DIR="$ROOT_DIR/build/killswitch-watchdog-install"
PRIVILEGED_STAGING_DIR="/tmp/openburnbar-killswitch-watchdog-install"

mkdir -p "$STAGING_DIR"

swift build \
  --package-path OpenBurnBarDaemon \
  -c release \
  --product OpenBurnBarPrivilegedInputKillSwitchWatchdog

BUILT_BIN="$ROOT_DIR/OpenBurnBarDaemon/.build/release/OpenBurnBarPrivilegedInputKillSwitchWatchdog"
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "error: built watchdog binary is missing: $BUILT_BIN" >&2
  exit 1
fi

plutil -lint "$SOURCE_PLIST" >/dev/null

rm -rf "$PRIVILEGED_STAGING_DIR"
mkdir -p "$PRIVILEGED_STAGING_DIR"
cp "$BUILT_BIN" "$PRIVILEGED_STAGING_DIR/openburnbar-killswitch-watchdog"
cp "$SOURCE_PLIST" "$PRIVILEGED_STAGING_DIR/$LABEL.plist"
chmod 755 "$PRIVILEGED_STAGING_DIR/openburnbar-killswitch-watchdog"
chmod 644 "$PRIVILEGED_STAGING_DIR/$LABEL.plist"

ADMIN_SCRIPT="$(cat <<SCRIPT
set -e
mkdir -p '$INSTALL_DIR'
cp '$PRIVILEGED_STAGING_DIR/openburnbar-killswitch-watchdog' '$INSTALL_BIN'
chown root:wheel '$INSTALL_BIN'
chmod 755 '$INSTALL_BIN'
cp '$PRIVILEGED_STAGING_DIR/$LABEL.plist' '$PLIST_PATH'
chown root:wheel '$PLIST_PATH'
chmod 644 '$PLIST_PATH'
launchctl bootout system '$PLIST_PATH' >/dev/null 2>&1 || true
launchctl bootstrap system '$PLIST_PATH'
launchctl enable system/$LABEL
launchctl kickstart -k system/$LABEL
SCRIPT
)"

osascript -e "do shell script $(printf '%s' "$ADMIN_SCRIPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') with administrator privileges"

echo "Installed $LABEL"
launchctl print "system/$LABEL" | sed -n '1,40p'
