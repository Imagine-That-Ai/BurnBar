#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="com.openburnbar.virtual-hid-bridge"
INSTALL_DIR="/Library/Application Support/OpenBurnBar/RemoteUnlock"
INSTALL_BIN="$INSTALL_DIR/openburnbar-virtual-hid-bridge"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
SOCKET_PATH="/var/run/openburnbar-virtual-hid.sock"
LOG_PATH="/var/log/openburnbar-virtual-hid-bridge.log"
ERR_LOG_PATH="/var/log/openburnbar-virtual-hid-bridge.err.log"
ENTITLEMENTS="$ROOT_DIR/OpenBurnBarDaemon/Resources/VirtualHIDBridge/OpenBurnBarVirtualHIDBridge.entitlements"
STAGING_DIR="$ROOT_DIR/build/virtual-hid-bridge-install"
STAGING_PLIST="$STAGING_DIR/$LABEL.plist"
PRIVILEGED_STAGING_DIR="/tmp/openburnbar-virtual-hid-bridge-install"
PRIVILEGED_STAGING_BIN="$PRIVILEGED_STAGING_DIR/openburnbar-virtual-hid-bridge"
PRIVILEGED_STAGING_PLIST="$PRIVILEGED_STAGING_DIR/$LABEL.plist"

mkdir -p "$STAGING_DIR"

swift build \
  --package-path OpenBurnBarDaemon \
  -c release \
  --product OpenBurnBarVirtualHIDBridge

BUILT_BIN="$ROOT_DIR/OpenBurnBarDaemon/.build/release/OpenBurnBarVirtualHIDBridge"
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "error: built virtual HID bridge is missing: $BUILT_BIN" >&2
  exit 1
fi

cat >"$STAGING_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_BIN</string>
    <string>--socket</string>
    <string>$SOCKET_PATH</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_PATH</string>
  <key>StandardErrorPath</key>
  <string>$ERR_LOG_PATH</string>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

plutil -lint "$STAGING_PLIST" >/dev/null

rm -rf "$PRIVILEGED_STAGING_DIR"
mkdir -p "$PRIVILEGED_STAGING_DIR"
cp "$BUILT_BIN" "$PRIVILEGED_STAGING_BIN"
cp "$STAGING_PLIST" "$PRIVILEGED_STAGING_PLIST"
chmod 755 "$PRIVILEGED_STAGING_BIN"
chmod 644 "$PRIVILEGED_STAGING_PLIST"

# Local development builds are ad-hoc signed with the virtual-HID entitlement.
# Production builds must use the Developer ID profile Apple grants for this
# entitlement; the runtime bridge logs `virtual_hid_device_unavailable` if the
# kernel rejects the entitlement.
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$PRIVILEGED_STAGING_BIN"

ADMIN_SCRIPT="$(cat <<SCRIPT
set -e
mkdir -p '$INSTALL_DIR'
cp '$PRIVILEGED_STAGING_BIN' '$INSTALL_BIN'
chown root:wheel '$INSTALL_BIN'
chmod 755 '$INSTALL_BIN'
cp '$PRIVILEGED_STAGING_PLIST' '$PLIST_PATH'
chown root:wheel '$PLIST_PATH'
chmod 644 '$PLIST_PATH'
launchctl bootout system '$PLIST_PATH' >/dev/null 2>&1 || true
rm -f '$SOCKET_PATH'
launchctl bootstrap system '$PLIST_PATH'
launchctl enable system/$LABEL
launchctl kickstart -k system/$LABEL
SCRIPT
)"

osascript -e "do shell script $(printf '%s' "$ADMIN_SCRIPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') with administrator privileges"

echo "Installed $LABEL"
launchctl print "system/$LABEL" | sed -n '1,80p'
echo
echo "Health probe:"
python3 - "$SOCKET_PATH" <<'PY'
import json, socket, sys
sock_path = sys.argv[1]
request = json.dumps({"operation":"health"}) + "\n"
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.settimeout(2)
    s.connect(sock_path)
    s.sendall(request.encode())
    print(s.recv(4096).decode().strip())
PY
