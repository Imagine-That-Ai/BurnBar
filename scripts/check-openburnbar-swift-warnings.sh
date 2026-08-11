#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$repo_root/scripts/lib/libsignal-swift-compat.sh"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$repo_root/scripts/lib/xcode-source-classification.sh"
openburnbar_configure_xcode_process_tmpdir

cleanup() {
  local original_status="${1:-0}"
  local google_restore_status=0
  local libsignal_restore_status=0
  openburnbar_restore_google_sign_in_macos_compat || google_restore_status=$?
  openburnbar_restore_libsignal_swift_compat || libsignal_restore_status=$?
  local restore_status="$google_restore_status"
  if ((restore_status == 0)); then
    restore_status="$libsignal_restore_status"
  fi
  if ((original_status == 0 && restore_status != 0)); then
    return "$restore_status"
  fi
  return "$original_status"
}
cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup "$original_status"
  exit $?
}
trap cleanup_on_exit EXIT

derived_data="${OPENBURNBAR_WARNING_DERIVED_DATA:-/tmp/openburnbar-warning-check-dd}"
log_file="${OPENBURNBAR_WARNING_LOG:-/tmp/openburnbar-warning-check.log}"
normalized_file="${OPENBURNBAR_WARNING_NORMALIZED_LOG:-/tmp/openburnbar-warning-check.normalized.log}"
cache_dir="${OPENBURNBAR_WARNING_PACKAGE_CACHE:-$repo_root/.spm-cache}"

schemes=(
  OpenBurnBar
  OpenBurnBarMobile
  OpenBurnBarWidget
  OpenBurnBarKeyboard
  OpenBurnBarDaemon
  OpenBurnBarDaemonExecutable
)

: >"$log_file"
mkdir -p "$cache_dir"
xcodebuild -resolvePackageDependencies \
  -project "$repo_root/OpenBurnBar.xcodeproj" \
  -scheme OpenBurnBar \
  -clonedSourcePackagesDirPath "$cache_dir" \
  -derivedDataPath "$derived_data"
openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
openburnbar_prepare_libsignal_swift_compat "$repo_root"

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
    -clonedSourcePackagesDirPath "$cache_dir" \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}" \
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
