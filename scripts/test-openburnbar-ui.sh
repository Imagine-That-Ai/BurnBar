#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

export FIREBASE_SOURCE_FIRESTORE="${FIREBASE_SOURCE_FIRESTORE:-1}"

usage() {
    cat <<'EOF'
Usage: scripts/test-openburnbar-ui.sh [--remote|--local] [options]

Modes:
  --remote   Build on this machine and execute on the Mac mini (default).
  --local    Run xcodebuild test for OpenBurnBarUITests on this machine.

Options:
  --dry-run                  Forwarded to remote mode.
  --ax-smoke <OpenBurnBar.app>
                             Forwarded to remote mode.
  -only-testing:<target>     XCUITest filter. May be repeated.
  -only-testing <target>     Same as above.
  -h, --help                 Show this help.

Environment:
  OPENBURNBAR_UI_TEST_FILTER=<target>
      Default -only-testing target.
  OPENBURNBAR_UI_ARTIFACT_DIR=<path>
      Artifact root override.
  OPENBURNBAR_UI_DERIVED_DATA_ROOT=<path>
      Derived data root override.
EOF
}

mode="remote"
forward_args=()
local_filters=()

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --remote)
            mode="remote"
            shift
            ;;
        --local)
            mode="local"
            shift
            ;;
        --dry-run|--ax-smoke|--products-dir|--timeout-seconds|--poll-timeout-seconds)
            option="$1"
            forward_args+=("$option")
            if [[ "$option" != "--dry-run" ]]; then
                shift
                [[ "$#" -gt 0 ]] || { echo "error: $option requires a value" >&2; exit 64; }
                forward_args+=("$1")
            fi
            shift
            ;;
        -only-testing:*)
            local_filters+=("${1#-only-testing:}")
            forward_args+=("$1")
            shift
            ;;
        -only-testing)
            shift
            [[ "$#" -gt 0 ]] || { echo "error: -only-testing requires a target" >&2; exit 64; }
            local_filters+=("$1")
            forward_args+=("-only-testing" "$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unsupported argument '$1'" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$mode" == "remote" ]]; then
    exec "$repo_root/scripts/macmini/run-remote-ui-tests.sh" "${forward_args[@]}"
fi

artifact_root="${OPENBURNBAR_UI_ARTIFACT_DIR:-$repo_root/.artifacts/openburnbar-ui-local}"
derived_data_root="${OPENBURNBAR_UI_DERIVED_DATA_ROOT:-${TMPDIR:-/tmp}/openburnbar-ui-tests-local}"
cache_dir="$repo_root/.spm-cache-new"
mkdir -p "$artifact_root" "$derived_data_root" "$cache_dir"

derived_data_dir="$(mktemp -d "$derived_data_root/openburnbar-ui-local.XXXXXX")"
trap 'rm -rf "$derived_data_dir"' EXIT
result_bundle="$artifact_root/OpenBurnBarUITests.xcresult"
rm -rf "$result_bundle"

filters=()
if ((${#local_filters[@]})); then
    filters=("${local_filters[@]}")
elif [[ -n "${OPENBURNBAR_UI_TEST_FILTER:-}" ]]; then
    filters=("$OPENBURNBAR_UI_TEST_FILTER")
fi

xcodebuild_args=(
    -project "$repo_root/OpenBurnBar.xcodeproj"
    -scheme "OpenBurnBarUITests"
    -destination "platform=macOS,arch=arm64"
    -clonedSourcePackagesDirPath "$cache_dir"
    -derivedDataPath "$derived_data_dir"
    -resultBundlePath "$result_bundle"
    SWIFT_ENABLE_EXPLICIT_MODULES=NO
    SWIFT_COMPILATION_MODE=singlefile
    SWIFT_ENABLE_BATCH_MODE=NO
)
if ((${#filters[@]})); then
    for filter in "${filters[@]}"; do
        xcodebuild_args+=("-only-testing:$filter")
    done
fi

xcodebuild test "${xcodebuild_args[@]}"
