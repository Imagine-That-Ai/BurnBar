#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="com.openburnbar.remote-access-agent"
INSTALL_DIR="/Library/Application Support/OpenBurnBar/RemoteAccess"
INSTALL_BIN="$INSTALL_DIR/openburnbar-remote-access-agent"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
SOCKET_PATH="/var/run/openburnbar-remote-access-agent.sock"
STAGING_DIR="$ROOT_DIR/build/remote-access-agent-install"
STAGING_PLIST="$STAGING_DIR/$LABEL.plist"
PRIVILEGED_STAGING_DIR="/tmp/openburnbar-remote-access-agent-install"
PRIVILEGED_STAGING_BIN="$PRIVILEGED_STAGING_DIR/openburnbar-remote-access-agent"
PRIVILEGED_STAGING_PLIST="$PRIVILEGED_STAGING_DIR/$LABEL.plist"

mkdir -p "$STAGING_DIR"

swift build \
  --package-path OpenBurnBarDaemon \
  -c release \
  --product OpenBurnBarRemoteAccessAgent

BUILT_BIN="$ROOT_DIR/OpenBurnBarDaemon/.build/release/OpenBurnBarRemoteAccessAgent"
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "error: built remote-access agent is missing: $BUILT_BIN" >&2
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
  <string>/var/log/openburnbar-remote-access-agent.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/openburnbar-remote-access-agent.err.log</string>
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
