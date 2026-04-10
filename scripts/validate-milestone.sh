#!/usr/bin/env bash
#
# validate-milestone.sh
#
# Integrated validator execution path that enforces flow report finalization
# before allowing success. This script is the runtime integration point for
# the verify-flow-report-finalization.sh enforcement check.
#
# Usage:
#   ./scripts/validate-milestone.sh <milestone>
#
# Example:
#   ./scripts/validate-milestone.sh misc-infra-followups
#   ./scripts/validate-milestone.sh fast-surfaces
#
# Exit codes:
#   0 - Enforcement passed AND all validators passed
#   1 - Enforcement failed OR validators failed
#
# This script implements the runtime integration requirement:
# "Validator runtime path invokes enforcement check automatically during finalization."
#

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
    echo "Usage: $0 <milestone>" >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  milestone    - The milestone name (e.g., core-engine, fast-surfaces, misc-infra-followups)" >&2
    echo "" >&2
    echo "This script runs flow report enforcement check before executing validators." >&2
    exit 1
fi

MILESTONE="$1"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

info "=== Milestone Validation with Flow Report Enforcement ==="
info "Milestone: ${MILESTONE}"
info "Repo root: ${REPO_ROOT}"
echo ""

# Step 1: Run flow report finalization enforcement check
info "--- Step 1: Flow Report Finalization Enforcement ---"

ENFORCEMENT_SCRIPT="${REPO_ROOT}/.factory/library/verify-flow-report-finalization.sh"

if [ ! -f "$ENFORCEMENT_SCRIPT" ]; then
    error "Enforcement script not found: ${ENFORCEMENT_SCRIPT}"
    exit 1
fi

# Run the enforcement check
# This will exit 1 if required flow reports are missing
set +e
"$ENFORCEMENT_SCRIPT" "$MILESTONE"
ENFORCEMENT_EXIT=$?
set -e

if [ $ENFORCEMENT_EXIT -ne 0 ]; then
    error ""
    error "=== VALIDATION FAILED: Flow Report Enforcement ==="
    error ""
    error "Required flow reports are missing for milestone: ${MILESTONE}"
    error "Validator CANNOT report success until all required flow reports exist."
    error ""
    error "To fix: Ensure all required flow reports are generated and persisted."
    error "See enforcement script output above for which reports are missing."
    exit 1
fi

success "Flow report enforcement passed."
echo ""

# Step 2: Run test validators
info "--- Step 2: Running Test Validators ---"

cd "$REPO_ROOT"

# Run swift tests
info "Running Swift package tests..."
if ! bash "${REPO_ROOT}/scripts/test-openburnbar-swift.sh"; then
    error "Swift package tests failed."
    exit 1
fi
success "Swift package tests passed."

# Run app tests
info "Running app tests..."
if ! bash "${REPO_ROOT}/scripts/test-openburnbar-app.sh"; then
    error "App tests failed."
    exit 1
fi
success "App tests passed."
echo ""

# Step 3: Run typecheck
info "--- Step 3: Running Typecheck ---"

if ! xcodebuild build-for-testing \
    -project "${REPO_ROOT}/OpenBurnBar.xcodeproj" \
    -scheme "OpenBurnBar" \
    -destination "platform=macOS,arch=arm64" \
    -clonedSourcePackagesDirPath "${REPO_ROOT}/.spm-cache" \
    -derivedDataPath "${REPO_ROOT}/.derived-data/ci-typecheck" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO; then
    error "Typecheck failed."
    exit 1
fi
success "Typecheck passed."
echo ""

# Step 4: Run lint
info "--- Step 4: Running Lint ---"

if ! npm --prefix "${REPO_ROOT}/extensions/openburnbar" run lint; then
    error "Lint failed."
    exit 1
fi
success "Lint passed."
echo ""

# All steps passed
success "=== VALIDATION PASSED ==="
success ""
success "Flow report enforcement: PASSED"
success "Test validators: PASSED"
success "Typecheck: PASSED"
success "Lint: PASSED"
success ""
success "Milestone ${MILESTONE} validation complete. Success can be reported."

exit 0
