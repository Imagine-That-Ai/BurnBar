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
    if full_entitlements == "keychain":
        entitlements["keychain-access-groups"] = [f"{team_id}.{bundle_id}"]
    with Path(destination).open("wb") as file:
        plistlib.dump(entitlements, file)
PY

sign_path() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  /usr/bin/codesign --force --sign "$IDENTITY" --timestamp=none "$path"
}

sign_path "$APP_BUNDLE/Contents/Helpers/OpenBurnBarDaemon"
sign_path "$APP_BUNDLE/Contents/Helpers/libOpenBurnBarCore.dylib"
sign_path "$APP_BUNDLE/Contents/Frameworks/OpenBurnBarCore.framework"

if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' framework; do
    sign_path "$framework"
  done < <(find "$APP_BUNDLE/Contents/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 | sort -z)
fi

if [[ "${OPENBURNBAR_PRESERVE_SIGNED_ENTITLEMENTS:-0}" == "1" ]]; then
  /usr/bin/codesign \
    --force \
    --sign "$IDENTITY" \
    --timestamp=none \
    --generate-entitlement-der \
    --preserve-metadata=entitlements,requirements,flags \
    "$APP_BUNDLE"
else
  /usr/bin/codesign \
    --force \
    --sign "$IDENTITY" \
    --timestamp=none \
    --options runtime \
    --entitlements "$TEMP_ENTITLEMENTS" \
    "$APP_BUNDLE"
fi

/usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
echo "Signed $APP_BUNDLE with $IDENTITY (team $TEAM_ID, bundle $BUNDLE_ID)."
