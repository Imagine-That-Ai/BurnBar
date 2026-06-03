#!/usr/bin/env bash

# Shared XCTest log classifier for scripts/test-openburnbar-app.sh and its
# fixture tests. These helpers intentionally separate infrastructure-level
# runner crashes from concrete XCTest failures so CI retries flakes without
# hiding real regressions.

openburnbar_app_test_hang_substrings=(
    "test runner hung before establishing connection"
    "Test runner never began executing tests"
    "Test session timed out"
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

openburnbar_app_test_final_selected_summary_is_green() {
    local log_path="$1"

    awk '
        /Test Suite '\''Selected tests'\'' passed/ {
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

openburnbar_app_test_has_final_failing_tests_section() {
    local log_path="$1"

    awk '
        /^Failing tests:/ {
            in_failing = 1
            found = 0
            next
        }
        in_failing && /^[[:space:]]*$/ { next }
        in_failing && /^[^[:space:]]/ { in_failing = 0 }
        in_failing && NF { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$log_path"
}

is_known_hang() {
    local log_path="$1"
    local pattern

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

is_xcode_false_negative_pass() {
    local log_path="$1"

    # Xcode can occasionally return 65 and print "** TEST FAILED **" after the
    # selected XCTest suite has already reported a clean run. Accept that as
    # success only when the final selected-suite summary is unambiguously green
    # and Xcode did not append a final failing-tests section.
    openburnbar_app_test_final_selected_summary_is_green "$log_path" || return 1

    if openburnbar_app_test_has_final_failing_tests_section "$log_path"; then
        return 1
    fi

    return 0
}
