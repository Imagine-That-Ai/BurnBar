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
INPUT_ENTITLEMENTS="$(mktemp -t openburnbar-input-entitlements.XXXXXX.plist)"
FINAL_ENTITLEMENTS="$(mktemp -t openburnbar-final-entitlements.XXXXXX.plist)"
trap 'rm -f "$TEMP_ENTITLEMENTS" "$INPUT_ENTITLEMENTS" "$FINAL_ENTITLEMENTS"' EXIT

# Write the entitlements currently embedded in $1 to the plist file $2.
# Returns non-zero (leaving $2 empty) when the target carries none — an unsigned
# or ad-hoc bundle, for instance.
read_embedded_entitlements() {
  local path="$1"
  local destination="$2"
  : >"$destination"
  if ! /usr/bin/codesign -d --entitlements - --xml "$path" >"$destination" 2>/dev/null; then
    : >"$destination"
    return 1
  fi
  [[ -s "$destination" ]]
}

# The non-negotiable rule of this script: signing may add entitlements, never
# drop them. $1 is the plist read off the input binary, $2 the set about to be
# (or just) applied. Exits non-zero naming every key that would be lost — a
# warning is not enough, because a build that loses
# com.apple.developer.icloud-container-identifiers or
# com.apple.developer.applesignin still passes `codesign --verify --strict` and
# only fails at runtime, blaming the developer's Apple Developer configuration.
assert_no_entitlement_loss() {
  local before="$1"
  local after="$2"
  [[ -s "$before" ]] || return 0
  python3 - "$before" "$after" <<'PY'
import plistlib
import sys

before, after = sys.argv[1:3]


def read(path):
    """Raw bytes at `path`; empty when the file is absent or unreadable."""
    try:
        with open(path, "rb") as handle:
            return handle.read()
    except OSError:
        return b""


def input_keys(path):
    """Entitlement keys carried by the *input* binary.

    An absent or empty file is the documented "this bundle carries no readable
    signature" fallback, and legitimately means "nothing to lose". Any other
    parse failure is a hard error: swallowing it into an empty set would
    silently disable this gate at the exact moment it is load-bearing, which is
    the fail-open direction and unacceptable for a signing check.
    """
    raw = read(path)
    if not raw.strip():
        return set()
    try:
        loaded = plistlib.loads(raw)
    except Exception as error:  # noqa: BLE001 - any parse failure is fatal here
        raise SystemExit(
            f"ERROR: could not parse the entitlements read from the input binary "
            f"({path}): {type(error).__name__}: {error}. "
            "Refusing to sign with the entitlement-loss check disabled."
        )
    if not isinstance(loaded, dict):
        raise SystemExit(
            f"ERROR: entitlements read from the input binary ({path}) are a "
            f"{type(loaded).__name__}, not a plist dictionary. "
            "Refusing to sign with the entitlement-loss check disabled."
        )
    return set(loaded)


def result_keys(path):
    """Entitlement keys of the set about to be (or just) applied.

    Unparseable stays lenient here on purpose, because lenient *is* fail-closed
    on this side: an empty set makes every input key read as missing, so the
    comparison below rejects the signature.
    """
    try:
        loaded = plistlib.loads(read(path))
    except Exception:  # noqa: BLE001
        return set()
    return set(loaded) if isinstance(loaded, dict) else set()


# Deliberately a key-level comparison: it catches an entitlement disappearing,
# which is the failure that ships a silently broken build. Narrowing a value
# (one keychain group where there were two, say) is out of scope.
missing = sorted(input_keys(before) - result_keys(after))
if missing:
    raise SystemExit(
        "ERROR: signing would drop entitlements the input binary already carries: "
        + ", ".join(missing)
        + ". Refusing to reduce the app's entitlement set."
    )
PY
}

read_embedded_entitlements "$APP_BUNDLE" "$INPUT_ENTITLEMENTS" || true

python3 - "$ENTITLEMENTS_SOURCE" "$TEMP_ENTITLEMENTS" "$TEAM_ID" "$BUNDLE_ID" "${OPENBURNBAR_FULL_ENTITLEMENTS:-1}" <<'PY'
from pathlib import Path
import plistlib
import sys

source, destination, team_id, bundle_id, full_entitlements = sys.argv[1:6]
# Two modes, and an unrecognised one stops the build rather than quietly
# picking an entitlement set nobody asked for. The old "keychain" / "none"
# modes are retired: "keychain" had become a byte-for-byte synonym of "0", and
# no caller in this repo ever passed any of them.
#
# The default is the *full* source entitlements file. This set is only ever a
# fallback for a bundle that carries no readable signature of its own, and a
# reduced set there silently strips iCloud, Sign in with Apple and keychain
# access from a locally installed build.
RECOGNISED_MODES = {"1", "minimal"}
if full_entitlements not in RECOGNISED_MODES:
    raise SystemExit(
        f"ERROR: unrecognised OPENBURNBAR_FULL_ENTITLEMENTS={full_entitlements!r}; "
        f"expected one of {sorted(RECOGNISED_MODES)}."
    )
if full_entitlements == "1":
    text = Path(source).read_text()
    text = text.replace("$(AppIdentifierPrefix)", f"{team_id}.")
    text = text.replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
    Path(destination).write_text(text)
else:
    entitlements = {
        "com.apple.security.app-sandbox": False,
        "com.apple.security.files.user-selected.read-only": True,
        "keychain-access-groups": [f"{team_id}.{bundle_id}"],
    }
    with Path(destination).open("wb") as file:
        plistlib.dump(entitlements, file)
PY

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

# OPENBURNBAR_PRESERVE_SIGNED_ENTITLEMENTS=1 means "keep whatever Xcode stamped".
# It is honoured whenever the bundle actually carries entitlements, and what it
# preserves is that set *verbatim* (`--preserve-metadata=entitlements` re-embeds
# the original blob). It is emphatically NOT a request for a regenerated subset:
# the app's real set includes iCloud containers, iCloud services and Sign in
# with Apple, and no generated stand-in may quietly replace them.
preserve_entitlements=false
if [[ "${OPENBURNBAR_PRESERVE_SIGNED_ENTITLEMENTS:-0}" == "1" ]]; then
  if [[ -s "$INPUT_ENTITLEMENTS" ]]; then
    preserve_entitlements=true
    if ! grep -q 'keychain-access-groups' "$INPUT_ENTITLEMENTS"; then
      echo "WARN: $APP_BUNDLE was signed without keychain-access-groups; preserving it as-is." >&2
      echo "WARN: keychain-backed cloud sign-in will not work until Keychain Sharing is enabled on the provisioning profile." >&2
    fi
  else
    echo "WARN: $APP_BUNDLE carries no readable entitlements; applying generated entitlements." >&2
  fi
fi

# Fail closed *before* mutating the bundle: on the generated path the set we are
# about to stamp must still be a superset of what the input binary carries.
if [[ "$preserve_entitlements" != "true" ]]; then
  assert_no_entitlement_loss "$INPUT_ENTITLEMENTS" "$TEMP_ENTITLEMENTS"
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

# And prove it after the fact: whatever path ran above, the signed bundle must
# still carry every entitlement key the input bundle had.
read_embedded_entitlements "$APP_BUNDLE" "$FINAL_ENTITLEMENTS" || true
assert_no_entitlement_loss "$INPUT_ENTITLEMENTS" "$FINAL_ENTITLEMENTS"

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
