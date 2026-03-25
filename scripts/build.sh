#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/BurnBar.xcodeproj"
SCHEME="BurnBar"
CONFIGURATION="Debug"
DESTINATION="platform=macOS"
CACHE_DIR="$ROOT_DIR/.spm-cache"
DERIVED_DATA_DIR="$ROOT_DIR/.derived-data"
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
  --scheme <name>         Xcode scheme (default: BurnBar)
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

