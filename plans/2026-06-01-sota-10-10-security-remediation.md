# SOTA 10/10 security remediation (2026-06-01)

Implementation tracker for the June 2026 security swarm + [`2026-05-30-sota-security-remediation.md`](2026-05-30-sota-security-remediation.md).

## Phase 0 — Emergency (48h) — shipped in tree

| Item | Status | Notes |
|------|--------|-------|
| Global Google Play token claims | Done | `functions/src/callables/googlePlayTokenClaims.ts`, wired in `stripe.ts`, rules deny client access |
| Public HTTP rate limits | Done | `functions/src/callables/publicRateLimit.ts` — CLI link start, Hermes gateway device start, approval failure lockouts |
| VoIP device-only fan-out | Done | `functions/src/voipPush.ts` + `callables/voipPush.ts` require `pairedDeviceId`; iOS persists `voipDeviceToken` on device doc |
| Pairing freshness 180s | Done | `IROH_PAIRING_FRESHNESS_MS`, Android `IrohPairingFreshness`, `docs/HERMES_IROH_TRANSPORT.md` |

## Phase 1 — Iroh inbound binding

| Item | Status | Notes |
|------|--------|-------|
| Remote peer id in Rust FFI | Done | `crates/openburnbar-iroh` — `IrohStream.remote_node_id()`; rebuild `Vendor/OpenBurnBarIroh.xcframework` before release |
| Mac allowlist policy | Done | `IrohInboundPeerPolicy`, `FirestoreIrohInboundPeerAllowlist`, `HermesIrohRelayHostClient` reject + audit |
| Mobile publishes `irohPeerNodeId` | Done | `HermesIrohRelayTransport.persistIrohPeerNodeId` |

## Phase 2 — Privileged / Computer Use

| Item | Status | Notes |
|------|--------|-------|
| App Check launch gate | Done | `scripts/commercial-launch-gate.mjs` + `evaluate-firebase-app-check-enforcement.mjs` |
| Privileged socket red-team | Ops script | `scripts/ops/run-privileged-socket-redteam.sh` + `PrivilegedSocketRedTeamIntegrationTests` |
| WS1–WS6 leaf tokens | Done (core) | `PrivilegedPeerAuthenticator`, `VirtualHIDBridgeCapabilityGate`, capability tokens |
| Phone attestation binding | Done | `AppCheckAttestationBinding` + Mac/iOS readers + envelope digest on send |

## Phase 3 — AI agency

| Item | Status | Notes |
|------|--------|-------|
| Mac desktop grant LocalAuthentication | Done | `DesktopGrantLocalAuthenticator` + `ChatDesktopControlButton` |
| RAG untrusted delimiters | Done | `OpenBurnBarChatEvidenceFormatting` + `LLMSafeContent` |

## Phase 4 — Supply chain

| Item | Status | Notes |
|------|--------|-------|
| OSV scanner | Done | `.github/workflows/security-pr.yml` |
| cargo-deny | Done | `fast-feedback.yml` `rust-deny-fast` + `run-ecosystem-deny-checks.sh` |
| SLSA binary attestations | Done | `release.yml` cosign attest DMG + ZIP + SBOM/VEX/checksums |

## Phase 5 — Trust

| Item | Status | Notes |
|------|--------|-------|
| security.txt | Done | `website/public/.well-known/security.txt` |
| Detection matrix | Done | `docs/security/DETECTION_MATRIX.md` |
| Signoff doc | Done | `docs/security/SOTA_10_10_SIGNOFF.md` (awaiting signatures) |

## Verification

```bash
cd functions && npm test -- --run src/__tests__/googlePlayTokenClaims.test.ts src/__tests__/publicRateLimit.test.ts src/__tests__/irohPairingFreshness.test.ts
cd crates/openburnbar-iroh && cargo check
# Rebuild iroh xcframework before shipping peer binding to production Mac builds
```