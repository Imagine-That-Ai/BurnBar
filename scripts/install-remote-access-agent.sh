#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

LABEL="com.openburnbar.remote-access-agent"
IDENTIFIER="com.openburnbar.remote-access-agent"
ENTITLEMENTS="$ROOT_DIR/OpenBurnBarDaemon/Resources/RemoteAccessAgent/OpenBurnBarRemoteAccessAgent.entitlements"
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

# The agent runs as a root LaunchDaemon on a socket whose `typeCredential`
# requests carry the macOS login password. Clients authenticate the server
# against the first-party designated requirement before writing, so an
# unsigned / ad-hoc binary is both a trust failure for callers and a
# squattable root path. Fail closed: refuse to install unsigned builds.
# Local development may opt into an ad-hoc install explicitly via
# OPENBURNBAR_AGENT_ADHOC=1, which installs the same entitlement-bearing
# ad-hoc profile the virtual-HID bridge script uses for dev loops.
IDENTITY="${OPENBURNBAR_SIGNING_IDENTITY:-}"
if [[ "${OPENBURNBAR_AGENT_ADHOC:-0}" != "1" ]]; then
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
  fi
  if [[ -z "$IDENTITY" ]]; then
    echo "error: no Developer ID Application identity found; the remote-access agent must be signed." >&2
    echo "       Install the Developer ID certificate, set OPENBURNBAR_SIGNING_IDENTITY, or set" >&2
    echo "       OPENBURNBAR_AGENT_ADHOC=1 for an explicitly dev-only install." >&2
    exit 1
  fi
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

# Sign the staged binary with hardened runtime + library validation — the same
# CodeDirectory flags the peer designated requirement enforces on clients — so
# the installed root daemon satisfies the first-party trust gate its own
# clients run against it. A SECURE TIMESTAMP is mandatory for Developer ID
# code on modern macOS: without it AMFI kills the daemon at spawn
# (`OS_REASON_CODESIGNING`, verified 2026-09-04), so do NOT copy the
# `--timestamp=none` profile from scripts/sign-openburnbar-local.sh here.
#
# The ad-hoc dev lane keeps the exact identifier (the identifier assertion
# below applies to both lanes) but omits the Developer-ID-only options: a
# secure timestamp and hardened runtime require a real certificate chain, and
# the production client's designated requirement (Apple anchor + OpenBurnBar
# team) rejects ad-hoc code by design. A dev machine that opted into
# OPENBURNBAR_AGENT_ADHOC=1 therefore runs the daemon for LOCAL testing with
# a dev-signed client (or a temporarily injected validator); it is not a
# production trust lane. `scripts/verify-remote-access-agent.sh` fails closed
# on ad-hoc installs unless the same opt-in is set on the verifying host.
if [[ "${OPENBURNBAR_AGENT_ADHOC:-0}" == "1" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" --identifier "$IDENTIFIER" "$PRIVILEGED_STAGING_BIN"
else
  codesign \
    --force \
    --sign "$IDENTITY" \
    --timestamp \
    --options runtime,library \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$IDENTIFIER" \
    "$PRIVILEGED_STAGING_BIN"
fi

# Fail closed on any signing mistake before touching the privileged install
# path: the identifier must be exactly ours, and (for Developer ID installs)
# the signature must carry hardened runtime + library validation AND a secure
# timestamp (AMFI rejects timestamped-less Developer ID code at spawn).
SIGNATURE="$(codesign -d --verbose=4 "$PRIVILEGED_STAGING_BIN" 2>&1 || true)"
if ! grep -q "Identifier=$IDENTIFIER" <<<"$SIGNATURE"; then
  echo "error: staged agent is signed with the wrong identifier; expected $IDENTIFIER." >&2
  printf '%s\n' "$SIGNATURE" >&2
  exit 1
fi
if [[ "${OPENBURNBAR_AGENT_ADHOC:-0}" != "1" ]]; then
  if ! grep -q "flags=.*runtime" <<<"$SIGNATURE" \
    || ! grep -q "flags=.*library-validation" <<<"$SIGNATURE"; then
    echo "error: staged agent must be signed with hardened runtime and library validation." >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
  if ! grep -q "Authority=Developer ID Application" <<<"$SIGNATURE"; then
    echo "error: staged agent must carry a Developer ID Application signature." >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
  # The app's client trust gate pins the leaf OU to the OpenBurnBar team, so a
  # Developer ID certificate from ANY other team would install "successfully"
  # and then be rejected by every client on its first request. Fail at install
  # time with the same constraint the runtime enforces.
  if ! grep -q "^TeamIdentifier=4Y367DF25B" <<<"$SIGNATURE"; then
    echo "error: staged agent is signed by the wrong team (expected TeamIdentifier=4Y367DF25B)." >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
  if ! grep -q "^Timestamp=" <<<"$SIGNATURE"; then
    echo "error: staged agent must carry a secure signing timestamp; without one AMFI kills the daemon at spawn." >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
fi
codesign --verify --strict --verbose=2 "$PRIVILEGED_STAGING_BIN"

ADMIN_SCRIPT="$(cat <<SCRIPT
set -e
mkdir -p '$INSTALL_DIR'
# Write the binary fresh (cat >) instead of cp: macOS provenance attestation
# binds to the ORIGINAL build artifact, and re-signing invalidates it. A
# byte-copy of the re-signed file inherits a stale attestation, which
# xpcproxy rejects at spawn with OS_REASON_CODESIGNING ("embedded signature
# doesn't match attached signature", verified 2026-09-04). A fresh write
# records a new attestation for the signed bytes and launches cleanly.
cat '$PRIVILEGED_STAGING_BIN' > '$INSTALL_BIN'
chown root:wheel '$INSTALL_BIN'
chmod 755 '$INSTALL_BIN'
xattr -c '$INSTALL_BIN' 2>/dev/null || true
cp '$PRIVILEGED_STAGING_PLIST' '$PLIST_PATH'
chown root:wheel '$PLIST_PATH'
chmod 644 '$PLIST_PATH'
launchctl bootout system '$PLIST_PATH' >/dev/null 2>&1 || true
rm -f '$SOCKET_PATH'
rm -f /var/run/openburnbar-remote-access-agent.credential.*
launchctl bootstrap system '$PLIST_PATH'
launchctl enable system/$LABEL
launchctl kickstart -k system/$LABEL
SCRIPT
)"

osascript -e "do shell script $(printf '%s' "$ADMIN_SCRIPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))') with administrator privileges"

echo "Installed $LABEL"
launchctl print "system/$LABEL" | sed -n '1,80p'
