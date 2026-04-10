#!/bin/bash
#
# verify-flow-report-finalization.sh
#
# Implements runtime finalization enforcement for user-testing flow validators.
# This script MUST be called before a user-testing validation run can report success.
# It verifies that all required flow report artifacts exist; missing reports
# produce explicit failure with missing-path and directory diagnostics.
#
# Usage:
#   ./verify-flow-report-finalization.sh <milestone> [report1 report2 ...]
#
# Arguments:
#   milestone    - The milestone name (e.g., core-engine, fast-surfaces)
#   reportN      - Optional: specific report filenames to check (default: settings-ui.json launch-contracts.json)
#
# Exit codes:
#   0 - All required flow reports exist
#   1 - One or more required flow reports are missing
#
# This script implements the enforcement described in user-testing.md:
# "Flow Report Finalization - Critical: Flow validator success requires
# existence of required flow report file(s)."
#
# No silent success: A validation run that passes tests but fails to persist
# flow reports must NOT report as pass. The missing report is a blocking
# failure requiring explicit diagnostics.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print error message
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

# Function to print success message
success() {
    echo -e "${GREEN}$1${NC}"
}

# Function to print info message
info() {
    echo -e "${YELLOW}$1${NC}"
}

# Validate arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <milestone> [report1 report2 ...]" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  milestone    - The milestone name (e.g., core-engine, fast-surfaces)" >&2
    echo "  reportN      - Optional: specific report filenames to check" >&2
    echo "                (default: settings-ui.json launch-contracts.json)" >&2
    exit 1
fi

MILESTONE="$1"
shift

# Default required reports if not specified
if [ $# -eq 0 ]; then
    REQUIRED_REPORTS="settings-ui.json launch-contracts.json"
else
    REQUIRED_REPORTS="$*"
fi

# Construct the flows directory path
# The flows directory is at: .factory/validation/<milestone>/user-testing/flows/
REPO_ROOT="$(git -C "$(dirname "$0")/../../../" rev-parse --show-toplevel 2>/dev/null || echo ".")"
FLOWS_DIR="${REPO_ROOT}/.factory/validation/${MILESTONE}/user-testing/flows"

info "=== Flow Report Finalization Enforcement ==="
info "Milestone: ${MILESTONE}"
info "Flows directory: ${FLOWS_DIR}"
info "Required reports: ${REQUIRED_REPORTS}"
echo ""

# Check if flows directory exists
if [ ! -d "${FLOWS_DIR}" ]; then
    error "Flows directory does not exist: ${FLOWS_DIR}"
    error "Cannot verify flow reports without flows directory."
    exit 1
fi

# Track missing reports
MISSING_REPORTS=()
EXISTING_REPORTS=()

# Check each required report
for report in ${REQUIRED_REPORTS}; do
    REPORT_PATH="${FLOWS_DIR}/${report}"
    if [ -f "${REPORT_PATH}" ]; then
        EXISTING_REPORTS+=("${report}")
        success "✓ Found: ${report}"
    else
        MISSING_REPORTS+=("${report}")
        error "✗ Missing: ${report}"
        error "  Expected path: ${REPORT_PATH}"
    fi
done

echo ""

# If any reports are missing, fail with diagnostics
if [ ${#MISSING_REPORTS[@]} -gt 0 ]; then
    error "=== Flow Report Finalization FAILED ==="
    error ""
    error "Missing ${#MISSING_REPORTS[@]} required flow report(s):"
    for report in "${MISSING_REPORTS[@]}"; do
        error "  - ${report}"
    done
    error ""
    error "Diagnostics:"
    error "  Missing path(s):"
    for report in "${MISSING_REPORTS[@]}"; do
        error "    - ${FLOWS_DIR}/${report}"
    done
    error ""
    error "  Flows directory contents:"
    if [ -d "${FLOWS_DIR}" ]; then
        ls -la "${FLOWS_DIR}" | while read -r line; do
            error "    ${line}"
        done
    else
        error "    (directory does not exist)"
    fi
    error ""
    error "Validator MUST NOT report success when required flow reports are missing."
    error "This is a blocking failure per Flow Report Finalization policy."
    echo ""
    info "To fix: Ensure all required flow reports are generated before finalization."
    exit 1
fi

# All reports exist - success
success "=== Flow Report Finalization PASSED ==="
success ""
success "All ${#EXISTING_REPORTS[@]} required flow report(s) verified:"
for report in "${EXISTING_REPORTS[@]}"; do
    success "  - ${report}"
done
success ""
success "Validator MAY report success. Flow reports persisted correctly."

# Output the flowReports array for synthesis.json
echo ""
info "Flow reports for synthesis.json:"
FLOW_REPORTS_JSON="["
first=true
for report in "${EXISTING_REPORTS[@]}"; do
    if [ "$first" = true ]; then
        first=false
    else
        FLOW_REPORTS_JSON+=", "
    fi
    FLOW_REPORTS_JSON+="\"\.factory/validation/${MILESTONE}/user-testing/flows/${report}\""
done
FLOW_REPORTS_JSON+="]"
echo "${FLOW_REPORTS_JSON}"

exit 0
