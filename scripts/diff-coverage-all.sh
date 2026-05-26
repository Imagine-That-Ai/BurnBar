#!/usr/bin/env bash
# Multi-surface diff coverage orchestrator (Swift, Kotlin, TypeScript).
#
# Usage:
#   diff-coverage-all.sh <base-ref>
#
# Runs surface-specific gates when matching files changed.
# Does NOT early-exit with 100% when only one surface changed.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"
failed=0

swift_changed="$(git diff --name-only "$base_ref" HEAD -- '*.swift' 2>/dev/null || true)"
kotlin_changed="$(git diff --name-only "$base_ref" HEAD -- '*.kt' 'android/**/*.kts' 2>/dev/null || true)"
ts_changed="$(git diff --name-only "$base_ref" HEAD -- 'functions/src/**/*.ts' 'extensions/openburnbar/src/**/*.ts' 2>/dev/null || true)"

echo "=== OpenBurnBar diff coverage (base: $base_ref, threshold: ${threshold}%) ==="

if [[ -n "$swift_changed" ]]; then
    echo "--- Swift ---"
    if [[ -f "$repo_root/openburnbar-coverage.json" ]]; then
        cov_json="$repo_root/openburnbar-coverage.json"
    elif [[ -d "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" ]]; then
        cov_json="$TMPDIR/openburnbar-coverage-all-swift.json"
        "$repo_root/scripts/extract-coverage.sh" "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" > "$cov_json"
    else
        echo "::error::Swift files changed but no coverage artifact found." >&2
        failed=1
        cov_json=""
    fi
    if [[ -n "${cov_json:-}" ]]; then
        lines_json=""
        if [[ -d "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" ]]; then
            lines_json="$TMPDIR/openburnbar-coverage-all-lines.json"
            "$repo_root/scripts/extract-coverage-lines.sh" "$repo_root/.derived-data/OpenBurnBar_TestCoverage.xcresult" > "$lines_json" 2>/dev/null || lines_json=""
        fi
        if ! COVERAGE_THRESHOLD="$threshold" "$repo_root/scripts/diff-coverage.sh" "$base_ref" "$cov_json" "${lines_json:-}"; then
            failed=1
        fi
    fi
else
    echo "--- Swift: no changes, skipped ---"
fi

if [[ -n "$kotlin_changed" ]]; then
    echo "--- Kotlin (Android) ---"
    if ! "$repo_root/scripts/diff-coverage-android.sh" "$base_ref"; then
        failed=1
    fi
else
    echo "--- Kotlin: no changes, skipped ---"
fi

if [[ -n "$ts_changed" ]]; then
    echo "--- TypeScript ---"
    if ! "$repo_root/scripts/diff-coverage-ts.sh" "$base_ref"; then
        failed=1
    fi
else
    echo "--- TypeScript: no changes, skipped ---"
fi

if [[ "$failed" -ne 0 ]]; then
    echo "::error::One or more diff coverage gates failed." >&2
    exit 1
fi

echo "=== All applicable diff coverage gates passed ==="
