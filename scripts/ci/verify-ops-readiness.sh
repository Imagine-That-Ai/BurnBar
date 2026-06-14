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

# F5: the on-host Hermes agent runtime ships as bytecode; this gate proves it
# corresponds to the reviewed source AND that the C-4 command-guard hardening is
# present (manifest.pendingHardening.blocking == false). Pre-beta ops-readiness
# MUST NOT pass while the agent can't be trusted to refuse destructive/exfil
# commands. Requires a hermes-agent checkout (HERMES_AGENT_SRC, default
# ~/.hermes/hermes-agent); the verify script fails closed if it is missing.
echo "==> verify-vendored-agent-source (agent runtime provenance + command-guard gate)"
bash scripts/ci/verify-vendored-agent-source.sh

echo "==> ops alert policy manifest"
node --check functions/scripts/ops-alert-policy-definitions.mjs
node --check functions/scripts/apply-ops-alert-policies.mjs
node --check functions/scripts/create-ops-log-metrics.mjs

echo "==> post-deploy health gate script"
bash -n scripts/ci/post-deploy-health-gate.sh

echo "==> production ops plane scripts"
bash -n scripts/ops/activate-production-ops-plane.sh
bash -n scripts/ops/verify-production-ops-plane.sh
bash -n scripts/ops/verify-firestore-disaster-recovery.sh
bash -n scripts/ops/verify-github-governance.sh
bash -n scripts/ops/resolve-functions-base-url.sh
bash -n scripts/ops/deploy-health-functions.sh
bash -n scripts/ops/discover-gcp-access.sh
node --check scripts/ops/check-ops-alerts.mjs
node --check scripts/lib/ops-alerts-gate.mjs
node --test scripts/lib/ops-alerts-gate.test.mjs

echo "==> release attestation verifier"
bash -n scripts/ci/verify-release-attestations.sh

# F-RR02-002: verify that firestore.indexes.json declares TTL policies for
# collections that depend on automatic cleanup. The live deployment state must
# be verified separately with:
#   gcloud firestore fields ttls list --project=<prod-project>
# This check ensures the declarations are not accidentally removed from source.
echo "==> firestore TTL policy declarations"
INDEXES_FILE="firestore.indexes.json"
ttl_ok=true
for group in pop_nonces _rate_limits hermes_gateway_device_sessions public_rate_limits; do
  if ! grep -A5 "\"collectionGroup\".*\"${group}\"" "$INDEXES_FILE" | grep -q '"ttl".*true'; then
    echo "FAIL: missing TTL declaration for collection group '${group}' in ${INDEXES_FILE}"
    ttl_ok=false
  fi
done
if [ "$ttl_ok" = false ]; then
  echo "FAIL: Firestore TTL declarations missing — see F-RR02-002"
  exit 1
fi
echo "  TTL declarations verified for pop_nonces, _rate_limits, hermes_gateway_device_sessions, public_rate_limits"

echo "PASS: ops readiness"
