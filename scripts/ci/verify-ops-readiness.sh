#!/usr/bin/env bash
# Meta gate: callable logging, resilience wiring, ops policy manifests.
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "==> verify-callable-logging"
bash scripts/ci/verify-callable-logging.sh

echo "==> verify-resilience-wiring"
bash scripts/ci/verify-resilience-wiring.sh

echo "==> verify-agpl-compliance"
bash scripts/ci/verify-agpl-compliance.sh

echo "==> ops alert policy manifest"
node --check functions/scripts/ops-alert-policy-definitions.mjs
node --check functions/scripts/apply-ops-alert-policies.mjs
node --check functions/scripts/create-ops-log-metrics.mjs

echo "==> post-deploy health gate script"
bash -n scripts/ci/post-deploy-health-gate.sh

echo "==> production ops plane scripts"
bash -n scripts/ops/activate-production-ops-plane.sh
bash -n scripts/ops/verify-production-ops-plane.sh
bash -n scripts/ops/resolve-functions-base-url.sh
bash -n scripts/ops/deploy-health-functions.sh
bash -n scripts/ops/discover-gcp-access.sh
node --check scripts/ops/check-ops-alerts.mjs
node --check scripts/lib/ops-alerts-gate.mjs

echo "PASS: ops readiness"
