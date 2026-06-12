#!/usr/bin/env bash
# Multi-surface diff coverage orchestrator (Swift, Kotlin, TypeScript).
#
# Usage:
#   diff-coverage-all.sh <base-ref>
#
# Runs surface-specific gates when matching files changed; surfaces with no
# changed files are skipped, so e.g. Swift-only PRs never pay Android costs.
# Does NOT early-exit with 100% when only one surface changed.
#
# Environment passthrough (consumed by scripts/diff-coverage.sh):
#   COVERAGE_THRESHOLD    minimum diff coverage percent (default 80)
#   DIFF_COVERAGE_SCOPE   all|app|packages — which Swift partition this lane
#                         is allowed to judge (see diff-coverage.sh header)
#   DIFF_COVERAGE_OUTPUT  optional path for the Swift verdict JSON

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
    echo "--- Swift (scope: ${DIFF_COVERAGE_SCOPE:-all}) ---"
    # diff-coverage.sh owns Swift evidence resolution: it extracts per-line
    # maps from the app xcresult and/or SwiftPM package coverage as its scope
    # requires, and fails closed when the evidence its scope needs is absent.
    cov_json=""
    if [[ -f "$repo_root/openburnbar-coverage.json" ]]; then
        cov_json="$repo_root/openburnbar-coverage.json"
    fi
    if ! COVERAGE_THRESHOLD="$threshold" "$repo_root/scripts/diff-coverage.sh" "$base_ref" "$cov_json"; then
        failed=1
    fi
else
    echo "--- Swift: no changes, skipped ---"
fi

if [[ -n "$kotlin_changed" ]]; then
    echo "--- Kotlin (Android) ---"
    jacoco_xml="$repo_root/android/app/build/reports/jacoco/testDebugUnitTest/jacocoTestReport.xml"
    if [[ -f "$jacoco_xml" ]]; then
        if ! "$repo_root/scripts/diff-coverage-android.sh" "$base_ref"; then
            failed=1
        fi
    else
        # Lane partition (CG-1): a lane that cannot see is not allowed to
        # judge. The Android harness job runs the unit tests, generates the
        # JaCoCo report, and gates Kotlin diffs with real line evidence; this
        # aggregate (App XCTest) has no Android build and would only have
        # test-file PRESENCE — which is never evidence.
        echo "::notice::Kotlin diff present but no JaCoCo report in this lane — gated by the Android job with real line evidence."
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
