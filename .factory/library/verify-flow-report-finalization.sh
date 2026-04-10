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
#   reportN      - Optional: specific report filenames to check
#                  (defaults are milestone-aware via built-in mapping)
#
# Exit codes:
#   0 - All required flow reports exist
#   1 - One or more required flow reports are missing
#
# Default Report Mapping (milestone-aware):
#   core-engine: settings-ui.json, launch-contracts.json
#   fast-surfaces: dashboard.json, popover.json
#   m1-provenance-foundation: group-core-persistence.json, group-remote-watermark.json
#   m2-exact-ingestion-precision: group-a.json, group-b.json
#   m3-hybrid-indexing-efficiency: group-a.json, group-b.json
#   m4-reconciliation-backfill-hardening: group-reconciliation-core.json, group-reporting-audit.json
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
    echo "                (defaults are milestone-aware via built-in mapping)" >&2
    echo "" >&2
    echo "Default report mapping:" >&2
    echo "  core-engine: settings-ui.json, launch-contracts.json" >&2
    echo "  fast-surfaces: dashboard.json, popover.json" >&2
    echo "  m1-provenance-foundation: group-core-persistence.json, group-remote-watermark.json" >&2
    echo "  m2-exact-ingestion-precision: group-a.json, group-b.json" >&2
    echo "  m3-hybrid-indexing-efficiency: group-a.json, group-b.json" >&2
    echo "  m4-reconciliation-backfill-hardening: group-reconciliation-core.json, group-reporting-audit.json" >&2
    echo "" >&2
    echo "If no default is available for the milestone, reports must be specified explicitly." >&2
    exit 1
fi

MILESTONE="$1"
shift

# Construct the repo root path early (needed for milestone default lookup)
# The flows directory is at: .factory/validation/<milestone>/user-testing/flows/
REPO_ROOT="$(git -C "$(dirname "$0")/../../../" rev-parse --show-toplevel 2>/dev/null || echo ".")"

# Milestone-specific default required reports mapping
# Maps milestone names to their required flow report filenames.
# This mapping is milestone-aware: each milestone has its own set of reports
# that must exist before a validation run can report success.
get_milestone_default_reports() {
    local milestone="$1"
    case "$milestone" in
        core-engine)
            echo "settings-ui.json launch-contracts.json"
            ;;
        fast-surfaces)
            echo "dashboard.json popover.json"
            ;;
        integration-hardening)
            echo "settings-ui.json launch-contracts.json"
            ;;
        m1-provenance-foundation)
            echo "group-core-persistence.json group-remote-watermark.json"
            ;;
        m2-exact-ingestion-precision)
            echo "group-a.json group-b.json"
            ;;
        m3-hybrid-indexing-efficiency)
            echo "group-a.json group-b.json"
            ;;
        m4-reconciliation-backfill-hardening)
            echo "group-reconciliation-core.json group-reporting-audit.json"
            ;;
        misc-core-engine-followups|misc-infra-followups|misc-m4-followups)
            # Misc milestones may have variable reports - try to infer from synthesis.json
            echo ""
            ;;
        *)
            echo ""
            ;;
    esac
}

# Try to read flowReports from synthesis.json for a milestone
get_synthesis_flow_reports() {
    local milestone="$1"
    local synthesis_path="${REPO_ROOT}/.factory/validation/${milestone}/user-testing/synthesis.json"
    if [ -f "$synthesis_path" ]; then
        # Extract flowReports array from synthesis.json using grep and sed
        local flow_reports
        flow_reports=$(grep -o '"flowReports": \[[^]]*\]' "$synthesis_path" 2>/dev/null | head -1 || true)
        if [ -n "$flow_reports" ]; then
            # Extract just the filenames from the array
            echo "$flow_reports" | sed -n 's/.*flows\/\([^"]*\.json\).*/\1/p' | tr '\n' ' '
            return 0
        fi
    fi
    # Return empty string instead of 1 to avoid triggering set -e
    return 0
}

# Default required reports if not specified
if [ $# -eq 0 ]; then
    # First try milestone-specific defaults
    REQUIRED_REPORTS=$(get_milestone_default_reports "$MILESTONE")
    
    # If milestone has no hardcoded defaults, try to read from synthesis.json
    if [ -z "$REQUIRED_REPORTS" ]; then
        REQUIRED_REPORTS=$(get_synthesis_flow_reports "$MILESTONE")
    fi
    
    # If still empty, check if milestone has any user-testing flows directory
    # If no defaults and no synthesis data, this milestone may not require enforcement
    # (i.e., features don't have user-facing assertions requiring flow reports)
    if [ -z "$REQUIRED_REPORTS" ]; then
        FLOWS_DIR_CHECK="${REPO_ROOT}/.factory/validation/${MILESTONE}/user-testing/flows"
        if [ ! -d "${FLOWS_DIR_CHECK}" ]; then
            # No flows directory means this milestone doesn't have user-testing assertions
            # Enforcement is not required - pass silently
            success "=== Flow Report Finalization PASSED (No Enforcement Required) ==="
            success ""
            success "Milestone ${MILESTONE} does not have user-testing flow reports configured."
            success "This is expected for milestones without user-facing assertions."
            success ""
            success "Validator MAY report success. No flow report enforcement needed."
            exit 0
        else
            # Flows directory exists but no defaults - require explicit specification
            error "=== Flow Report Finalization FAILED ==="
            error ""
            error "No default required reports found for milestone: ${MILESTONE}"
            error ""
            error "This milestone does not have milestone-aware default reports configured."
            error "You must specify reports explicitly: $0 <milestone> [report1 report2 ...]"
            error ""
            error "To fix: Provide required report filenames as arguments, e.g.:"
            error "  $0 ${MILESTONE} dashboard.json popover.json"
            error ""
            error "Or add this milestone to the milestone-defaults mapping in the script."
            exit 1
        fi
    fi
else
    REQUIRED_REPORTS="$*"
fi

# Construct the flows directory path
# The flows directory is at: .factory/validation/<milestone>/user-testing/flows/
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
