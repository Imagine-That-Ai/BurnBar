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
node functions/scripts/test-ops-alert-policy-definitions.mjs
node --check functions/scripts/apply-ops-alert-policies.mjs
node --check functions/scripts/create-ops-log-metrics.mjs

echo "==> drift-check scripts (offline self-tests: prove MATCH/DRIFT detection)"
# Both drift checks gate LIVE state == committed source of truth in CI (they need
# creds). Here we run their creds-free self-tests so the DIFF LOGIC is itself gated
# offline: a broken drift check that can no longer detect drift must fail loud.
node --check scripts/lib/branch-protection-drift.mjs
node --check scripts/ops/check-branch-protection-drift.mjs
node --test scripts/ops/check-branch-protection-drift.test.mjs
node --check scripts/lib/ops-alert-plane-drift.mjs
node --check scripts/ops/check-ops-alert-plane-drift.mjs
node --test scripts/ops/check-ops-alert-plane-drift.test.mjs

echo "==> post-deploy health gate script"
bash -n scripts/ci/post-deploy-health-gate.sh
bash scripts/ci/verify-hosted-mcp-deploy-health.sh

echo "==> production ops plane scripts"
bash -n scripts/rollback.sh
bash -n scripts/rollback.test.sh
bash scripts/rollback.test.sh
bash -n scripts/ops/rollback-revision.sh
bash -n scripts/ops/rollback-revision.test.sh
bash scripts/ops/rollback-revision.test.sh
bash -n scripts/ops/rollback-macos-appcast.sh
bash -n scripts/ops/rollback-macos-appcast.test.sh
bash scripts/ops/rollback-macos-appcast.test.sh
bash -n scripts/ops/activate-production-ops-plane.sh
bash -n scripts/ops/verify-production-ops-plane.sh
bash -n scripts/ops/verify-firestore-disaster-recovery.sh
bash -n scripts/ops/verify-github-governance.sh
bash -n scripts/ops/verify-firestore-app-check-enforcement.sh
bash -n scripts/ops/verify-firestore-app-check-enforcement.test.sh
bash scripts/ops/verify-firestore-app-check-enforcement.test.sh
bash -n scripts/ops/resolve-functions-base-url.sh
bash -n scripts/ops/deploy-health-functions.sh
bash -n scripts/ops/discover-gcp-access.sh
node --check scripts/ops/check-ops-alerts.mjs
node --check scripts/lib/ops-alerts-gate.mjs
node --test scripts/lib/ops-alerts-gate.test.mjs
node --check scripts/ops/run-alert-delivery-drill.mjs
node --check scripts/lib/alert-delivery-drill.mjs
node --test scripts/lib/alert-delivery-drill.test.mjs

echo "==> release attestation verifier"
bash -n scripts/ci/verify-release-attestations.sh

echo "==> Phase 1 security register structural gates"
bash scripts/ci/verify-phase1-security-gates.sh

echo "==> privacy invariants gate (run-09) — self-test then enforce"
node scripts/ci/check-privacy-invariants.test.mjs
node scripts/ci/check-privacy-invariants.mjs

echo "==> credential-transfer secret boundary"
bash scripts/ci/verify-credential-transfer-secret-boundary.sh

echo "PASS: ops readiness"
