#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mobile-runner-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

destination="platform=iOS,id=00008132-001158191E9A401C"
filter="OpenBurnBarMobileTests/OpenBurnBarMobileTests/testSealedApprovalDecisionCarriesKindAndActionAtRootOfSealedPayload"

scratch="$tmp_root/scratch"
scratch="$(python3 - "$scratch" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
dry_output="$tmp_root/dry-run.out"
OPENBURNBAR_IOS_DESTINATION="$destination" \
OPENBURNBAR_MOBILE_DRY_RUN=1 \
OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$dry_output"

grep -q "platform=iOS,id=00008132-001158191E9A401C" "$dry_output" ||
  fail "dry run did not print the resolved physical-device destination"
grep -q "SwiftPM cache root: $scratch/swiftpm-cache" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted SwiftPM cache"
grep -q "Signal FFI build root: $scratch/signal-ffi-build" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted Signal FFI build root"
grep -q "Signal FFI Cargo target root: $scratch/signal-ffi-cargo-target" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted Cargo target root"
[[ ! -e "$scratch" ]] || fail "dry run created scratch directories"

outside_output="$tmp_root/outside.out"
if OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
  OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT="$tmp_root/outside-cache" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$outside_output" 2>&1; then
  fail "outside SwiftPM cache path unexpectedly passed containment validation"
fi
grep -q "SwiftPM cache must remain under OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT" "$outside_output" ||
  fail "outside SwiftPM cache error did not identify the containment rule"

mkdir -p "$scratch" "$tmp_root/outside-target"
ln -s "$tmp_root/outside-target" "$scratch/escape-cache"
symlink_output="$tmp_root/symlink.out"
if OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
  OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT="$scratch/escape-cache" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$symlink_output" 2>&1; then
  fail "symlink-escaped SwiftPM cache path unexpectedly passed validation"
fi
grep -q "SwiftPM cache resolves outside OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT" "$symlink_output" ||
  fail "symlink escape error did not identify the containment rule"

fake_bin="$tmp_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "xcdevice" && "${2:-}" == "list" ]]; then
  cat "$FAKE_XCDEVICE_JSON"
  exit 0
fi

if [[ "${1:-}" == "devicectl" && "${2:-}" == "list" && "${3:-}" == "devices" ]]; then
  cat "${FAKE_COREDEVICE_JSON:?FAKE_COREDEVICE_JSON is required for devicectl tests}"
  exit 0
fi

if [[ "${1:-}" == "simctl" && "${2:-}" == "list" ]]; then
  printf '%s\n' '{"devices":{}}'
  exit 0
fi

printf 'unexpected fake xcrun invocation: %s\n' "$*" >&2
exit 64
SH
chmod +x "$fake_bin/xcrun"

cat >"$fake_bin/pkill" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_PRECLEAN_MARKER"
exit 0
SH
chmod +x "$fake_bin/pkill"

locked_json="$tmp_root/locked.json"
printf '%s\n' '[{"simulator":false,"platform":"com.apple.platform.iphoneos","available":false,"identifier":"00008132-001158191E9A401C","name":"Alberto iPad","error":{"description":"Device is locked."}}]' > "$locked_json"
locked_output="$tmp_root/locked.out"
locked_marker="$tmp_root/locked-preclean.marker"
if PATH="$fake_bin:$PATH" \
  FAKE_XCDEVICE_JSON="$locked_json" \
  FAKE_PRECLEAN_MARKER="$locked_marker" \
  OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_PREFLIGHT_ONLY=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$locked_output" 2>&1; then
  fail "locked physical device unexpectedly passed preflight"
fi
grep -qi "physical iOS device is locked" "$locked_output" ||
  fail "locked-device refusal did not identify the locked device"
grep -qi "unlock the device" "$locked_output" ||
  fail "locked-device refusal did not tell the user to unlock the device"
grep -q "Developer Mode" "$locked_output" ||
  fail "locked-device refusal did not include the Developer Mode recovery path"
[[ ! -e "$locked_marker" ]] || fail "stale-process cleanup ran before locked-device refusal"

developer_mode_json="$tmp_root/developer-mode.json"
printf '%s\n' '[{"simulator":false,"platform":"com.apple.platform.iphoneos","available":true,"identifier":"00008132-001158191E9A401C","name":"Alberto iPad","error":{"description":"Developer Mode is disabled."}}]' > "$developer_mode_json"
developer_mode_output="$tmp_root/developer-mode.out"
developer_mode_marker="$tmp_root/developer-mode-preclean.marker"
if PATH="$fake_bin:$PATH" \
  FAKE_XCDEVICE_JSON="$developer_mode_json" \
  FAKE_PRECLEAN_MARKER="$developer_mode_marker" \
  OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_PREFLIGHT_ONLY=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$developer_mode_output" 2>&1; then
  fail "Developer Mode-disabled device unexpectedly passed preflight"
fi
grep -qi "Developer Mode is disabled" "$developer_mode_output" ||
  fail "Developer Mode refusal did not identify the disabled state"
grep -qi "Settings > Privacy & Security > Developer Mode" "$developer_mode_output" ||
  fail "Developer Mode refusal did not include the settings path"
[[ ! -e "$developer_mode_marker" ]] || fail "stale-process cleanup ran before Developer Mode refusal"

unavailable_json="$tmp_root/unavailable.json"
printf '%s\n' '[{"simulator":false,"platform":"com.apple.platform.iphoneos","available":false,"identifier":"00008132-001158191E9A401C","name":"Alberto iPad","error":{"description":"The device is not paired with this Mac."}}]' > "$unavailable_json"
unavailable_output="$tmp_root/unavailable.out"
unavailable_marker="$tmp_root/unavailable-preclean.marker"
if PATH="$fake_bin:$PATH" \
  FAKE_XCDEVICE_JSON="$unavailable_json" \
  FAKE_PRECLEAN_MARKER="$unavailable_marker" \
  OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_PREFLIGHT_ONLY=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$unavailable_output" 2>&1; then
  fail "unavailable physical device unexpectedly passed preflight"
fi
grep -qi "physical iOS device is unavailable" "$unavailable_output" ||
  fail "unavailable-device refusal did not identify the unavailable device"
grep -qi "Reconnect it over USB" "$unavailable_output" ||
  fail "unavailable-device refusal did not provide reconnect guidance"
grep -q "Developer Mode" "$unavailable_output" ||
  fail "unavailable-device refusal did not include the Developer Mode recovery path"
[[ ! -e "$unavailable_marker" ]] || fail "stale-process cleanup ran before unavailable-device refusal"

simulator_output="$tmp_root/simulator.out"
if ! PATH="$fake_bin:$PATH" \
  CI=true \
  FAKE_XCDEVICE_JSON="$locked_json" \
  FAKE_PRECLEAN_MARKER="$tmp_root/simulator-preclean.marker" \
  OPENBURNBAR_MOBILE_PREFLIGHT_ONLY=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$simulator_output" 2>&1; then
  fail "simulator preflight unexpectedly failed"
fi
grep -q "CI environment: using iOS Simulator destination" "$simulator_output" ||
  fail "simulator path did not retain CI destination resolution"
grep -q "Mobile preflight passed" "$simulator_output" ||
  fail "simulator path did not complete the preflight-only exit"
if grep -qi "physical iOS device is locked" "$simulator_output"; then
  fail "simulator path incorrectly ran the physical-device lock guard"
fi
[[ ! -e "$tmp_root/simulator-preclean.marker" ]] || fail "preflight-only simulator path ran stale-process cleanup"

coredevice_id="407C0B12-010B-5970-8E85-D0E43DA8F457"
hardware_udid="00008132-001158191E9A401C"
uuid_shaped_hardware_udid="00000000-0000-0000-0000-000000000001"
coredevice_json="$tmp_root/coredevice.json"
cat >"$coredevice_json" <<JSON
devicectl table output is intentionally ignored by the JSON parser
{
  "result": {
    "devices": [
      {
        "identifier": "$coredevice_id",
        "deviceProperties": {"name": "Alberto's iPad"},
        "hardwareProperties": {
          "platform": "iOS",
          "reality": "physical",
          "udid": "$hardware_udid"
        }
      },
      {
        "identifier": "F0000000-0000-0000-0000-000000000001",
        "deviceProperties": {"name": "UUID-shaped iPad"},
        "hardwareProperties": {
          "platform": "iOS",
          "reality": "physical",
          "udid": "$uuid_shaped_hardware_udid"
        }
      }
    ]
  }
}
JSON

coredevice_output="$tmp_root/coredevice.out"
if ! PATH="$fake_bin:$PATH" \
  FAKE_COREDEVICE_JSON="$coredevice_json" \
  OPENBURNBAR_IOS_DESTINATION="$coredevice_id" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$coredevice_output" 2>&1; then
  fail "CoreDevice identifier unexpectedly failed destination resolution"
fi
grep -q "platform=iOS,id=$hardware_udid" "$coredevice_output" ||
  fail "raw CoreDevice identifier did not resolve to the hardware UDID"

coredevice_destination_output="$tmp_root/coredevice-destination.out"
if ! PATH="$fake_bin:$PATH" \
  FAKE_COREDEVICE_JSON="$coredevice_json" \
  OPENBURNBAR_IOS_DESTINATION="platform=iOS,id=$coredevice_id" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$coredevice_destination_output" 2>&1; then
  fail "platform=iOS CoreDevice destination unexpectedly failed resolution"
fi
grep -q "platform=iOS,id=$hardware_udid" "$coredevice_destination_output" ||
  fail "platform=iOS CoreDevice destination did not resolve to the hardware UDID"

hardware_uuid_output="$tmp_root/hardware-uuid.out"
if ! PATH="$fake_bin:$PATH" \
  FAKE_COREDEVICE_JSON="$coredevice_json" \
  OPENBURNBAR_IOS_DESTINATION="$uuid_shaped_hardware_udid" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$hardware_uuid_output" 2>&1; then
  fail "UUID-shaped hardware UDID unexpectedly failed destination resolution"
fi
grep -q "platform=iOS,id=$uuid_shaped_hardware_udid" "$hardware_uuid_output" ||
  fail "UUID-shaped hardware UDID was not preserved"

missing_coredevice_json="$tmp_root/missing-coredevice.json"
printf '%s\n' '{"result":{"devices":[]}}' >"$missing_coredevice_json"
missing_coredevice_output="$tmp_root/missing-coredevice.out"
if PATH="$fake_bin:$PATH" \
  FAKE_COREDEVICE_JSON="$missing_coredevice_json" \
  OPENBURNBAR_IOS_DESTINATION="$coredevice_id" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$missing_coredevice_output" 2>&1; then
  fail "missing CoreDevice mapping unexpectedly passed closed-world resolution"
fi
grep -qi "no matching physical iOS hardware UDID" "$missing_coredevice_output" ||
  fail "missing CoreDevice mapping did not fail closed with an actionable error"

ambiguous_coredevice_json="$tmp_root/ambiguous-coredevice.json"
cat >"$ambiguous_coredevice_json" <<JSON
{
  "result": {
    "devices": [
      {
        "identifier": "$coredevice_id",
        "deviceProperties": {"name": "First iPad"},
        "hardwareProperties": {"platform": "iOS", "reality": "physical", "udid": "$hardware_udid"}
      },
      {
        "identifier": "$coredevice_id",
        "deviceProperties": {"name": "Second iPad"},
        "hardwareProperties": {"platform": "iOS", "reality": "physical", "udid": "00008132-001158191E9A402D"}
      }
    ]
  }
}
JSON
ambiguous_coredevice_output="$tmp_root/ambiguous-coredevice.out"
if PATH="$fake_bin:$PATH" \
  FAKE_COREDEVICE_JSON="$ambiguous_coredevice_json" \
  OPENBURNBAR_IOS_DESTINATION="$coredevice_id" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$ambiguous_coredevice_output" 2>&1; then
  fail "ambiguous CoreDevice mapping unexpectedly passed closed-world resolution"
fi
grep -qi "matched multiple physical iOS devices" "$ambiguous_coredevice_output" ||
  fail "ambiguous CoreDevice mapping did not fail closed"

echo "test-openburnbar-mobile root boundary and physical-device preflight tests passed"

prune_cache="$tmp_root/prune-cache"
mkdir -p "$prune_cache/artifacts/sentry-cocoa/Sentry" \
  "$prune_cache/artifacts/sentry-cocoa/Sentry-Dynamic" \
  "$prune_cache/artifacts/sentry-cocoa/Sentry-Dynamic-WithARM64e" \
  "$prune_cache/artifacts/sentry-cocoa/Sentry-WithoutUIKitOrAppKit" \
  "$prune_cache/artifacts/sentry-cocoa/Sentry-WithoutUIKitOrAppKit-WithARM64e"
printf 'static\n' > "$prune_cache/artifacts/sentry-cocoa/Sentry/marker"
printf 'unused\n' > "$prune_cache/artifacts/sentry-cocoa/Sentry-Dynamic/marker"

prune_output="$tmp_root/prune.out"
"$repo_root/scripts/lib/prune-mobile-swiftpm-cache.sh" "$prune_cache" > "$prune_output"
[[ -d "$prune_cache/artifacts/sentry-cocoa/Sentry" ]] || fail "static Sentry artifact was pruned"
[[ -f "$prune_cache/artifacts/sentry-cocoa/Sentry/marker" ]] || fail "static Sentry artifact contents changed"
for unused in \
  Sentry-Dynamic \
  Sentry-Dynamic-WithARM64e \
  Sentry-WithoutUIKitOrAppKit \
  Sentry-WithoutUIKitOrAppKit-WithARM64e; do
  [[ ! -e "$prune_cache/artifacts/sentry-cocoa/$unused" ]] || fail "unused Sentry artifact was retained: $unused"
done
grep -q "Pruned 4 unused Sentry SwiftPM artifact variant(s)" "$prune_output" ||
  fail "cache-prune helper did not report the removed variants"

echo "test-openburnbar-mobile SwiftPM cache-prune test passed"
