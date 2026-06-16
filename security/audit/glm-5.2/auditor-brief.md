# Auditor Brief — External Security Review Package

## Scope

**Product:** OpenBurnBar — cross-platform AI agent observability and control platform
**Repository:** `/Users/albertonunez/Documents/Developer/BurnBar`
**Commit:** `60faa70227` on `security/run-09-privacy-invariants-hardening`
**Previous audit:** 9-model run (2026-06-14), 40 root-cause findings, 27 fixed

## Architecture Summary

- **macOS app** (SwiftUI) + **daemon** (privileged, SQLCipher) + **iOS/Android** companions
- **Cloud Functions** (TypeScript, Firebase v2) with ~75 callable endpoints
- **CloudVault** E2E encryption (AES-256-GCM, path-bound AAD, vault key in Keychain)
- **Computer Use** agent control (Virtual HID, three trust modes, SHA-256 audit chain, capability tokens)
- **Hermes** real-time communication (iroh P2P, encrypted)
- **Payments** (Stripe, Apple App Store, Google Play)

## Areas Where Adversarial Review Is Desired

### 1. Computer Use Trust Boundary (Highest Priority)
- Kill-switch watchdog socket authentication (FINDING-001)
- Local-auth-proof verifier dormancy (FINDING-002)
- Phone trust mode UI downgrade enforcement (FINDING-003)
- Capability token binding at HID boundary
- Audit chain tamper detection with signed terminal head

### 2. CloudVault Cryptography
- Path-bound AAD coverage gaps (chat_threads, cli_sessions — FINDING-008)
- Vault key rotation and revocation completeness
- First-vault creation server mediation (FINDING-004)

### 3. Firestore Rules Completeness
- Session log allowlist effectiveness
- Path-bound sealed payload enforcement
- Cross-tenant isolation (BOLA test coverage)

### 4. Hermes Gateway and iroh Pairing
- Envelope PoP verification
- First-contact safety-number (FINDING-005)
- Relay operator threat model

### 5. Supply Chain Integrity
- Release pipeline (code signing, notarization, SBOM, SLSA)
- Dependency confusion and provenance

## Setup Instructions

1. Clone repository
2. `cd functions && npm install`
3. `cd firestore-rules-tests && npm install`
4. For Cloud Functions tests: `npm run test:security`
5. For Firestore rules tests: `npm run test:ci`
6. For daemon tests: `swift test --package-path OpenBurnBarDaemon`
7. For core crypto tests: `swift test --package-path OpenBurnBarCore --filter CapabilityTokenVerifier`

## Test Accounts Needed

- Firebase Auth test user (email + password)
- Stripe test mode customer
- Apple App Store Sandbox tester

## Key Flows to Trace

1. CloudVault write: `CloudVaultCrypto.sealBlob` -> Firestore `validPathBoundSealedPayloadForUser`
2. High-risk callable: `enforceHighRiskComputerUseCallableWithNonce` -> nonce consume -> attestation verify
3. HID dispatch: `PrivilegedInputDispatchHandler.handle` -> kill switch check -> `VirtualHIDBridgeCapabilityGate.validate`
4. Account deletion: `eraseUserCloudData` -> KMS destroy -> subtree delete -> Storage purge -> Auth delete

## Known Issues (Not Hidden)

All findings in `findings.md` are documented and tracked. The product team is aware of all open findings. No issues are being concealed from reviewers.

## Open Questions for Auditors

1. Is the kill-switch watchdog socket (root-only, no peer auth) acceptable as a defense-in-depth layer, given three other independent panic paths?
2. Is the local-auth-proof verifier dormancy acceptable pre-launch, given peer codesig + capability tokens are active?
3. Is the CloudVault path-bound AAD partial coverage acceptable, given the remaining surfaces (chat_threads, cli_sessions) are same-user-bound?
4. Is the App Check 30-day attestation max-age reasonable for this threat model?
