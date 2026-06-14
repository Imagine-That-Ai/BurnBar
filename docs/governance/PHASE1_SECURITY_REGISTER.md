# Phase 1 Security Register

Live closure ledger for the debt-free plan's Phase 1 items — register debt that
can hurt users. Historical diligence reports (`DILIGENCE_REPORT_2026-06-11.md`,
`TECH_DEBT_AUDIT_2026-06-11.md`) stay immutable; this file is the current
status, proof commands, and remaining evidence.

Accepted product decisions live in
[`RISK_REGISTER.md`](RISK_REGISTER.md), not here.

## Status Snapshot

| ID | Status | Current proof | Remaining work |
| --- | --- | --- | --- |
| NB-1 | **Closed 2026-06-13** | `node scripts/ops/check-ops-alerts.mjs` exits 0 and verifies concrete notification-channel objects (enabled, verified email targets). Gate rejects `support@openburnbar.app` by default. Live GCP channel `projects/burnbar/notificationChannels/5012565067290551244` → `alberto8793@gmail.com`. Website support contact repointed to `support@burnbar.ai` (`website/src/data/site.ts`). | Keep `OPENBURNBAR_DISALLOWED_ALERT_EMAILS` current if other dead addresses are discovered. |
| NB-2 | **Closed 2026-06-13** | `.github/workflows/deploy-production.yml` checks out with `submodules: recursive`, then `git submodule update --init --recursive` after the release-tag checkout so `Vendor/libsignal` matches the tag gitlink before provenance preflight. `docs/runbooks/functions-break-glass.md` documents the bounded emergency lane. | Prove the lane end-to-end on the next production tag after counsel clears; confirm live functions `updateTime` postdates LB-5/P0-7 fixes. |
| C-2 | **Closed 2026-06-13** | Client-verifiable escrow trust chain before vault-key wrap: `CloudVaultTrustedDeviceChainVerifier.swift`, `MobileCloudVaultTrustedDeviceChainVerifier.swift`, `AndroidCloudVaultTrustedDeviceChainVerifier.kt`; server fingerprint backstop `ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = true` (`computerUseSecurity.ts:270`); chain fields enforced in `firestore.rules`. Tests: `approveEscrowDeviceTrustHandler.test.ts`, `escrowDeviceTrustFingerprint.test.ts`, `CloudVaultDeviceTrustChainTests.swift`, `CloudVaultDeviceTrustChainTest.kt`. | Relay sender-trust resolver should keep parity with chain verification (`security/threat-model/security-test-plan.md` C8 note). |
| C-3 | **Closed 2026-06-13** | `rotateCloudVaultKey` callable (`cloudVaultRotation.ts`) + revoke batch schedules `cloud_vault_rotation_requirements`; Mac/Android survivors rotate and rewrap (`ComputerUseSecurityCallableClient.swift`, `AndroidCloudVaultRevocationRotation.kt`, `CloudVaultRotationRewrapWorker.swift`). Tests: `cloudVaultRotationNonRevokerSurvivor.test.ts`, `cloudVaultRotationResilience.test.ts`, `CloudVaultRotationPickupTests.swift`, `AndroidCloudVaultRevocationRotationTest.kt`. | Honest limitation: pre-revocation cached keys remain readable until a survivor completes rotation; iOS lacks survivor pickup triggers (`T-PTR-02`). |
| H-4 | **Closed 2026-06-13 (code)** | Cursor connector binds secret broker to loopback, mints per-session bearer tokens, probes the public tunnel unauthenticated (must not return 200) before use (`CursorConnectorManager.swift:703-729`), and routes auth through the C-5-pinned gateway source (`third_party/hermes-agent/manifest.json`). Residual quick-tunnel exposure is accepted as **AR-006**. | Prefer named tunnels + Cloudflare Access before marketing the connector as enterprise-grade. |
| LB-5 | **Closed (code), open (ops)** | Stripe webhook event ledger + ordering guard (`stripe.ts` `stripe_webhook_events/{eventID}` transaction). | Production functions still pinned pre-fix until NB-2 lane deploys the current tag. |
| P0-7 | **Closed (code), open (ops)** | Paginated rollup rebuild + circuit breaker (`rollups.ts`, `scheduled.ts`) with vitest coverage. | Same production deploy dependency as LB-5. |
| CG-1 | **Closed 2026-06-13** | `scripts/diff-coverage.sh` documents and enforces measured line coverage only — test-file presence and directory existence are never evidence (`:32-33`). Swift package-lane coverage wired via `extract-package-coverage-lines.sh`. | Keep waiver discipline (`cov:ignore -- reason` or `COVERAGE_ALLOWLIST` only). |
| LB-4 | **Closed 2026-06-13 (code)** | `third_party/hermes-agent/manifest.json` pins `bdb830070…` with `pendingHardening.blocking: false`; `scripts/ci/verify-vendored-agent-source.sh` is blocking in `verify-ops-readiness.sh`. | Re-pin on every gateway security change; keep harness ref aligned with manifest. |
| P0-6 | **Closed (build-gated)** | Privileged input prefers authenticated XPC; VirtualHID/RemoteAccess peer auth + red-team RC evidence (`docs/runbooks/privileged-socket-redteam-rc.md`, `docs/security/SOTA_10_10_SIGNOFF.md` Phase 2). | Wire env-gated red-team suite into required CI or document operator cadence. |
| LB-1 | **Partial** | Uptime check definitions + apply script (`ops-uptime-check-definitions.mjs`); ops gate now fails on dead channels (NB-1). | First green nightly + dedupe semantics that do not mask new failures; extensions matrix `npm ci`. |
| LB-2 | **Partial** | Sparkle feed generation + in-client Ed25519 verification (`DirectDownloadArtifactVerifier.swift`, `release.yml` appcast signing). | Cut an end-to-end test release; un-silence feed smoke; prove fleet can fetch a signed update. |
| SOTA release attestations | **Open (ops)** | `release.yml` attests SBOM, VEX, checksums, DMG, ZIP, source archive, appcast, and latest feed with cosign. Verifier: `scripts/ci/verify-release-attestations.sh <tag>`. Latest release `v0.1.2-beta.12` predates DMG/ZIP attestations. | Ship the next release through current `release.yml`, run verifier, attach output to SOTA signoff. |
| SOTA attestation rollout | **Open (ops)** | `computer_use_phone_control_attestation_required` rollout ring documented in SOTA Phase 2. | Enable per ring after RC validation. |
| SOTA owner signatures | **Open (ops)** | Checklist rows green except Phase 2 attestation flag + Phase 4 attestation verify + Phase 5 signature table. | Engineering owner + security reviewer sign `docs/security/SOTA_10_10_SIGNOFF.md`. |

**Open count (debt):** 5 — LB-1, LB-2, SOTA release attestations, SOTA attestation rollout, SOTA owner signatures. (Code-closed items with only production deploy left — LB-5, P0-7 — are tracked under NB-2 remaining work, not counted as open code debt.)

## Proof Commands

```bash
# NB-1: required ops policies + live notification channels.
node scripts/ops/check-ops-alerts.mjs
node --test scripts/lib/ops-alerts-gate.test.mjs

# NB-2: deploy lane keeps release-tag submodule contents.
rg -n "submodules: recursive|git submodule update --init --recursive" \
  .github/workflows/deploy-production.yml

# C-2 / C-3: server + client escrow/vault security tests.
npm test --prefix functions -- \
  src/__tests__/approveEscrowDeviceTrustHandler.test.ts \
  src/__tests__/escrowDeviceTrustFingerprint.test.ts \
  src/__tests__/cloudVaultRotationNonRevokerSurvivor.test.ts \
  src/__tests__/cloudVaultRotationResilience.test.ts
swift test --package-path OpenBurnBarCore --filter CloudVaultDeviceTrustChainTests
cd android && ./gradlew :app:testDebugUnitTest \
  --tests com.openburnbar.data.cloud.CloudVaultDeviceTrustChainTest \
  --tests com.openburnbar.data.cloud.AndroidCloudVaultRevocationRotationTest

# H-4: connector loopback broker + vendored gateway pin.
rg -n "127.0.0.1|verifyPublicEndpoint|tunnelRotationToken" \
  AgentLens/Services/CursorConnector/CursorConnectorManager.swift
bash scripts/ci/verify-vendored-agent-source.sh

# CG-1: diff-coverage integrity self-test.
bash scripts/diff-coverage-self-test.sh

# LB-4 / ops readiness meta-gate.
bash scripts/ci/verify-ops-readiness.sh

# SOTA release-attestation box, after the next release.
scripts/ci/verify-release-attestations.sh vX.Y.Z
```

## Closure Rules

- **Fixed** means code + proof exists (test, gate, or reproducible command). Do not
  mark accepted risk or operator-only live state as fixed.
- **Closed (code), open (ops)** stays out of the open debt count until production
  deploy or live GCP/App Store state is proven.
- Historical diligence reports are evidence, not the ledger. Reopen items here
  with dated proof when regressions land.
- Product decisions with compensating controls belong in
  [`RISK_REGISTER.md`](RISK_REGISTER.md), not in this register.