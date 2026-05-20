#!/usr/bin/env bash
# Verify the local Iroh Services API secret can authenticate and push one
# metrics snapshot from a real iroh endpoint.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export IROH_REPO_ROOT="${REPO_ROOT}"
export IROH_REQUIRE_SERVICES_SECRET=true
# shellcheck source=../ci/load-iroh-services-secret.sh
. "${REPO_ROOT}/scripts/ci/load-iroh-services-secret.sh"

export OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME="${OPENBURNBAR_IROH_SERVICES_ENDPOINT_NAME:-openburnbar-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"

cd "${REPO_ROOT}/crates/openburnbar-iroh"
cargo run --example iroh_services_smoke --quiet
