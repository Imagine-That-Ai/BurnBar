#!/usr/bin/env bash
# clear-xcode-caches.sh
#
# Purpose
# -------
# Clear Xcode/SwiftPM/XCFramework caches that occasionally hold stale binary
# artifacts after large in-flight migrations. Symptoms include:
#
#   • "value of type 'X' has no member 'Y'" errors that disappear after a
#     fresh clone.
#   • XCFramework symbol mismatches between the OpenBurnBar Mac target and
#     OpenBurnBarMobile after the shared `OpenBurnBarCore` package gains
#     new public types or fields.
#   • SourceKit "ghost" errors that don't match the on-disk file content.
#
# This script is safe and idempotent — every directory it removes is
# recreated by Xcode on the next build.
#
# Usage
# -----
#   scripts/clear-xcode-caches.sh                # clear all caches
#   scripts/clear-xcode-caches.sh --derived-only # only DerivedData
#   scripts/clear-xcode-caches.sh --xcframeworks # only XCFramework cache
#   scripts/clear-xcode-caches.sh --packages     # only SwiftPM caches
#   scripts/clear-xcode-caches.sh --dry-run      # print actions, do not delete
#
# Exit codes
# ----------
#   0  success
#   1  unknown flag

set -euo pipefail

mode="all"
dry_run="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --derived-only)
            mode="derived"
            shift
            ;;
        --xcframeworks)
            mode="xcframeworks"
            shift
            ;;
        --packages)
            mode="packages"
            shift
            ;;
        --dry-run)
            dry_run="true"
            shift
            ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *)
            echo "error: unknown flag: $1" >&2
            exit 1
            ;;
    esac
done

# Derive predictable paths up-front so dry-run prints stable output.
DERIVED_DATA="${HOME}/Library/Developer/Xcode/DerivedData"
SPM_CACHES=(
    "${HOME}/Library/Caches/org.swift.swiftpm"
    "${HOME}/Library/org.swift.swiftpm"
)
XCFRAMEWORK_CACHES=(
    "${HOME}/Library/Caches/com.apple.dt.Xcode"
    "${HOME}/Library/Developer/Xcode/iOS DeviceSupport"
    "${HOME}/Library/Developer/Xcode/macOS DeviceSupport"
)

run() {
    if [[ "$dry_run" == "true" ]]; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

remove_path() {
    local path="$1"
    if [[ -e "$path" ]]; then
        run "rm -rf \"$path\""
        echo "  cleared: $path"
    else
        echo "  already clean: $path"
    fi
}

case "$mode" in
    derived|all)
        echo "▸ DerivedData"
        remove_path "$DERIVED_DATA"
        ;;
esac

case "$mode" in
    packages|all)
        echo "▸ SwiftPM caches"
        for path in "${SPM_CACHES[@]}"; do
            remove_path "$path"
        done
        ;;
esac

case "$mode" in
    xcframeworks|all)
        echo "▸ XCFramework / Xcode caches"
        for path in "${XCFRAMEWORK_CACHES[@]}"; do
            remove_path "$path"
        done
        ;;
esac

echo
if [[ "$dry_run" == "true" ]]; then
    echo "✓ dry run complete — nothing was deleted."
else
    echo "✓ caches cleared. The next \`xcodebuild\` will rebuild artifacts."
fi
