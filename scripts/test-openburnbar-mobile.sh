#!/usr/bin/env bash
#
# test-openburnbar-mobile.sh — SOTA test driver for OpenBurnBarMobileTests.
#
# Local default: first connected physical iOS device (iPhone/iPad, USB,
# unlocked, trusted).
# CI (CI=true / GITHUB_ACTIONS=true): iOS Simulator — GitHub macOS runners have
# no USB-attached devices.
#
# Mirrors retry/telemetry patterns from test-openburnbar-app.sh.
#
# Environment knobs:
#   OPENBURNBAR_ENABLE_COVERAGE=YES      Capture xcresult at canonical mobile coverage path.
#   OPENBURNBAR_IOS_DESTINATION=...      Explicit xcodebuild destination (e.g. platform=iOS,id=<UDID>).
#   OPENBURNBAR_MOBILE_DRY_RUN=1         Print resolved destination and exit 0.
#   OPENBURNBAR_MOBILE_PREFLIGHT_ONLY=1   Validate physical-device readiness and
#                                        exit before package prep or XCTest.
#   OPENBURNBAR_MOBILE_TEST_ATTEMPTS=N   Override max attempts (default 4).
#   OPENBURNBAR_MOBILE_TEST_FILTER=...   Pass one or more custom -only-testing
#                                           targets. Separate multiple selectors
#                                           with commas or whitespace.
#   OPENBURNBAR_MOBILE_TEST_SCHEME=...   Override scheme (default: OpenBurnBarMobileUnitTests).
#                                           Use OpenBurnBarMobile for UI tests.
#   OPENBURNBAR_MOBILE_SIMULATOR=...     Simulator name for CI fallback (default: iPhone 17 Pro Max).
#   OPENBURNBAR_MOBILE_DISABLE_SIMULATOR_SIGNING=1
#                                           Force the CI-style unsigned simulator host locally.
#   OPENBURNBAR_MOBILE_SKIP_SIGNAL_FFI_PREP=1
#                                           Skip Signal FFI prep when the caller
#                                           already prepared the Signal FFI XCFramework artifacts.
#   OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS=<targets>
#                                           Explicit Signal FFI target override for this
#                                           mobile run. Defaults to iOS-only targets
#                                           (physical: aarch64-apple-ios; simulator:
#                                           aarch64-apple-ios-sim and x86_64-apple-ios).
#   SIGNAL_FFI_BUILD_TARGETS=<targets>      Preserve an explicit lower-level target
#                                           override when the mobile override is unset.
#   OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT=<absolute path>
#                                           Keep all transient mobile-test
#                                           roots below this caller-owned path.
#   OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT=<path>
#                                           Override cloned SwiftPM package cache.
#   OPENBURNBAR_MOBILE_TEST_ARTIFACT_ROOT=<path>
#                                           Override telemetry/coverage root.
#   OPENBURNBAR_MOBILE_TEST_DERIVED_DATA_ROOT=<path>
#                                           Override the derived-data parent.
#   OPENBURNBAR_MOBILE_CLEAN_STALE_DERIVED_DATA=1
#                                           Opt in to removing prior wrapper-generated
#                                           derived-data children from the scratch-rooted
#                                           derived-data parent before the run. The cleanup
#                                           is fail-closed: it requires
#                                           OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT, validates
#                                           current-user ownership and path containment, and
#                                           never follows symlinks. Default: keep all prior
#                                           children untouched.
#   OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_ROOT=<path>
#                                           Override Signal FFI staging root.
#   OPENBURNBAR_MOBILE_SIGNAL_FFI_CARGO_TARGET_ROOT=<path>
#                                           Override Signal FFI Cargo target root.
#   OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS=0|1
#                                           Override scratch-run Cargo target pruning
#                                           (default: 1 when scratch-rooted).
#   OPENBURNBAR_MOBILE_CLEANUP_SIGNAL_FFI_ROOT=0
#                                           Keep redirected Signal FFI
#                                           intermediates for post-run forensics
#                                           (default: clean when scratch-rooted).
#   OPENBURNBAR_MOBILE_PRUNE_UNUSED_SPM_ARTIFACTS=1
#                                           In an owned scratch root, remove
#                                           unused Sentry binary variants from
#                                           the SwiftPM cache before XCTest.
#                                           The mobile host links static Sentry;
#                                           this avoids a multi-gigabyte cache
#                                           expansion on physical-device runs.
#   OPENBURNBAR_MOBILE_ALLOW_PROVISIONING_UPDATES=0
#                                           Disable Xcode automatic profile/device updates on physical-device runs.
#
# Test-runner environment:
#   xcodebuild only forwards custom variables into XCTest runners when they use
#   the TEST_RUNNER_ prefix. This wrapper mirrors OpenBurnBar proof/test knobs
#   into that namespace automatically so physical-device tests can read the same
#   variables callers set in their shell.
#
# Exit status:
#   0  — tests passed (or dry-run succeeded)
#   N  — final xcodebuild exit code

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Firestore must build from source on iOS 27+; the prebuilt grpc-binary path
# faults at runtime and the mobile target has a build-phase tripwire for it.
export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

# shellcheck source=scripts/lib/openburnbar-app-test-classifier.sh
source "$repo_root/scripts/lib/openburnbar-app-test-classifier.sh"

dry_run_requested="${OPENBURNBAR_MOBILE_DRY_RUN:-}"
mobile_scratch_root=""

validate_path_within_root() {
    local root="$1"
    local candidate="$2"
    local label="$3"
    local resolve_symlinks="$4"
    python3 - "$root" "$candidate" "$label" "$resolve_symlinks" <<'PY'
import os
import sys

root, candidate, label, resolve_symlinks = sys.argv[1:]
root = os.path.abspath(root)
candidate = os.path.abspath(candidate)

def is_within(parent, child):
    try:
        return os.path.commonpath([parent, child]) == parent
    except ValueError:
        return False

if not is_within(root, candidate):
    print(f"ERROR: {label} must remain under OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT: {candidate}", file=sys.stderr)
    raise SystemExit(64)

if resolve_symlinks == "1":
    real_root = os.path.realpath(root)
    real_candidate = os.path.realpath(candidate)
    if not is_within(real_root, real_candidate):
        print(f"ERROR: {label} resolves outside OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT: {candidate}", file=sys.stderr)
        raise SystemExit(64)
PY
}

if [[ "${OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT+x}" == "x" ]]; then
    if [[ -z "${OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT}" ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT cannot be empty." >&2
        exit 64
    fi
    if [[ "${OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT}" != /* ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT must be an absolute path." >&2
        exit 64
    fi
    mobile_scratch_root="$(python3 - "${OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT}" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
    if [[ "$dry_run_requested" != "1" ]]; then
        mkdir -p "$mobile_scratch_root"
        mobile_scratch_root="$(python3 - "$mobile_scratch_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
    fi
fi

resolve_mobile_root() {
    local label="$1"
    local override_name="$2"
    local default_path="$3"
    local raw_path

    if [[ "${!override_name+x}" == "x" ]]; then
        raw_path="${!override_name}"
        if [[ -z "$raw_path" ]]; then
            echo "ERROR: ${override_name} cannot be empty." >&2
            return 64
        fi
    else
        raw_path="$default_path"
    fi

    if [[ -n "$mobile_scratch_root" ]]; then
        if [[ "$raw_path" != /* ]]; then
            echo "ERROR: ${label} must be absolute when OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT is set." >&2
            return 64
        fi
        local resolve_symlinks=1
        if [[ "$dry_run_requested" == "1" && ! -d "$mobile_scratch_root" ]]; then
            resolve_symlinks=0
        fi
        validate_path_within_root "$mobile_scratch_root" "$raw_path" "$label" "$resolve_symlinks" || return $?
        if [[ "$dry_run_requested" != "1" ]]; then
            mkdir -p "$raw_path"
            validate_path_within_root "$mobile_scratch_root" "$raw_path" "$label" 1 || return $?
            raw_path="$(python3 - "$raw_path" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
        fi
    fi

    printf '%s\n' "$raw_path"
}

cache_default="${mobile_scratch_root:+$mobile_scratch_root/swiftpm-cache}"
[[ -n "$cache_default" ]] || cache_default="$repo_root/.spm-cache-new"
cache_dir="$(resolve_mobile_root "SwiftPM cache" OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT "$cache_default")" || exit $?

# OpenBurnBarCore's package manifest resolves `../Vendor/libsignal` relative to
# its SwiftPM checkout. Isolated caches otherwise compile the deliberate
# unavailable Signal stub and hide real app integration failures.
if [[ -f "$repo_root/Vendor/libsignal/swift/Package.swift" ]]; then
    signal_vendor_cache="$cache_dir/checkouts/Vendor/libsignal"
    if [[ ! -f "$signal_vendor_cache/swift/Package.swift" ]]; then
        mkdir -p "$cache_dir/checkouts/Vendor"
        cp -R "$repo_root/Vendor/libsignal" "$signal_vendor_cache"
    fi
fi

artifact_default="${mobile_scratch_root:+$mobile_scratch_root/artifacts}"
[[ -n "$artifact_default" ]] || artifact_default="$repo_root/.derived-data"
artifact_root="$(resolve_mobile_root "mobile test artifact root" OPENBURNBAR_MOBILE_TEST_ARTIFACT_ROOT "$artifact_default")" || exit $?

derived_data_default="${mobile_scratch_root:+$mobile_scratch_root/derived-data}"
[[ -n "$derived_data_default" ]] || derived_data_default="${TMPDIR:-/tmp}/openburnbar-mobile-tests"
derived_data_root="$(resolve_mobile_root "derived-data root" OPENBURNBAR_MOBILE_TEST_DERIVED_DATA_ROOT "$derived_data_default")" || exit $?

# Accept the lower-level Signal FFI names when the caller invokes this wrapper
# directly. They are folded into the mobile-scoped names so scratch-root
# containment is applied before the prep script sees them.
if [[ "${OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_ROOT+x}" != "x" ]]; then
    if [[ "${SIGNAL_FFI_BUILD_ROOT+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_ROOT="$SIGNAL_FFI_BUILD_ROOT"
    elif [[ "${OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_ROOT="$OPENBURNBAR_SIGNAL_FFI_BUILD_ROOT"
    fi
fi
if [[ "${OPENBURNBAR_MOBILE_SIGNAL_FFI_CARGO_TARGET_ROOT+x}" != "x" ]]; then
    if [[ "${SIGNAL_FFI_CARGO_TARGET_ROOT+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_CARGO_TARGET_ROOT="$SIGNAL_FFI_CARGO_TARGET_ROOT"
    elif [[ "${OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_CARGO_TARGET_ROOT="$OPENBURNBAR_SIGNAL_FFI_CARGO_TARGET_ROOT"
    fi
fi
if [[ "${OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS+x}" != "x" ]]; then
    if [[ "${SIGNAL_FFI_BUILD_TARGETS+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS="$SIGNAL_FFI_BUILD_TARGETS"
    elif [[ "${OPENBURNBAR_SIGNAL_FFI_BUILD_TARGETS+x}" == "x" ]]; then
        OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS="$OPENBURNBAR_SIGNAL_FFI_BUILD_TARGETS"
    fi
fi

signal_ffi_build_default="${mobile_scratch_root:+$mobile_scratch_root/signal-ffi-build}"
signal_ffi_target_default="${mobile_scratch_root:+$mobile_scratch_root/signal-ffi-cargo-target}"
signal_ffi_build_root="$(resolve_mobile_root "Signal FFI build root" OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_ROOT "$signal_ffi_build_default")" || exit $?
signal_ffi_cargo_target_root="$(resolve_mobile_root "Signal FFI Cargo target root" OPENBURNBAR_MOBILE_SIGNAL_FFI_CARGO_TARGET_ROOT "$signal_ffi_target_default")" || exit $?
disable_automatic_package_resolution=0

attempt_log_path="$artifact_root/test-openburnbar-mobile-attempts.jsonl"

default_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_DEFAULT_ALLOWANCE:-900}"
maximum_test_execution_allowance="${OPENBURNBAR_MOBILE_TEST_MAX_ALLOWANCE:-1800}"
max_test_attempts="${OPENBURNBAR_MOBILE_TEST_ATTEMPTS:-4}"
test_filter="${OPENBURNBAR_MOBILE_TEST_FILTER:-OpenBurnBarMobileTests}"
test_scheme="${OPENBURNBAR_MOBILE_TEST_SCHEME:-OpenBurnBarMobileUnitTests}"
simulator_name="${OPENBURNBAR_MOBILE_SIMULATOR:-iPhone 17 Pro Max}"
ios_destination=""
test_filters=()

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_test_filters() {
    local raw="$1"
    local entry
    test_filters=()
    while IFS= read -r entry; do
        entry="$(trim_whitespace "$entry")"
        if [[ -z "$entry" ]]; then
            echo "ERROR: OPENBURNBAR_MOBILE_TEST_FILTER contains an empty filter entry." >&2
            exit 64
        fi
        test_filters+=("$entry")
    done < <(python3 - "$raw" <<'PY'
import re
import sys

for part in re.split(r"[\s,]+", sys.argv[1]):
    part = part.strip()
    if part:
        print(part)
PY
)
    if [[ "${#test_filters[@]}" -eq 0 ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_TEST_FILTER must include at least one filter." >&2
        exit 64
    fi
}

print_test_filters() {
    echo ">>> Mobile XCTest filter(s):"
    for entry in "${test_filters[@]}"; do
        echo "  - $entry"
    done
}

test_filters_include_bundle() {
    local bundle="$1"
    local selector
    for selector in "${test_filters[@]}"; do
        if [[ "$selector" == "$bundle" || "$selector" == "$bundle/"* ]]; then
            return 0
        fi
    done
    return 1
}

normalize_ios_destination() {
    local raw="$1"
    local component identifier mapped normalized
    local -a destination_components

    if [[ -z "$raw" ]]; then
        return 1
    fi

    # CoreDevice exposes a 36-character identifier, while xcodebuild requires
    # the hardware UDID. Resolve only physical iOS destinations; simulator and
    # generic destinations retain their existing behavior.
    resolve_ios_identifier() {
        local candidate="$1"
        if [[ -z "$candidate" ]]; then
            echo "ERROR: iOS destination id cannot be empty." >&2
            return 64
        fi
        if [[ "$candidate" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
            resolve_coredevice_identifier "$candidate"
            return $?
        fi
        printf '%s\n' "$candidate"
    }

    if [[ "$raw" == generic/* ]]; then
        echo "$raw"
        return 0
    fi
    if [[ "$raw" == platform=iOS || "$raw" == platform=iOS,* ]]; then
        IFS=',' read -r -a destination_components <<< "$raw"
        normalized=""
        for component in "${destination_components[@]}"; do
            if [[ "$component" == id=* ]]; then
                identifier="${component#id=}"
                mapped="$(resolve_ios_identifier "$identifier")" || return $?
                component="id=$mapped"
            fi
            if [[ -n "$normalized" ]]; then
                normalized+=",$component"
            else
                normalized="$component"
            fi
        done
        printf '%s\n' "$normalized"
        return 0
    fi
    if [[ "$raw" == id=* ]]; then
        identifier="${raw#id=}"
        mapped="$(resolve_ios_identifier "$identifier")" || return $?
        echo "platform=iOS,id=$mapped"
        return 0
    fi
    if [[ "$raw" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        mapped="$(resolve_ios_identifier "$raw")" || return $?
        echo "platform=iOS,id=$mapped"
        return 0
    fi
    if [[ "$raw" =~ ^[0-9A-Fa-f-]{25,40}$ ]]; then
        echo "platform=iOS,id=$raw"
        return 0
    fi
    if [[ "$raw" == name=* ]]; then
        echo "platform=iOS,$raw"
        return 0
    fi

    echo "$raw"
}

resolve_coredevice_identifier() {
    local coredevice_identifier="$1"
    local devicectl_output

    # devicectl's documented machine-readable interface writes JSON to a
    # caller-provided path. /dev/stdout keeps this lookup ephemeral and avoids
    # leaving device metadata or temporary files behind.
    devicectl_output="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null || true)"
    COREDEVICE_IDENTIFIER="$coredevice_identifier" DEVICETCL_OUTPUT="$devicectl_output" python3 - <<'PY'
import json
import os
import re
import sys

identifier = os.environ.get("COREDEVICE_IDENTIFIER", "").casefold()
raw = os.environ.get("DEVICETCL_OUTPUT", "")
start = raw.find("{")
if start < 0:
    print(
        f"ERROR: CoreDevice identifier {identifier} could not be resolved; "
        "xcrun devicectl returned no JSON device inventory.",
        file=sys.stderr,
    )
    raise SystemExit(64)

try:
    payload, _ = json.JSONDecoder().raw_decode(raw[start:])
except json.JSONDecodeError:
    print(
        f"ERROR: CoreDevice identifier {identifier} could not be resolved; "
        "xcrun devicectl returned invalid JSON.",
        file=sys.stderr,
    )
    raise SystemExit(64)

devices = payload.get("result", {}).get("devices", [])
hardware_matches = []
matches = []
for device in devices if isinstance(devices, list) else []:
    if not isinstance(device, dict):
        continue
    hardware = device.get("hardwareProperties")
    if not isinstance(hardware, dict):
        continue
    if str(hardware.get("platform", "")).casefold() != "ios":
        continue
    if str(hardware.get("reality", "")).casefold() != "physical":
        continue
    udid = hardware.get("udid")
    if not isinstance(udid, str) or not re.fullmatch(r"[0-9A-Fa-f-]{25,40}", udid):
        continue
    name = str(device.get("deviceProperties", {}).get("name") or "iOS device")
    if udid.casefold() == identifier:
        hardware_matches.append((udid, name))
        continue
    if str(device.get("identifier", "")).casefold() != identifier:
        continue
    matches.append((udid, name))

if len(hardware_matches) == 1:
    # A hardware UDID can be UUID-shaped too. Preserve it when CoreDevice's
    # inventory identifies it as hardware rather than treating it as a
    # CoreDevice identifier.
    print(hardware_matches[0][0])
    raise SystemExit(0)

if len(hardware_matches) > 1:
    print(
        f"ERROR: iOS hardware UDID {identifier} matched multiple devices; "
        "refusing an ambiguous destination.",
        file=sys.stderr,
    )
    raise SystemExit(64)

if len(matches) == 1:
    print(matches[0][0])
    raise SystemExit(0)

if not matches:
    print(
        f"ERROR: CoreDevice identifier {identifier} has no matching physical iOS hardware UDID. "
        "Confirm the device appears in `xcrun devicectl list devices` and is paired.",
        file=sys.stderr,
    )
    raise SystemExit(64)

print(
    f"ERROR: CoreDevice identifier {identifier} matched multiple physical iOS devices; "
    "refusing an ambiguous destination.",
    file=sys.stderr,
)
for udid, name in matches:
    print(f"  {name}: {udid}", file=sys.stderr)
raise SystemExit(64)
PY
}

discover_physical_ios_destination() {
    local selected unavailable_ios device_name udid

    selected="$(xcrun xcdevice list 2>/dev/null | python3 -c '
import json
import sys

try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []

candidates = []
for device in devices:
    if device.get("simulator"):
        continue
    if device.get("platform") != "com.apple.platform.iphoneos":
        continue
    if not device.get("available"):
        continue
    identifier = device.get("identifier") or ""
    name = device.get("name") or "iOS device"
    if not identifier:
        continue
    interface = device.get("interface") or ""
    # Prefer cabled hardware because physical XCTest over Wi-Fi is much flakier.
    candidates.append((0 if interface == "usb" else 1, name, identifier))

if candidates:
    _, name, identifier = sorted(candidates)[0]
    print(f"{name}\t{identifier}")
')"

    if [[ -z "$selected" ]]; then
        echo "ERROR: No connected physical iOS device found for OpenBurnBar mobile tests." >&2
        echo "" >&2
        echo "Connect an iPhone or iPad over USB, unlock it, tap Trust on the device, and ensure Developer Mode is on." >&2
        echo "Or set OPENBURNBAR_IOS_DESTINATION to an explicit UDID, e.g.:" >&2
        echo "  OPENBURNBAR_IOS_DESTINATION='platform=iOS,id=<UDID>' ./scripts/test-openburnbar-mobile.sh" >&2
        echo "" >&2
        unavailable_ios="$(xcrun xcdevice list 2>/dev/null | python3 -c '
import json
import sys

try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []

for device in devices:
    if device.get("simulator"):
        continue
    if device.get("platform") != "com.apple.platform.iphoneos":
        continue
    if device.get("available"):
        continue
    name = device.get("name") or "iOS device"
    identifier = device.get("identifier") or "unknown-udid"
    reason = ((device.get("error") or {}).get("description")) or "unavailable"
    print(f"  {name} ({identifier}): {reason}")
')"
        if [[ -n "$unavailable_ios" ]]; then
            echo "Unavailable iOS devices:" >&2
            echo "$unavailable_ios" >&2
        fi
        return 1
    fi

    IFS=$'\t' read -r device_name udid <<< "$selected"

    echo ">>> Using connected physical iOS device: $device_name ($udid)" >&2
    echo "platform=iOS,id=$udid"
}

resolve_ios_destination() {
    local resolved=""

    if [[ -n "${OPENBURNBAR_IOS_DESTINATION:-}" ]]; then
        if ! resolved="$(normalize_ios_destination "$OPENBURNBAR_IOS_DESTINATION")"; then
            echo "ERROR: OPENBURNBAR_IOS_DESTINATION could not be resolved to a valid iOS destination." >&2
            return 64
        fi
        echo ">>> Using OPENBURNBAR_IOS_DESTINATION: $resolved" >&2
        echo "$resolved"
        return 0
    fi

    if [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" ]]; then
        # GitHub-hosted macOS runners cannot attach USB physical devices.
        resolved="platform=iOS Simulator,name=${simulator_name}"
        echo ">>> CI environment: using iOS Simulator destination ($resolved)" >&2
        echo "$resolved"
        return 0
    fi

    discover_physical_ios_destination
}

physical_ios_device_status() {
    local destination="$1"
    local xcdevice_json

    xcdevice_json="$(xcrun xcdevice list 2>/dev/null || true)"
    XCDEVICE_JSON="$xcdevice_json" python3 -c '
import json
import os
import sys

destination = sys.argv[1]
raw = os.environ.get("XCDEVICE_JSON", "")
try:
    devices = json.loads(raw)
except Exception:
    devices = []

if not isinstance(devices, list):
    devices = []

parts = {}
for part in destination.split(","):
    if "=" in part:
        key, value = part.split("=", 1)
        parts[key.strip()] = value.strip()

physical = [
    device for device in devices
    if isinstance(device, dict)
    and not device.get("simulator")
    and device.get("platform") == "com.apple.platform.iphoneos"
]
identifier = parts.get("id")
name = parts.get("name")
if identifier:
    physical = [device for device in physical if device.get("identifier") == identifier]
elif name:
    physical = [device for device in physical if device.get("name") == name]

if not physical:
    print("missing\tiOS device\tunknown-udid\tNo matching physical iOS device was reported by Xcode.")
    raise SystemExit(0)

device = physical[0]
device_name = str(device.get("name") or "iOS device")
device_id = str(device.get("identifier") or identifier or "unknown-udid")
error = device.get("error")
if isinstance(error, dict):
    reason = str(error.get("description") or error.get("code") or "")
else:
    reason = str(error or "")
reason = " ".join(reason.split())
lower_reason = reason.lower()
if any(token in lower_reason for token in ("locked", "passcode", "unlock")):
    state = "locked"
elif any(token in lower_reason for token in ("developer mode", "developer-mode", "developermode")):
    state = "developer_mode"
elif not bool(device.get("available")):
    state = "unavailable"
else:
    state = "ready"
display_reason = reason or "available"
print(f"{state}\t{device_name}\t{device_id}\t{display_reason}")
' "$destination"
}

verify_physical_ios_device_ready() {
    local status_line state device_name udid reason
    status_line="$(physical_ios_device_status "$ios_destination")"
    IFS=$'\t' read -r state device_name udid reason <<< "$status_line"

    case "$state" in
        ready)
            echo ">>> Physical iOS device readiness verified: $device_name ($udid)"
            ;;
        locked)
            echo "ERROR: Physical iOS device is locked: $device_name ($udid)." >&2
            echo "Unlock the device before running XCTest; do not leave it at the passcode screen." >&2
            echo "If it remains unavailable after unlocking, enable Developer Mode in Settings > Privacy & Security > Developer Mode, tap Trust if prompted, and reconnect it." >&2
            echo "Xcode reported: ${reason:-device locked}." >&2
            return 65
            ;;
        developer_mode)
            echo "ERROR: Physical iOS device cannot run XCTest because Developer Mode is disabled: $device_name ($udid)." >&2
            echo "Enable Developer Mode in Settings > Privacy & Security > Developer Mode, tap Trust if prompted, unlock the device, and reconnect it." >&2
            echo "Xcode reported: ${reason:-Developer Mode is disabled}." >&2
            return 65
            ;;
        unavailable)
            echo "ERROR: Physical iOS device is unavailable: $device_name ($udid)." >&2
            echo "Reconnect it over USB, unlock it, tap Trust if prompted, and ensure Developer Mode is enabled in Settings > Privacy & Security > Developer Mode." >&2
            echo "Xcode reported: ${reason:-device unavailable}." >&2
            return 65
            ;;
        *)
            echo "ERROR: Xcode could not find the requested physical iOS device for XCTest." >&2
            echo "Connect the device over USB, unlock it, tap Trust if prompted, and ensure Developer Mode is enabled in Settings > Privacy & Security > Developer Mode." >&2
            echo "Requested destination: $ios_destination" >&2
            echo "Xcode reported: ${reason:-no matching device}." >&2
            return 65
            ;;
    esac
}

simulator_udid=""
simulator_destination="platform=iOS Simulator,name=${simulator_name}"

parse_test_filters "$test_filter"

resolve_simulator_udid() {
    simulator_udid="$(python3 - "$simulator_name" <<'PY'
import json, subprocess, sys
name = sys.argv[1]
proc = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    check=False,
    capture_output=True,
    text=True,
)
if proc.returncode != 0:
    raise SystemExit(0)
payload = json.loads(proc.stdout)
for runtime, devices in payload.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
PY
)"
    if [[ -n "$simulator_udid" ]]; then
        simulator_destination="platform=iOS Simulator,id=${simulator_udid}"
    fi
}

ios_destination="$(resolve_ios_destination)"
uses_ios_simulator=0
if [[ "$ios_destination" == *"Simulator"* ]]; then
    uses_ios_simulator=1
fi

if [[ "$uses_ios_simulator" -eq 1 && -z "${OPENBURNBAR_IOS_DESTINATION:-}" ]]; then
    resolve_simulator_udid
    ios_destination="$simulator_destination"
fi

if [[ "${OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS+x}" == "x" ]]; then
    signal_ffi_build_targets="$OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS"
    if [[ -z "$signal_ffi_build_targets" || "$signal_ffi_build_targets" =~ ^[[:space:]]*$ ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_SIGNAL_FFI_BUILD_TARGETS cannot be empty." >&2
        exit 64
    fi
elif [[ "$uses_ios_simulator" -eq 1 ]]; then
    # Keep both simulator slices so the generated iOS XCFramework works on
    # Apple Silicon and Intel simulator hosts.
    signal_ffi_build_targets="aarch64-apple-ios-sim x86_64-apple-ios"
else
    # A physical iPad/iPhone only needs the arm64 device slice. In particular,
    # never inherit the macOS darwin targets from the shared build helper.
    signal_ffi_build_targets="aarch64-apple-ios"
fi
echo ">>> Mobile Signal FFI build targets: $signal_ffi_build_targets"

if [[ "$uses_ios_simulator" -eq 0 && -z "${OPENBURNBAR_APP_CHECK_PROVIDER:-}" ]] \
    && [[ "${OPENBURNBAR_LIVE_HERMES_RELAY_E2E:-}" == "1" || "${OPENBURNBAR_LIVE_HERMES_GATEWAY_CLIENT_E2E:-}" == "1" || -n "${OPENBURNBAR_LIVE_HERMES_GATEWAY_APPROVAL_CODE:-}" ]]; then
    export OPENBURNBAR_APP_CHECK_PROVIDER=appattest
    echo ">>> Live Hermes proof: using App Attest App Check on the physical device."
fi

if [[ "$uses_ios_simulator" -eq 0 && "${OPENBURNBAR_MOBILE_ALLOW_PROVISIONING_UPDATES:-1}" != "0" ]]; then
    echo ">>> Physical iOS test: allowing Xcode automatic provisioning profile and device registration updates."
fi

if [[ "${OPENBURNBAR_MOBILE_DRY_RUN:-}" == "1" ]]; then
    echo ">>> Dry run: would test OpenBurnBarMobile at destination:"
    echo "$ios_destination"
    if [[ -n "$mobile_scratch_root" ]]; then
        echo ">>> Mobile scratch root: $mobile_scratch_root"
        echo ">>> SwiftPM cache root: $cache_dir"
        echo ">>> Mobile artifact root: $artifact_root"
        echo ">>> Derived-data root: $derived_data_root"
        echo ">>> Signal FFI build root: ${signal_ffi_build_root:-<unset>}"
        echo ">>> Signal FFI Cargo target root: ${signal_ffi_cargo_target_root:-<unset>}"
    fi
    print_test_filters
    exit 0
fi

print_test_filters

# Physical XCTest can terminate/relaunch the app on the attached device. Check
# the live device record immediately before any package preparation or stale
# process cleanup so a locked/passcode-screen device is never disturbed.
if [[ "$uses_ios_simulator" -eq 0 ]]; then
    verify_physical_ios_device_ready
fi

if [[ "${OPENBURNBAR_MOBILE_PREFLIGHT_ONLY:-}" == "1" ]]; then
    echo ">>> Mobile preflight passed; no package preparation or XCTest was started."
    exit 0
fi

print_test_filters

mkdir -p "$cache_dir"
mkdir -p "$artifact_root"
mkdir -p "$derived_data_root"

derived_data_dir=""
xcodebuild_log=""
xcodebuild_args=()
last_test_exit_code=0
test_selectors=()

validate_owned_directory() {
    local path="$1"
    local label="$2"
    python3 - "$path" "$label" <<'PY'
import os
import stat
import sys

path, label = sys.argv[1:]
try:
    info = os.lstat(path)
except OSError as exc:
    print(f"ERROR: {label} cannot be inspected: {exc}", file=sys.stderr)
    raise SystemExit(64)

if stat.S_ISLNK(info.st_mode):
    print(f"ERROR: {label} must not be a symlink: {path}", file=sys.stderr)
    raise SystemExit(64)
if not stat.S_ISDIR(info.st_mode):
    print(f"ERROR: {label} must be a directory: {path}", file=sys.stderr)
    raise SystemExit(64)
if info.st_uid != os.getuid():
    print(
        f"ERROR: {label} is not owned by the current user: {path}",
        file=sys.stderr,
    )
    raise SystemExit(64)
PY
}

cleanup_stale_derived_data() {
    [[ "${OPENBURNBAR_MOBILE_CLEAN_STALE_DERIVED_DATA:-0}" == "1" ]] || return 0

    if [[ -z "$mobile_scratch_root" ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_CLEAN_STALE_DERIVED_DATA=1 requires OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT." >&2
        return 64
    fi

    # Re-validate immediately before deletion. This protects against a
    # scratch-root or derived-data path being replaced after initial
    # resolution, and makes the ownership boundary explicit for cleanup.
    validate_owned_directory "$mobile_scratch_root" "Mobile test scratch root"
    validate_path_within_root "$mobile_scratch_root" "$derived_data_root" "Derived-data cleanup root" 1
    validate_owned_directory "$derived_data_root" "Derived-data cleanup root"

    local candidate basename
    # Leave nullglob disabled so an empty directory yields a literal pattern;
    # the existence guard below skips that sentinel without tripping nounset.
    local -a stale_candidates=("$derived_data_root"/openburnbar-mobile-tests.*)

    for candidate in "${stale_candidates[@]}"; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        basename="${candidate##*/}"
        # mktemp creates exactly six alphanumeric suffix characters. Requiring
        # that shape prevents this opt-in cleanup from deleting arbitrary
        # caller-owned directories that merely share a loose prefix.
        [[ "$basename" =~ ^openburnbar-mobile-tests\.[[:alnum:]]{6}$ ]] || continue

        if [[ -L "$candidate" ]]; then
            echo "ERROR: Prior mobile derived-data child must not be a symlink: $candidate" >&2
            return 64
        fi
        validate_path_within_root "$derived_data_root" "$candidate" "Prior mobile derived-data child" 1
        validate_owned_directory "$candidate" "Prior mobile derived-data child"
        rm -rf "$candidate"
        echo ">>> Removed prior mobile derived-data child: $candidate"
    done
}

cleanup_stale_derived_data
derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"

emit_attempt_event() {
    local attempt="$1"
    local exit_code="$2"
    local outcome="$3"
    local duration="$4"
    local xcresult_path="$5"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$attempt" "$exit_code" "$outcome" "$duration" "$xcresult_path" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

attempt, exit_code, outcome, duration, xcresult_path, timestamp, dest = sys.argv[1:]
record = {
    "kind": "attempt",
    "timestamp": timestamp,
    "attempt": int(attempt),
    "exitCode": int(exit_code),
    "outcome": outcome,
    "durationSeconds": int(duration),
    "xcresultPath": xcresult_path,
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

emit_summary_event() {
    local outcome="$1"
    local attempts="$2"
    local total_duration="$3"
    local final_exit="$4"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    python3 - "$outcome" "$attempts" "$total_duration" "$final_exit" "$timestamp" "$attempt_log_path" <<'PY'
import json
import sys

outcome, attempts, duration, final_exit, timestamp, dest = sys.argv[1:]
record = {
    "kind": "summary",
    "timestamp": timestamp,
    "outcome": outcome,
    "attempts": int(attempts),
    "totalDurationSeconds": int(duration),
    "finalExitCode": int(final_exit),
}
with open(dest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

cleanup_derived_data() {
    local dd="$1"
    rm -rf "$dd" 2>/dev/null || true
}

cleanup_signal_ffi_intermediates() {
    local cleanup_requested="${OPENBURNBAR_MOBILE_CLEANUP_SIGNAL_FFI_ROOT:-0}"
    if [[ -z "${OPENBURNBAR_MOBILE_CLEANUP_SIGNAL_FFI_ROOT+x}" && -n "$mobile_scratch_root" ]]; then
        cleanup_requested=1
    fi
    [[ "$cleanup_requested" == "1" ]] || return 0
    [[ -n "$mobile_scratch_root" ]] || return 0
    local root
    for root in "$signal_ffi_build_root" "$signal_ffi_cargo_target_root"; do
        [[ -n "$root" && "$root" != "$mobile_scratch_root" ]] || continue
        validate_path_within_root "$mobile_scratch_root" "$root" "Signal FFI cleanup root" 1 || continue
        rm -rf "$root" 2>/dev/null || true
    done
}

prune_unused_spm_artifacts() {
    [[ "${OPENBURNBAR_MOBILE_PRUNE_UNUSED_SPM_ARTIFACTS:-0}" == "1" ]] || return 0
    if [[ -z "$mobile_scratch_root" ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_PRUNE_UNUSED_SPM_ARTIFACTS=1 requires OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT." >&2
        return 64
    fi
    validate_path_within_root "$mobile_scratch_root" "$cache_dir" "SwiftPM artifact-prune cache" 1
    if [[ ! -f "$cache_dir/workspace-state.json" ]]; then
        echo ">>> SwiftPM cache has no workspace-state.json; retaining all artifacts for the initial package resolution."
        return 0
    fi
    "$repo_root/scripts/lib/prune-mobile-swiftpm-cache.sh" "$cache_dir"
    # The pruned cache is a resolved, reusable package graph. Prevent Xcode
    # from trying to refresh every package and repopulate unused binary
    # variants during the build.
    disable_automatic_package_resolution=1
}

cleanup() {
    if [ -n "$xcodebuild_log" ]; then
        rm -f "$xcodebuild_log" 2>/dev/null || true
    fi
    if [ -n "$derived_data_dir" ]; then
        cleanup_derived_data "$derived_data_dir"
    fi
    cleanup_signal_ffi_intermediates
}

ensure_simulator_booted() {
    if [[ -z "$simulator_udid" ]]; then
        return 0
    fi
    local state
    state="$(xcrun simctl list devices booted -j | python3 -c '
import json, sys
target = sys.argv[1]
payload = json.loads(sys.stdin.read() or "{}")
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("udid") == target:
            print(device.get("state", ""))
            raise SystemExit(0)
print("")
' "$simulator_udid")"
    if [[ "$state" != "Booted" ]]; then
        echo ">>> Booting iOS Simulator ${simulator_name} (${simulator_udid})."
        xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$simulator_udid" -b >/dev/null 2>&1 || sleep 3
    fi
}

preclean_stale_mobile_processes() {
    local patterns=(
        "OpenBurnBarMobile.app/Contents/MacOS/OpenBurnBarMobile"
        "OpenBurnBarMobileTests.xctest"
        "xctest .*OpenBurnBarMobileTests"
        "OpenBurnBarMobileUITests.xctest"
    )
    for pattern in "${patterns[@]}"; do
        pkill -f "$pattern" >/dev/null 2>&1 || true
    done
    if [[ -n "$simulator_udid" ]]; then
        xcrun simctl terminate "$simulator_udid" com.openburnbar.app >/dev/null 2>&1 || true
    fi
    sleep 0.2
}

trap 'cleanup' EXIT

populate_xcodebuild_args() {
    local dd="$1"
    local attempt_result="$2"
    local selector
    xcodebuild_args=(
        -project "$repo_root/OpenBurnBar.xcodeproj"
        -scheme "$test_scheme"
        -destination "$ios_destination"
        -clonedSourcePackagesDirPath "$cache_dir"
        -derivedDataPath "$dd"
        -resultBundlePath "$attempt_result"
        -test-timeouts-enabled YES
        -default-test-execution-time-allowance "$default_test_execution_allowance"
        -maximum-test-execution-time-allowance "$maximum_test_execution_allowance"
        SWIFT_ENABLE_EXPLICIT_MODULES=NO
        SWIFT_COMPILATION_MODE=singlefile
        SWIFT_ENABLE_BATCH_MODE=NO
        -parallel-testing-enabled NO
    )
    if [[ "$disable_automatic_package_resolution" -eq 1 ]]; then
        xcodebuild_args+=(-disableAutomaticPackageResolution)
    fi
    test_selectors=()
    for selector in "${test_filters[@]}"; do
        test_selectors+=("$selector")
        xcodebuild_args+=(-only-testing:"$selector")
    done
    if [[ "${#test_selectors[@]}" -eq 0 ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_TEST_FILTER resolved to zero -only-testing selectors." >&2
        return 64
    fi
    if [[ "$test_scheme" == "OpenBurnBarMobile" ]] \
        && ! test_filters_include_bundle "OpenBurnBarMobileUITests"; then
        xcodebuild_args+=(-skip-testing:OpenBurnBarMobileUITests)
    fi
    if [[ "$uses_ios_simulator" -eq 1 ]] \
        && [[ "${CI:-}" == "true" || "${GITHUB_ACTIONS:-}" == "true" || "${OPENBURNBAR_MOBILE_DISABLE_SIMULATOR_SIGNING:-}" == "1" ]]; then
        xcodebuild_args+=(
            CODE_SIGNING_ALLOWED=NO
            CODE_SIGNING_REQUIRED=NO
        )
    elif [[ "${OPENBURNBAR_MOBILE_ALLOW_PROVISIONING_UPDATES:-1}" != "0" ]]; then
        xcodebuild_args+=(
            -allowProvisioningUpdates
            -allowProvisioningDeviceRegistration
        )
    fi
    if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
        xcodebuild_args+=(-enableCodeCoverage YES)
    fi
}

if [[ "${CI:-}" == "true" ]]; then
    export TEST_RUNNER_CI=true
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    export TEST_RUNNER_GITHUB_ACTIONS=true
fi

forward_openburnbar_test_runner_environment() {
    local env_name runner_name forwarded_count
    forwarded_count=0

    while IFS= read -r env_name; do
        case "$env_name" in
            OPENBURNBAR_*|BURNBAR_SECOND_SIMULATOR|INSIGHTS_*) ;;
            *) continue ;;
        esac

        runner_name="TEST_RUNNER_${env_name}"
        if [[ -n "${!runner_name+x}" ]]; then
            continue
        fi

        export "${runner_name}=${!env_name}"
        forwarded_count=$((forwarded_count + 1))
    done < <(env | sed -nE 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p')

    if [[ "$forwarded_count" -gt 0 ]]; then
        echo ">>> Forwarded $forwarded_count OpenBurnBar test environment value(s) to XCTest runner."
    fi
}

forward_openburnbar_test_runner_environment

canonical_xcresult_path="$artifact_root/OpenBurnBarMobile_TestCoverage.xcresult"
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
    rm -rf "$canonical_xcresult_path"
fi

: > "$attempt_log_path"

if [[ "${OPENBURNBAR_MOBILE_SKIP_SIGNAL_FFI_PREP:-}" == "1" ]]; then
    if [[ ! -d "$repo_root/Vendor/OpenBurnBarSignalFfiIOS.xcframework" && ! -d "$repo_root/Vendor/OpenBurnBarSignalFfi.xcframework" ]]; then
        echo "ERROR: OPENBURNBAR_MOBILE_SKIP_SIGNAL_FFI_PREP=1 but no iOS Signal FFI XCFramework artifact is present." >&2
        exit 66
    fi
    echo ">>> Reusing prebuilt Signal FFI XCFramework."
else
    signal_ffi_prepare_environment=()
    signal_ffi_prepare_environment+=("SIGNAL_FFI_BUILD_TARGETS=$signal_ffi_build_targets")
    if [[ -n "$mobile_scratch_root" &&
        "${SIGNAL_FFI_PRUNE_CARGO_TARGETS+x}" != "x" &&
        "${OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS+x}" != "x" ]]; then
        # Scratch-rooted mobile builds may compile several large Rust targets.
        # The builder stages each requested slice before pruning its Cargo
        # target directory, keeping physical-device runs within the caller's
        # disk budget without changing the default desktop build behavior.
        signal_ffi_prepare_environment+=("OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS=1")
    fi
    if [[ -n "$signal_ffi_build_root" ]]; then
        signal_ffi_prepare_environment+=("SIGNAL_FFI_BUILD_ROOT=$signal_ffi_build_root")
    fi
    if [[ -n "$signal_ffi_cargo_target_root" ]]; then
        signal_ffi_prepare_environment+=("SIGNAL_FFI_CARGO_TARGET_ROOT=$signal_ffi_cargo_target_root")
    fi
    if [[ "${#signal_ffi_prepare_environment[@]}" -gt 0 ]]; then
        env "${signal_ffi_prepare_environment[@]}" "$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh"
    else
        "$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh"
    fi
fi

prune_unused_spm_artifacts

openburnbar_app_test_hang_substrings+=(
    "test runner hung before establishing connection"
    "Test runner never began executing tests"
    "Test session timed out"
    "Failed to launch test runner"
    "failed to launch"
    "Lost connection to the test runner"
    "Could not attach to pid"
    "TestRunner crashed"
    "Early unexpected exit, operation never finished bootstrapping"
    "operation never finished bootstrapping"
)

is_zero_test_pass() {
    local log_path="$1"

    grep -Fq "Test Suite 'Selected tests' passed" "$log_path" || return 1
    grep -Eq "Executed 0 tests, with ([0-9]+ tests skipped and )?0 failures" "$log_path"
}

backoff_seconds=(0 5 10 20 40)

test_attempt=1
final_exit_code=0
final_outcome="failed"
final_xcresult=""

while [ "$test_attempt" -le "$max_test_attempts" ]; do
    if [ "$test_attempt" -gt 1 ]; then
        local_idx=$((test_attempt - 1))
        if [ "$local_idx" -ge "${#backoff_seconds[@]}" ]; then
            local_idx=$((${#backoff_seconds[@]} - 1))
        fi
        wait_for=${backoff_seconds[$local_idx]}
        echo ">>> Mobile retry attempt $test_attempt of $max_test_attempts after retryable XCTest/SwiftPM infrastructure failure. Sleeping ${wait_for}s."
        sleep "$wait_for"
        if (( test_attempt % 2 == 1 )); then
            cleanup_derived_data "$derived_data_dir"
            derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-mobile-tests.XXXXXX")"
        fi
    fi

    attempt_xcresult="$derived_data_dir/OpenBurnBarMobileTests-attempt-$test_attempt.xcresult"
    xcodebuild_log="$(mktemp "$derived_data_root/openburnbar-mobile-tests-log-XXXXXX")"

    preclean_stale_mobile_processes
    if [[ "$uses_ios_simulator" -eq 1 ]]; then
        ensure_simulator_booted
    fi

    populate_xcodebuild_args "$derived_data_dir" "$attempt_xcresult"
    echo ">>> Mobile test selectors (${#test_selectors[@]}): ${test_selectors[*]}"

    attempt_start_epoch="$(date +%s)"
    set +e
    xcodebuild test "${xcodebuild_args[@]}" 2>&1 | tee "$xcodebuild_log"
    last_test_exit_code=${PIPESTATUS[0]}
    set -e
    attempt_end_epoch="$(date +%s)"
    attempt_duration=$((attempt_end_epoch - attempt_start_epoch))

    if openburnbar_app_test_has_terminal_concrete_xctest_failure "$xcodebuild_log"; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "test_failure" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Detected concrete XCTest failure in xcodebuild log; failing mobile attempt even though xcodebuild exited $last_test_exit_code."
        final_exit_code="$last_test_exit_code"
        if [ "$final_exit_code" -eq 0 ]; then
            final_exit_code=65
        fi
        final_outcome="test_failure"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if [ "$last_test_exit_code" -eq 0 ]; then
        if is_zero_test_pass "$xcodebuild_log"; then
            emit_attempt_event "$test_attempt" 65 "zero_tests_failed" "$attempt_duration" "$attempt_xcresult"
            echo "ERROR: XCTest reported Selected tests passed but executed 0 tests for OPENBURNBAR_MOBILE_TEST_FILTER." >&2
            print_test_filters >&2
            echo "ERROR: Regenerate the Xcode project or fix OPENBURNBAR_MOBILE_TEST_FILTER before accepting this run." >&2
            final_exit_code=65
            final_outcome="failed"
            final_xcresult="$attempt_xcresult"
            break
        fi
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "passed" "$attempt_duration" "$attempt_xcresult"
        final_exit_code=0
        final_outcome="passed"
        final_xcresult="$attempt_xcresult"
        break
    fi

    if is_known_hang "$xcodebuild_log" && [ "$test_attempt" -lt "$max_test_attempts" ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "hang_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Known XCTest hang detected on mobile attempt $test_attempt; retrying."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    if is_swiftpm_dependency_resolution_transient "$xcodebuild_log" && [ "$test_attempt" -lt "$max_test_attempts" ]; then
        emit_attempt_event "$test_attempt" "$last_test_exit_code" "swiftpm_dependency_retry" "$attempt_duration" "$attempt_xcresult"
        echo ">>> Transient SwiftPM dependency resolution failure detected on mobile attempt $test_attempt; retrying."
        test_attempt=$((test_attempt + 1))
        continue
    fi

    emit_attempt_event "$test_attempt" "$last_test_exit_code" "failed" "$attempt_duration" "$attempt_xcresult"
    final_exit_code="$last_test_exit_code"
    final_outcome="failed"
    final_xcresult="$attempt_xcresult"
    break
done

if [[ -n "$final_xcresult" && "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" && "$final_outcome" == "passed" ]]; then
    rm -rf "$canonical_xcresult_path"
    cp -R "$final_xcresult" "$canonical_xcresult_path"
fi

invocation_end_epoch="$(date +%s)"
total_duration=$((invocation_end_epoch - $(date -r "$attempt_log_path" +%s 2>/dev/null || echo "$invocation_end_epoch")))
emit_summary_event "$final_outcome" "$test_attempt" "$total_duration" "$final_exit_code"

echo ">>> Mobile test summary: outcome=$final_outcome attempts=$test_attempt exit=$final_exit_code"
echo ">>> Telemetry: $attempt_log_path"

exit "$final_exit_code"
