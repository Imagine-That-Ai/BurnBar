# SOTA 10/10 security signoff checklist

Use this checklist before marketing or investor diligence claims **“SOTA security.”** Each row must be green or explicitly waived with owner sign-off.

## Phase 0 — Cloud emergency

- [x] Global `google_play_token_claims` registry
- [x] Public HTTP rate limits (CLI link, Hermes gateway device start, approval lockouts)
- [x] VoIP fan-out from paired device doc only
- [x] Iroh pairing freshness 180s (iOS/Android/TS/docs)

## Phase 1 — Iroh transport

- [x] Rust `remote_node_id` on accepted streams (`cargo check` in `crates/openburnbar-iroh`)
- [x] **Release:** Rebuild `Vendor/OpenBurnBarIroh.xcframework` from updated crate (verify via `scripts/ci/verify-iroh-remote-node-id-binding.sh`)
- [x] Mac inbound peer allowlist + audit reject
- [x] Mobile publishes `irohPeerNodeId` on device doc

## Phase 2 — Privileged input / Computer Use

- [x] `PrivilegedPeerAuthenticator` on VirtualHID + RemoteAccessAgent sockets
- [x] `VirtualHIDBridgeCapabilityGate` unit tests
- [x] Phone control 300s authority TTL + optional attestation digest binding
- [x] Mac desktop grant requires LocalAuthentication for high-risk presets
- [x] Server-enforced local-auth proof for high-risk queued grants and autonomous Hermes Gateway elevation
- [x] Hermes Gateway proof-of-possession tokens with nonce replay defense and 24h access-token TTL
- [x] Client-verifiable CloudVault trusted-device chain before Mac, iOS, or Android wraps vault keys
- [x] CloudVault rotation callable plus client-side document, Storage-blob, and hosted-search-index rewrap workers
- [x] **Ops:** Privileged socket red-team on RC ([`docs/runbooks/privileged-socket-redteam-rc.md`](../runbooks/privileged-socket-redteam-rc.md) → `launch-evidence/privileged-redteam-rc-20260602T003648Z.txt`, probe rejected + `PrivilegedSocketRedTeamIntegrationTests` passed)
- [ ] **Ops:** Enable `computer_use_phone_control_attestation_required` per rollout ring after RC validation

## Phase 3 — AI agency

- [x] RAG / transcript `<UNTRUSTED_CONTENT>` wrappers (`PromptInjectionHardeningTests`)
- [x] Mac `grantDesktopControl` LocalAuthentication parity with mobile

## Phase 4 — Supply chain

- [x] OSV scanner in `security-pr.yml`
- [x] `run-ecosystem-deny-checks.sh` (npm audit + optional `cargo-deny`)
- [x] Cosign attest SBOM, VEX, checksums, **DMG, ZIP** in `release.yml`
- [ ] **Ops:** Verify cosign attestations on published release artifacts in GitHub attestations UI

## Phase 5 — Trust & launch

- [x] `website/public/.well-known/security.txt`
- [x] [`DETECTION_MATRIX.md`](DETECTION_MATRIX.md)
- [x] Automated App Check probe in `commercial-launch-gate.mjs`
- [ ] Owner + security reviewer signatures (below)

## Signatures

| Role | Name | Date | Notes |
|------|------|------|-------|
| Engineering owner | | | |
| Security reviewer | | | |

**Waivers** (if any): document ID, rationale, expiry, and compensating control in the PR that ships the waiver.
