#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

APP_DOMAIN="${OPENBURNBAR_MAC_APP_DOMAIN:-com.openburnbar.app}"
REPORT_DIR="${OPENBURNBAR_REMOTE_UNLOCK_PROOF_DIR:-$ROOT_DIR/.derived-data/remote-unlock}"
REPORT_PATH="$REPORT_DIR/remote-unlock-certification-$(date -u +%Y%m%dT%H%M%SZ).json"
VIEWER_KIND="${OPENBURNBAR_REMOTE_UNLOCK_VIEWER_KIND:-unknown}"

require_path() {
  local path="$1"
  local message="$2"
  if [[ ! -e "$path" ]]; then
    printf 'error: %s\n' "$message" >&2
    exit 1
  fi
}

read_default() {
  local key="$1"
  defaults read "$APP_DOMAIN" "$key" 2>/dev/null || true
}

lock_mac() {
  local cg_session_candidates=(
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/SharedSupport/CGSession"
  )
  local candidate
  for candidate in "${cg_session_candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      "$candidate" -suspend
      return
    fi
  done

  if osascript -e 'tell application "System Events" to keystroke "q" using {control down, command down}' >/dev/null 2>&1; then
    return
  fi

  if pmset displaysleepnow >/dev/null 2>&1; then
    return
  fi

  printf 'error: No supported lock-screen command is available on this Mac.\n' >&2
  exit 1
}

if [[ ! -e "/System/Library/CoreServices/RemoteManagement/ARDAgent.app" && ! -e "/System/Applications/Utilities/Screen Sharing.app" && ! -e "/System/Library/CoreServices/Applications/Screen Sharing.app" ]]; then
  printf 'error: Apple Screen Sharing / Remote Management is not available on this Mac.\n' >&2
  exit 1
fi

if ! nc -z -G 1 127.0.0.1 5900 >/dev/null 2>&1; then
  printf 'error: Apple Screen Sharing / Remote Management is installed but not listening on 127.0.0.1:5900.\n' >&2
  printf 'Enable Remote Management / Screen Sharing for this Mac, then rerun this smoke.\n' >&2
  exit 1
fi

if [[ ! -e "/Library/LaunchDaemons/com.openburnbar.remote-access-agent.plist" ]]; then
  printf 'error: Remote Unlock requires the direct-download remote-access LaunchDaemon.\n' >&2
  printf 'Install or repair the OpenBurnBar remote-access daemon, then rerun this smoke.\n' >&2
  exit 1
fi

KEY_ID="$(read_default remote_unlock.credential_recipient_key_id)"
PUBLIC_KEY="$(read_default remote_unlock.credential_recipient_public_key_base64)"

if [[ -z "$KEY_ID" || -z "$PUBLIC_KEY" ]]; then
  printf 'error: Remote Unlock HPKE recipient key material has not been published by the Mac app.\n' >&2
  printf 'Open OpenBurnBar once on this Mac, wait for Mercury presence to refresh, then rerun this smoke.\n' >&2
  exit 1
fi

cat <<EOF
Remote Unlock hardware smoke

This test never asks for, stores, or prints your Mac password.

Before continuing:
  1. Open OpenBurnBar on this Mac and keep it running.
  2. Open Mercury screen sharing on iPhone, iPad, or Android.
  3. Confirm the viewer shows the Remote Unlock password lane.
  4. Be ready to enter the Mac password on the phone after this script locks the Mac.

Viewer kind recorded in the proof: $VIEWER_KIND
Recipient key: $KEY_ID
EOF

printf '\nPress Return to lock this Mac and start the hardware smoke, or Ctrl-C to abort. '
read -r _

lock_mac

cat <<'EOF'

The Mac is unlocked again.

Only certify this build if the unlock was completed from the OpenBurnBar phone/tablet
Remote Unlock overlay. If you unlocked manually at the keyboard, Touch ID, Apple Watch,
or another tool, answer anything except the exact phrase below.
EOF

printf '\nType REMOTE UNLOCK WORKED to record certification: '
read -r CONFIRMATION

if [[ "$CONFIRMATION" != "REMOTE UNLOCK WORKED" ]]; then
  printf 'Remote Unlock certification was not recorded.\n' >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"

swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI \
  remote-unlock-certification record-hardware-proof \
  --key-id "$KEY_ID" \
  --public-key-base64 "$PUBLIC_KEY" \
  --viewer-device-kind "$VIEWER_KIND" \
  --notes "Operator-confirmed locked-Mac Remote Unlock hardware smoke." \
  --output "$REPORT_PATH"

printf '\nProof artifact: %s\n' "$REPORT_PATH"
