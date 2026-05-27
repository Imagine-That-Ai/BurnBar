#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${OPENBURNBAR_WARNING_DERIVED_DATA:-/tmp/openburnbar-warning-check-dd}"
log_file="${OPENBURNBAR_WARNING_LOG:-/tmp/openburnbar-warning-check.log}"
normalized_file="${OPENBURNBAR_WARNING_NORMALIZED_LOG:-/tmp/openburnbar-warning-check.normalized.log}"

schemes=(
  OpenBurnBar
  OpenBurnBarMobile
  OpenBurnBarWidget
  OpenBurnBarKeyboard
  OpenBurnBarDaemon
  OpenBurnBarDaemonExecutable
)

: >"$log_file"

for scheme in "${schemes[@]}"; do
  case "$scheme" in
    OpenBurnBar|OpenBurnBarDaemon|OpenBurnBarDaemonExecutable)
      destination='platform=macOS,arch=arm64'
      ;;
    *)
      destination="${OPENBURNBAR_IOS_DESTINATION:-generic/platform=iOS Simulator}"
      ;;
  esac

  echo "==> Building $scheme" | tee -a "$log_file"
  xcodebuild build \
    -project "$repo_root/OpenBurnBar.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "$destination" \
    -derivedDataPath "$derived_data" \
    -quiet 2>&1 | tee -a "$log_file"
done

rg "warning:" "$log_file" \
  | rg -v "Run script build phase .* will be run during every build" \
  | sed -E "s#$repo_root/##; s#:[0-9]+:[0-9]+: warning:#: warning:#; s#@__swiftmacro_[^:]+:[0-9]+:[0-9]+: warning:#<swiftmacro>: warning:#" \
  | sort \
  | uniq -c \
  | sort -nr >"$normalized_file" || true

if rg -q "this is an error in the Swift 6 language mode|warning:" "$normalized_file"; then
  echo "Swift warning check failed. Normalized warnings:"
  sed -n '1,160p' "$normalized_file"
  exit 1
fi

echo "Swift warning check passed with no warnings."
