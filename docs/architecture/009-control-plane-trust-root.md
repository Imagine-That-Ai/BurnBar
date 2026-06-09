# ADR 009 — Control-plane trust root (remote-control hardening)

**Status:** Accepted · **Date:** 2026-06-09 · **Supersedes part of** [008-remote-control-engine](008-remote-control-engine.md)

## Context

OpenBurnBar lets a remote phone talk to AI agents on a user's Mac and screen-share /
remotely control it, end-to-end encrypted on libsignal. A security review of the
remote-control kill chain ("a malicious peer / compromised relay / Firestore tamper →
code execution on the Mac, or exfiltration of screen / keystrokes / data") found that the
libsignal E2EE protects the **data plane** but the **control-plane authorization** — *which*
key may drive the Mac — was anchored in **server-controlled state**, not in the verified
end-to-end identity:

- The phone-control signing key was fetched from a Firestore directory
  (`users/{uid}/iroh_pairing/{connId}/controllers/{peerNodeId}.publicKeyBase64`) and trusted
  on every fetch as long as the named escrow device was `trusted`. A malicious/compromised
  relay or Firestore — explicitly in scope for the E2EE threat model — could swap that key
  for an attacker-held key, yielding **unattended keystroke/mouse injection (→ RCE) and
  screen capture** with no out-of-band verification.
- The `peerNodeId` only commits to a **96-bit prefix** of the signing key
  (`PhoneControlSender.peerNodeId = "ios-phone-" + hex(pubkey[0..<12])`), so it is not a full
  cryptographic binding.
- A verified phone intent **bypassed AX deny-regions and per-action approval**, contradicting
  the documented invariant *"approval is the only ground truth; no silent auto-pilot."*
- Escrow-device trust elevation (`approveEscrowDeviceTrust`) shipped with key-fingerprint
  binding **disabled**, and the latent libsignal session transport used TOFU with no pinning.

The unifying flaw: **the Mac was not the authoritative root of trust for who may control it.**

## Decision

Make the **Mac** the authoritative root of trust, mirroring the existing
`HermesGatewayAgentKeyPinStore` and `SignalAtRestSealer` pinning models. Six changes (F1–F6);
F4's two halves are split across this remediation and the concurrent relay-sealing effort.

### F1 — Mac-side controller-key pinning (keystone)

`OpenBurnBarComputerUseCore/ControllerKeyPinStore` + `ControllerKeySafetyCode` (pure,
unit-tested; Keychain-backed via an injectable `ControllerKeyPinBacking` seam). On first
contact a controller's Ed25519 signing key is **pinned** to the Mac Keychain
(`WhenUnlockedThisDeviceOnly`). Every later admission compares the directory-advertised key
against the pin:

- a **matching** key is admitted (steady state);
- a **different** key is **refused** — a possible relay/Firestore key swap; the operator must
  deliberately re-pair (`clearPin`) to rotate;
- the **first** key, when `ControllerKeyPinEnforcementFlag` is enabled, requires an
  out-of-band **safety-number** comparison (Mac ↔ phone) before it is trusted.

Wired at the single chokepoint `PhoneControlAuthorityValidator.registerPeer(…, uid:)`, with
the `ComputerUseSessionCoordinator` and `AgentCapabilityGrantQueueListener` passing the uid;
both validators share one Keychain service so the pin is consistent.

**Rollout posture:** the key-*change* rejection is **always on** (it can only ever refuse a
key that differs from what the operator first saw, so it cannot brick a stable pairing). The
stricter first-use safety-number confirmation is gated behind
`ControllerKeyPinEnforcementFlag` (**default off**) pending the cross-platform safety-number
UI — mirroring `EscrowDeviceTrustSafetyCheckFlag`.

### F3 — Phone-lane gate hardening

`DefaultComputerUseCapabilityGate`: a verified phone intent is now subject to the same AX
**deny-region** protection as agent input (secure text fields, system auth sheets) — default
`phoneControlRespectsDenyRegions = true`. The narrow "drive my own locked login window" case
uses the dedicated **Remote Unlock** path; an operator can opt out via Remote Config
`computer_use_phone_control_respects_deny_regions = false`. A per-session **first-action
approval** mechanism is implemented and unit-tested (`phoneSessionFirstActionConfirmed`); it
is gated-off in production (`confirmed: true`) until the coordinator tracks per-session
confirmation and the approval UX is validated.

### F2 — Escrow-device trust binding (server)

`ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = true`: `approveEscrowDeviceTrust` now fails
closed when a device's stored `publicKeyFingerprint` does not match the SHA-256 of its
actually-published `escrow_public_keys` bytes — binding escrow trust to the real key. A
device with no key on file is a no-op (cannot brick), only an actual mismatch is refused.
This also hardens the first-device bootstrap (the self-approving device must present a
key-bound identity). Activate the native `EscrowDeviceTrustSafetyCheckFlag` in lockstep.

### F5 — At-rest sender-auth fail-closed classification

`OpenBurnBarSignalCoreError.allowsLegacyAtRestFallback(senderSetComplete:)`: a **present**
`CloudVaultSignalEnvelope` that fails sender authentication must not silently downgrade to
the unauthenticated legacy `sealedPayload`. Forged signatures, stripped sender blocks, and
relocated (binding-mismatched) envelopes fail closed; an unrecognized sender is legacy-
eligible only while the trusted-sender set is still resolving. Callers (Mac/Mobile
chokepoints and the in-flight Hermes sender-trust resolver) adopt this classifier.

### F6 — libsignal session-transport pinning (latent code)

`OBBSignalProtocolStore` gains an injectable `identityTrustEvaluator` that, when set, is the
sole authority for `isTrustedIdentity` (fail-closed against any unpinned key, covering both
the inbound and outbound paths). `OBBSignalSessionCipherTransport.establishOutbound` /
`OBBSignalRemoteBundleDecoder.decode` gain a `pinnedIdentityPublicKey` that rejects a swapped
bundle before any session state is created. The transport is currently unwired; production
wiring **must** supply the anchor. The protocol address is intentionally **not** re-keyed, to
keep the cross-platform interop KAT fixtures byte-compatible.

### F4 — relay/transport integrity

Two halves, both now addressed:

- **Confidentiality + authenticity (the high-severity half)** landed via the concurrent relay
  sealing effort (commit *"require authenticated command plane"*): legacy plaintext relay
  envelopes are rejected for Mac-dispatched control/agent operations, and sender-authenticated
  v3 sealing/opening is applied across WSS, Firestore, iroh, iOS, and Android — so a relay can
  no longer read the typed text / coordinates of a control intent.
- **Chunk integrity (this change).** Each `response.chunk` is AES-GCM sealed with its `sequence`
  bound into the AAD, so a relay cannot forge, modify, or re-sequence a chunk — but it could
  silently **drop** one, truncating the reassembled result. The new pure
  `ChunkReassemblyValidator` (`OpenBurnBarCore`) records each received sequence and, on
  `response.complete`, rejects a response missing any chunk `0..<chunkCount` (a no-op for
  streaming completions that declare no total). It is wired into both iOS client reassembly
  paths (`HermesIrohRelayTransport.send` and `HermesService.send`).

## Deferred

- **F4 — Android chunk-integrity parity.** The iOS clients now reject a truncated chunk stream;
  the Android client should adopt the same `chunkCount`-completeness check on its relay
  reassembly. Tracked as a follow-up.
- **F2 — cryptographic approver consent.** A distinct-device *signed* approval (proving the
  approver consented, not merely that a `trusted` doc exists) requires provisioning a per-
  device signing key on iOS/iPadOS/Android/macOS/Web — escrow devices today hold only P-256
  **key-agreement** keys. Tracked as a cross-platform key-distribution change.

## Verification

| Area | Tests | Command |
|---|---|---|
| F1 pin store + safety code | `ControllerKeyPinStoreTests` (11), `ControllerKeySafetyCodeTests` (5) | `swift test --filter ControllerKey` |
| F1 validator wiring | `PhoneControlAuthorityValidatorAttestationTests` (+2) | app test target (`scripts/test-openburnbar-app.sh`) |
| F3 gate | `ComputerUseCapabilityGateTests` (28, incl. new secure-default + approval) | `swift test --filter ComputerUseCapabilityGateTests` |
| F2 fingerprint | `escrowDeviceTrustFingerprint.test.ts` (13) | `npx vitest run src/__tests__/escrowDeviceTrustFingerprint.test.ts` |
| F5 fail-closed | `SignalAtRestFallbackPolicyTests` (3) | `swift test --filter SignalAtRestFallbackPolicyTests` |
| F6 identity pin | `OBBSignalIdentityPinTests` (4) | `swift test --filter OBBSignalIdentityPinTests` |
| F4 chunk integrity | `ChunkReassemblyValidatorTests` (7) | `swift test --filter ChunkReassemblyValidatorTests` |

All `OpenBurnBarComputerUseCore` (215), `OpenBurnBarSignalCore` (20), and
`OpenBurnBarSignalSessionTransport` (3) tests pass. The app-target (AgentLens / OpenBurnBar)
build + the Remote-Unlock regression must be confirmed via
`scripts/test-openburnbar-app.sh` before merge (F1/F3 app wiring is not compiled headlessly).

## Consequences

- A relay/Firestore compromise can no longer install a controller key the Mac will honor:
  the pin rejects any key the operator did not approve out-of-band.
- A remote controller can no longer silently type into a password field.
- Escrow-device trust is bound to the device's real key.
- Operators whose controller key legitimately rotates (app reinstall) must re-pair once — the
  correct, secure behavior for a key change.
