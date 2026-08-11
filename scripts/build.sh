#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/libsignal-swift-compat.sh
source "$ROOT_DIR/scripts/lib/libsignal-swift-compat.sh"
# shellcheck source=scripts/lib/xcode-source-classification.sh
source "$ROOT_DIR/scripts/lib/xcode-source-classification.sh"
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

PROJECT_PATH="$ROOT_DIR/OpenBurnBar.xcodeproj"
SCHEME="OpenBurnBar"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
CACHE_DIR="$ROOT_DIR/.spm-cache"
DERIVED_DATA_DIR="$ROOT_DIR/.derived-data/ci-build"
MODE="build"
DO_CLEAN=0

usage() {
  cat <<'EOF'
Usage: scripts/build.sh [options]

Options:
  --build                 Resolve + build (default)
  --test                  Resolve + test
  --resolve-only          Resolve package dependencies only
  --clean                 Run clean before build/test
  --scheme <name>         Xcode scheme (default: OpenBurnBar)
  --configuration <name>  Build configuration (default: Debug)
  --cache-dir <path>      SwiftPM cache dir (default: .spm-cache)
  --derived-data <path>   DerivedData dir (default: .derived-data)
  --destination <value>   xcodebuild destination (default: platform=macOS)
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      MODE="build"
      shift
      ;;
    --test)
      MODE="test"
      shift
      ;;
    --resolve-only)
      MODE="resolve"
      shift
      ;;
    --clean)
      DO_CLEAN=1
      shift
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    --cache-dir)
      CACHE_DIR="${2:-}"
      shift 2
      ;;
    --derived-data)
      DERIVED_DATA_DIR="${2:-}"
      shift 2
      ;;
    --destination)
      DESTINATION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SCHEME" || -z "$CONFIGURATION" || -z "$CACHE_DIR" || -z "$DERIVED_DATA_DIR" || -z "$DESTINATION" ]]; then
  echo "Invalid empty argument provided." >&2
  usage >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode command line tools first." >&2
  exit 1
fi

mkdir -p "$CACHE_DIR" "$DERIVED_DATA_DIR"

common_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -clonedSourcePackagesDirPath "$CACHE_DIR"
  -derivedDataPath "$DERIVED_DATA_DIR"
  -disableAutomaticPackageResolution
  "${OPENBURNBAR_XCODE_SOURCE_CLASSIFICATION_ARGS[@]}"
)

echo "Resolving packages with cache: $CACHE_DIR"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -clonedSourcePackagesDirPath "$CACHE_DIR" \
  -derivedDataPath "$DERIVED_DATA_DIR"

if [[ "$MODE" == "resolve" ]]; then
  echo "Package resolution complete."
  exit 0
fi

openburnbar_prepare_google_sign_in_macos_compat "$CACHE_DIR"
openburnbar_prepare_libsignal_swift_compat "$ROOT_DIR"

if [[ "$DO_CLEAN" -eq 1 ]]; then
  echo "Cleaning..."
  xcodebuild "${common_args[@]}" clean
fi

if [[ "$MODE" == "test" ]]; then
  echo "Running tests..."
  xcodebuild "${common_args[@]}" test
else
  echo "Building..."
  xcodebuild "${common_args[@]}" build
fi
