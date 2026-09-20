#!/usr/bin/env bash

# Shared XCTest log classifier for scripts/test-openburnbar-app.sh and its
# fixture tests. These helpers intentionally separate infrastructure-level
# runner crashes from concrete XCTest failures so CI retries flakes without
# hiding real regressions.

openburnbar_app_test_hang_substrings=(
    "test runner hung before establishing connection"
    "Test runner never began executing tests"
    "Test session timed out"
    "Timed out while enabling automation mode"
    "Failed to launch test runner"
    "failed to launch"
    "Lost connection to the test runner"
    "Could not attach to pid"
    "TestRunner crashed"
    "Restarting after unexpected exit, crash, or test timeout"
    "freed pointer was not the last allocation"
)

openburnbar_app_test_has_concrete_xctest_failure() {
    local log_path="$1"

    if grep -Eq "Test Case '-\\[[^]]+\\]' failed" "$log_path"; then
        return 0
    fi

    if grep -Eq "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[1-9][0-9]* failures?" "$log_path"; then
        return 0
    fi

    if awk '
        /^Failing tests:/ { in_failing = 1; next }
        in_failing && /^[[:space:]]*$/ { next }
        in_failing && /^[^[:space:]]/ { in_failing = 0 }
        in_failing && NF { found = 1; exit }
        END { exit found ? 0 : 1 }
    ' "$log_path"; then
        return 0
    fi

    return 1
}

openburnbar_app_test_has_terminal_concrete_xctest_failure() {
    local log_path="$1"

    if openburnbar_app_test_has_execution_timeout_restart "$log_path" &&
        openburnbar_app_test_final_selected_summary_is_green "$log_path"; then
        return 1
    fi

    if openburnbar_app_test_has_execution_timeout_restart "$log_path"; then
        openburnbar_app_test_has_concrete_xctest_failure "$log_path"
        return $?
    fi

    openburnbar_app_test_has_concrete_xctest_failure "$log_path"
}

openburnbar_app_test_has_assertion_failure() {
    local log_path="$1"

    grep -Eq "Test Case '-\\[[^]]+\\]' failed" "$log_path"
}

openburnbar_app_test_has_execution_timeout_restart() {
    local log_path="$1"

    grep -Fq "exceeded execution time allowance" "$log_path" || return 1
    grep -Fq "Restarting after unexpected exit, crash, or test timeout" "$log_path" || return 1

    # A timed-out/crashed test host can leave a stale "Failing tests:" footer
    # even after Xcode relaunches the host and reports a clean selected-suite
    # pass. Retry that infrastructure failure, but never hide a normal XCTest
    # assertion failure that appears in the same log.
    if openburnbar_app_test_has_assertion_failure "$log_path"; then
        return 1
    fi

    return 0
}

openburnbar_app_test_final_selected_summary_is_green() {
    local log_path="$1"

    awk '
        /Test Suite '\''Selected tests'\'' (passed|failed)/ {
            waiting_for_summary = 1
            green = 0
            next
        }
        waiting_for_summary && /Executed [0-9]+ tests?/ {
            if ($0 ~ /Executed [1-9][0-9]* tests?, with ([0-9]+ tests? skipped and )?0 failures/) {
                green = 1
            } else {
                green = 0
            }
            waiting_for_summary = 0
        }
        END { exit green ? 0 : 1 }
    ' "$log_path"
}

is_swiftpm_dependency_resolution_transient() {
    local log_path="$1"

    if openburnbar_app_test_has_concrete_xctest_failure "$log_path"; then
        return 1
    fi

    if grep -Fq "** INTERNAL ERROR: Uncaught exception **" "$log_path" &&
        grep -Fq "*** -[NSMutableArray insertObjects:atIndexes:]" "$log_path" &&
        grep -Eq "IDESwiftPackageCore|SPMWorkspace|packageGraphDidFinishAction" "$log_path"; then
        return 0
    fi

    grep -Eq "Could not resolve package dependencies|failed downloading .* which is required by binary target|Failed to clone repository|fatal: unable to access|Git command .* config --get remote\\.origin\\.url|binary target .*OpenBurnBarSignalFfi.* could not be mapped" "$log_path" || return 1
    grep -Eiq "downloadError\\(\"The request timed out\\.\"\\)|Failed to connect to .* port 443|Couldn'?t connect to server|Connection (reset|timed out)|network connection was lost|TLS handshake timeout|HTTP (502|503|504)|Bad Gateway|Service Unavailable|Gateway Timeout|fatal: cannot change to .+: No such file or directory|binary target .*OpenBurnBarSignalFfi.* could not be mapped to an artifact with expected name .*OpenBurnBarSignalFfi" "$log_path"
}

is_known_hang() {
    local log_path="$1"
    local pattern

    if openburnbar_app_test_has_execution_timeout_restart "$log_path" &&
        openburnbar_app_test_final_selected_summary_is_green "$log_path"; then
        return 0
    fi

    if openburnbar_app_test_has_concrete_xctest_failure "$log_path"; then
        return 1
    fi

    for pattern in "${openburnbar_app_test_hang_substrings[@]}"; do
        if grep -Fq "$pattern" "$log_path"; then
            return 0
        fi
    done
    return 1
}
