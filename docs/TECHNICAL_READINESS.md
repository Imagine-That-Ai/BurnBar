# OpenBurnBar Technical Readiness

Current diligence-facing snapshot for investors, operators, and senior engineers.

**Evidence snapshot (UTC):** 2026-07-08 source-readiness pass. This page is not
commercial launch proof. A launch claim requires fresh live evidence under
`launch-evidence/` plus a passing `scripts/commercial-launch-gate.mjs` run.

## Current Posture

OpenBurnBar has a strong engineering foundation: typed schema surfaces,
domain-specific sync services, resilience wrappers, security ratchets, rules
tests, operator runbooks, and release gates. The July diligence review found
that the source maturity is materially stronger than the launch proof posture:
the codebase can support production, but stale evidence and environment-coupled
ops checks must never be presented as current readiness.

## Evidence Boundaries

| Area | Current source guard | What still requires live proof |
|------|----------------------|--------------------------------|
| Public endpoints | `functions/src/security/endpointAuthorizationCatalog.generated.ts`; endpoint inventory tests; `latestRouterRundown` product-layer rate limit | Deployed endpoint catalog and production traffic telemetry |
| Storage rules | `scripts/ci/test-storage-rules.sh`; storage emulator suite in release, security, full-matrix, and deploy-firestore workflows | Deployed Firebase Storage ruleset ID |
| Launch evidence hygiene | `scripts/ci/check-no-stale-launch-evidence.sh` rejects tracked commercial `NO_GO` gate artifacts | Fresh commercial launch gate JSON from the release machine |
| Build artifact hygiene | `.gitignore` plus `scripts/ci/check-no-committed-build-artifacts.sh` blocks tracked module caches, DerivedData, and `.pcm` files | Clean release checkout generated from tracked source only |
| Ops readiness | `scripts/ci/verify-ops-readiness.sh` checks logging, resilience, legal packet, and Hermes provenance | `verify-production-ops-plane.sh` with production credentials and a matching `HERMES_AGENT_SRC` checkout |
| Android E2E | PR harness and nightly E2E now execute `scripts/e2e/android-iroh-chat.sh` on emulator when the relevant lane runs | Green instrumented result from GitHub Actions or a local emulator with valid Firebase config |
| Rollback | Fixture dry-run plus `scripts/ci/check-runbook-topology.mjs` topology lint | Staging/production revision-pin receipt — **PENDING** (human queue item 15 runs the live drill) |

## Diligence Interpretation

Use this page as a map of source-controlled readiness, not as investor-ready
launch evidence. The correct diligence packet is:

1. This source snapshot.
2. Passing CI runs for the relevant branch.
3. Fresh ops-readiness output.
4. Fresh production ops-plane output.
5. Fresh commercial launch gate output.
6. `launch-evidence/final-launch-evidence.json` validated with
   `scripts/validate-launch-evidence-bundle.mjs --require-done-stamp`.

If any item is stale, missing, or environment-blocked, the honest status is
source-ready with named launch blockers, not launch-ready.
