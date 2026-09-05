#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:?Usage: sign-openburnbar-local.sh <OpenBurnBar.app> [entitlements]}"
ENTITLEMENTS_SOURCE="${2:-AgentLens/Resources/OpenBurnBar.entitlements}"
IDENTITY="${OPENBURNBAR_SIGNING_IDENTITY:-}"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

if [[ ! -f "$ENTITLEMENTS_SOURCE" ]]; then
  echo "ERROR: Entitlements file not found: $ENTITLEMENTS_SOURCE" >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ -z "$IDENTITY" ]]; then
  echo "ERROR: No Apple Development code-signing identity found." >&2
  echo "Install an Apple Development certificate in Keychain, or set OPENBURNBAR_SIGNING_IDENTITY." >&2
  exit 1
fi

TEAM_ID="${OPENBURNBAR_TEAM_ID:-}"
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(
    security find-certificate -c "$IDENTITY" -p \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' \
      | head -n 1
  )"
fi

if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/' <<<"$IDENTITY")"
fi

if [[ ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Could not infer the 10-character Team ID from signing identity: $IDENTITY" >&2
  echo "Set OPENBURNBAR_TEAM_ID explicitly." >&2
  exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
TEMP_ENTITLEMENTS="$(mktemp -t openburnbar-entitlements.XXXXXX.plist)"
trap 'rm -f "$TEMP_ENTITLEMENTS"' EXIT

python3 - "$ENTITLEMENTS_SOURCE" "$TEMP_ENTITLEMENTS" "$TEAM_ID" "$BUNDLE_ID" "${OPENBURNBAR_FULL_ENTITLEMENTS:-0}" <<'PY'
from pathlib import Path
import plistlib
import sys

source, destination, team_id, bundle_id, full_entitlements = sys.argv[1:6]
if full_entitlements == "1":
    text = Path(source).read_text()
    text = text.replace("$(AppIdentifierPrefix)", f"{team_id}.")
    text = text.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
    Path(destination).write_text(text)
else:
    entitlements = {
        "com.apple.security.app-sandbox": False,
        "com.apple.security.files.user-selected.read-only": True,
    }
    if full_entitlements != "none":
        entitlements["keychain-access-groups"] = [f"{team_id}.{bundle_id}"]
    with Path(destination).open("wb") as file:
        plistlib.dump(entitlements, file)
PY

if [[ ! -x "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon" ]]; then
  for candidate in \
    "OpenBurnBarDaemon/.build/release/OpenBurnBarDaemon" \
    "OpenBurnBarDaemon/.build/arm64-apple-macosx/release/OpenBurnBarDaemon" \
    "OpenBurnBarDaemon/.build/arm64-apple-macosx/debug/OpenBurnBarDaemon" \
    "OpenBurnBarDaemon/.build/out/Products/Debug/OpenBurnBarDaemon"; do
    if [[ -x "$candidate" ]]; then
      mkdir -p "$APP_BUNDLE/Contents/Helpers"
      cp "$candidate" "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon"
      break
    fi
  done
fi

if [[ ! -x "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI" ]]; then
  for candidate in \
    "OpenBurnBarDaemon/.build/release/OpenBurnBarCLI" \
    "OpenBurnBarDaemon/.build/arm64-apple-macosx/release/OpenBurnBarCLI" \
    "OpenBurnBarDaemon/.build/arm64-apple-macosx/debug/OpenBurnBarCLI" \
    "OpenBurnBarDaemon/.build/out/Products/Debug/OpenBurnBarCLI"; do
    if [[ -x "$candidate" ]]; then
      mkdir -p "$APP_BUNDLE/Contents/Helpers"
      cp "$candidate" "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI"
      break
    fi
  done
fi

ensure_helper_rpath() {
  local helper="$1"
  [[ -f "$helper" ]] || return 0
  if otool -L "$helper" 2>/dev/null | grep -q 'SQLCipher.framework'; then
    if ! otool -l "$helper" 2>/dev/null | grep -q '@executable_path/../Frameworks'; then
      install_name_tool -add_rpath "@executable_path/../Frameworks" "$helper" 2>/dev/null || true
    fi
  fi
}

ensure_helper_rpath "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon"
ensure_helper_rpath "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI"

sign_path() {
  local path="$1"
  local options="${2:-runtime}"
  local identifier="${3:-}"
  local preserve_metadata="${4:-}"
  [[ -e "$path" ]] || return 0
  local args=(--force --sign "$IDENTITY" --timestamp=none)
  if [[ -n "$options" ]]; then
    args+=(--options "$options")
  fi
  if [[ -n "$identifier" ]]; then
    args+=(--identifier "$identifier")
  fi
  if [[ -n "$preserve_metadata" ]]; then
    args+=(--preserve-metadata="$preserve_metadata")
  fi
  /usr/bin/codesign "${args[@]}" "$path"
}

assert_peer_signature() {
  local path="$1"
  local expected_identifier="$2"
  local signature

  [[ -e "$path" ]] || return 0
  signature="$(/usr/bin/codesign -d -vvv "$path" 2>&1)"
  if ! grep -q "Identifier=$expected_identifier" <<<"$signature"; then
    echo "ERROR: $path is signed with the wrong identifier; expected $expected_identifier." >&2
    printf '%s\n' "$signature" >&2
    exit 1
  fi
  if ! grep -q "flags=.*runtime" <<<"$signature" || ! grep -q "flags=.*library-validation" <<<"$signature"; then
    echo "ERROR: $path must be signed with hardened runtime and library validation for privileged socket policy." >&2
    printf '%s\n' "$signature" >&2
    exit 1
  fi
}

sign_path "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon" "runtime,library" "com.openburnbar.app"
sign_path "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI" "runtime,library" "com.openburnbar.cli"
sign_path \
  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarPrivilegedInputExecution" \
  "runtime,library" \
  "com.openburnbar.privileged-input-execution" \
  "entitlements"
sign_path \
  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarVirtualHIDBridge" \
  "runtime,library" \
  "com.openburnbar.virtual-hid-bridge" \
  "entitlements"
sign_path \
  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarPrivilegedInputKillSwitchWatchdog" \
  "runtime,library" \
  "com.openburnbar.privileged-input-killswitch-watchdog" \
  "entitlements"
sign_path "$APP_BUNDLE/Contents/Helpers/libOpenBurnBarCore.dylib"
sign_path "$APP_BUNDLE/Contents/Frameworks/OpenBurnBarCore.framework"

if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' item; do
    sign_path "$item"
  done < <(find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 \( -type d -name '*.framework' -o -type f -name '*.dylib' \) -print0 | sort -z)
fi

preserve_entitlements=false
if [[ "${OPENBURNBAR_PRESERVE_SIGNED_ENTITLEMENTS:-0}" == "1" ]]; then
  if codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q 'keychain-access-groups'; then
    preserve_entitlements=true
  else
    echo "WARN: $APP_BUNDLE has no keychain-access-groups entitlement; applying generated entitlements." >&2
  fi
fi

if [[ "$preserve_entitlements" == "true" ]]; then
	  /usr/bin/codesign \
	    --force \
	    --sign "$IDENTITY" \
	    --timestamp=none \
	    --generate-entitlement-der \
	    --options runtime,library \
	    --preserve-metadata=entitlements,requirements \
	    "$APP_BUNDLE"
else
	  /usr/bin/codesign \
	    --force \
	    --sign "$IDENTITY" \
	    --timestamp=none \
	    --options runtime,library \
	    --entitlements "$TEMP_ENTITLEMENTS" \
	    "$APP_BUNDLE"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
assert_peer_signature "$APP_BUNDLE" "com.openburnbar.app"
assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon" "com.openburnbar.app"
assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarCLI" "com.openburnbar.cli"
assert_peer_signature \
  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarPrivilegedInputExecution" \
  "com.openburnbar.privileged-input-execution"
assert_peer_signature "$APP_BUNDLE/Contents/Helpers/OpenBurnBarVirtualHIDBridge" "com.openburnbar.virtual-hid-bridge"
assert_peer_signature \
  "$APP_BUNDLE/Contents/Helpers/OpenBurnBarPrivilegedInputKillSwitchWatchdog" \
  "com.openburnbar.privileged-input-killswitch-watchdog"
bash scripts/ci/verify-daemon-release-signing.sh "$APP_BUNDLE" "$TEAM_ID"
echo "Signed $APP_BUNDLE with $IDENTITY (team $TEAM_ID, bundle $BUNDLE_ID)."
