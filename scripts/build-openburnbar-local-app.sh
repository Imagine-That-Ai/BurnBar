#!/usr/bin/env bash

# Canonical local Xcode app build used by `make build` and `make build-signed`.
# It binds the build to Package.resolved, skips the Xcode resolver when the
# cloned-source cache is already complete, applies the Xcode 27 package
# compatibility lifecycle, and restores every temporary package edit on exit.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$repo_root/scripts/lib/libsignal-swift-compat.sh"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$repo_root/scripts/lib/xcode-source-classification.sh"

project="$repo_root/OpenBurnBar.xcodeproj"
scheme="OpenBurnBar"
configuration="Release"
destination="platform=macOS,arch=arm64"
cache_dir="$repo_root/.spm-cache"
derived_data_dir="$repo_root/.derived-data"
signing_mode="unsigned"
development_team=""

usage() {
  cat <<'EOF'
Usage: scripts/build-openburnbar-local-app.sh [options]

Options:
  --signed                Use Apple Development signing when an identity exists
  --unsigned              Disable code signing (default)
  --development-team ID  Apple team override for --signed
  --configuration NAME   Xcode configuration (default: Release)
  --destination VALUE    xcodebuild destination
  --cache-dir PATH        Cloned-source SwiftPM cache
  --derived-data PATH     Xcode DerivedData root
  --project PATH          Xcode project
  --scheme NAME           Xcode scheme
  -h, --help              Show this help
EOF
}

while (($# > 0)); do
  case "$1" in
    --signed)
      signing_mode="signed"
      shift
      ;;
    --unsigned)
      signing_mode="unsigned"
      shift
      ;;
    --development-team)
      development_team="${2:-}"
      shift 2
      ;;
    --configuration)
      configuration="${2:-}"
      shift 2
      ;;
    --destination)
      destination="${2:-}"
      shift 2
      ;;
    --cache-dir)
      cache_dir="${2:-}"
      shift 2
      ;;
    --derived-data)
      derived_data_dir="${2:-}"
      shift 2
      ;;
    --project)
      project="${2:-}"
      shift 2
      ;;
    --scheme)
      scheme="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

for required_value in \
  "$project" \
  "$scheme" \
  "$configuration" \
  "$destination" \
  "$cache_dir" \
  "$derived_data_dir"; do
  if [[ -z "$required_value" ]]; then
    echo "Build arguments must not be empty." >&2
    exit 64
  fi
done

if [[ "$project" != /* ]]; then
  project="$repo_root/$project"
fi
if [[ "$cache_dir" != /* ]]; then
  cache_dir="$repo_root/$cache_dir"
fi
if [[ "$derived_data_dir" != /* ]]; then
  derived_data_dir="$repo_root/$derived_data_dir"
fi

openburnbar_configure_xcode_process_tmpdir
export FIREBASE_SOURCE_FIRESTORE=1

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

mkdir -p "$cache_dir" "$derived_data_dir"
bash "$repo_root/scripts/prepare-openburnbar-app-swiftpm.sh" \
  --project "$project" \
  --scheme "$scheme" \
  --cache-dir "$cache_dir" \
  --derived-data "$derived_data_dir"

openburnbar_prepare_google_sign_in_macos_compat "$cache_dir"
openburnbar_prepare_libsignal_swift_compat "$repo_root"

common_args=(
  -project "$project"
  -scheme "$scheme"
  -configuration "$configuration"
  -destination "$destination"
  -clonedSourcePackagesDirPath "$cache_dir"
  -derivedDataPath "$derived_data_dir"
  -disableAutomaticPackageResolution
  -onlyUsePackageVersionsFromResolvedFile
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}"
)

if [[ "$signing_mode" == "signed" && -z "$development_team" ]]; then
  identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1 \
      || true
  )"
  if [[ -n "$identity" ]]; then
    development_team="$(
      security find-certificate -c "$identity" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' \
        | head -n 1 \
        || true
    )"
  fi
fi

if [[ "$signing_mode" == "signed" && -n "$development_team" ]]; then
  echo "Building $scheme with Apple Development team $development_team."
  xcodebuild build \
    "${common_args[@]}" \
    DEVELOPMENT_TEAM="$development_team" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates
else
  if [[ "$signing_mode" == "signed" ]]; then
    echo "No Apple Development identity was found; building unsigned for later ad-hoc signing."
  else
    echo "Building $scheme with Xcode code signing disabled."
  fi
  xcodebuild build \
    "${common_args[@]}" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
fi
