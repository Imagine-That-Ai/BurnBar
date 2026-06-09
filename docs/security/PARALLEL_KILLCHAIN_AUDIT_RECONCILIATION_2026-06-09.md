# Parallel kill-chain audit — reconciliation with the coordinated remediation (2026-06-09)

An independent offensive review traced ONE kill-chain end-to-end —
*malicious peer/server/relay connects → code executes on the victim Mac, or
screen/keystrokes/data are exfiltrated* — and began a parallel remediation
before discovering the in-flight coordinated work in
[`SECURITY_REMEDIATION_2026-06-09.md`](SECURITY_REMEDIATION_2026-06-09.md).

Per the owner's call, the parallel work was reconciled against the coordinated
pre-beta remediation branch. The net-new fixes that survived reconciliation are:
**B1** server-side trust-chain signature verification, **A1/A2** Swift broker
approval + sandbox hardening, and **C3** persisted phone-control replay
counters. This memo records the mapping so nothing is lost and no one re-does
it.

## Mapping (parallel finding → coordinated item → disposition)

| Parallel finding | Their item | Disposition |
|---|---|---|
| **B1** — `approveEscrowDeviceTrust` never cryptographically verified the device-trust-chain signature (stored it verbatim) | adjacent to **C-2** (escrow trust); their C-2 design is *client-side verify-before-wrap* + fingerprint backstop, and does **not** include server-side signature verification | **KEPT — committed** (`8a673cbc2`). See details below. |
| **A1/A2** — Swift `AgentToolBroker` shell tool: no per-action approval + weak `(allow default)` sandbox | **C-4** (agent command-guard, fail-closed) | **KEPT — committed** (`8a673cbc2`, tightened by `addc96311`). Privileged broker tools now fail closed without a per-action approver, and the restricted shell denies network, credential-store reads, and out-of-workspace writes with canonical Seatbelt paths. |
| **B3** — live relay-request plane trusts server `trustState` instead of a device-rooted chain | **C-1 / H-2 / F1–F6** (authenticated+pinned relay, Signal-identity gate, Mac-rooted trust) | **REVERTED** as duplicative of the trust-root work. See residual-gap note. |
| **C1** — at-rest readers swallow sender-auth failures and fall through to the unauthenticated legacy opener | F5-adjacent (sender-auth downgrade) | Swept into `8a673cbc2` (3 readers now consult `SignalAtRestFallbackPolicy`, fail-closed on `.senderAuthMissing/.senderSignatureInvalid/.bindingMismatch` + wrapper `signalBindingMismatch`). Owner: confirm desired. |
| **A4** — `InsightMissionApprovalPolicy` `default:` returned `false` (fail-open direction) | — | Swept into `8a673cbc2`; `default:` now returns `true` (fail-closed) + 7 tests pass. |
| **C3** — phone-control replay counter in-memory only (replayable after daemon restart) | **C-3** | **KEPT — committed** (`addc96311`). `PhoneControlReplayCounterStore` persists per-peer high-water marks with 0600 permissions and fail-closed validation on persistence failure. |
| **D1** — chunk-drop silent truncation on Firestore-fallback + Android | **F4** | Already committed (`2dff9416c`) for iOS realtime; Firestore-fallback + Android parity is their tracked follow-up. |
| **A3** — local-auth "proof" is self-signed by the controller key (no independent 2nd factor) | defense-in-depth once **B1+C-1+F1-F6** close the entry path | Not implemented (needs a Secure-Enclave-distinct key + Mac challenge-nonce + cross-platform wire change + on-device test). Design below. |

## KEPT — B1 (details for the C-2 / `computerUseSecurity.ts` owner)

**This edited your hot file `functions/src/callables/computerUseSecurity.ts`; it
is now in HEAD (`8a673cbc2`). Coordinate before rebasing C-2 onto it.**

- Added a pure `node:crypto` **XEdDSA (XEd25519 over Curve25519)** verifier
  (`verifyXEdDSACurve25519Signature`) mirroring vendored libsignal
  `curve25519::PrivateKey::verify_signature` — the trust-chain signature is
  libsignal XEdDSA over a 33-byte DJB key (`0x05‖X`), **not** plain Ed25519, so
  the existing `verifyEd25519RawSignature` could not be reused (a naive reuse
  would have fail-closed-rejected every legitimate approval).
- `buildCloudVaultDeviceTrustChainCanonicalBytes` reconstructs the exact bytes
  the client signs (`CloudVaultDeviceTrustChain.canonicalPayload`: domain line +
  nine length-prefixed `{utf8ByteCount}:{segment}\n` pairs); 5 fields from
  authoritative server context, 4 from the validated proof.
- `verifyCloudVaultDeviceTrustChainSignature` loads the approver's published
  `publicKeyData` from the already-fetched (immutable, attacker-uncontrolled)
  `signal_identity_public_keys` doc — never from the proof. Wired **after** the
  approver-identity checks and **before** `transaction.set`, fail-closed
  `permission-denied` on any decode/curve/verify failure. Bootstrap self-approval
  verifies against the device's own published key.
- **B2 (bonus):** bootstrap self-approval now hard-requires a single-use
  high-risk nonce when `enforceAppCheck` (prod), independent of the global
  `requireHighRiskNonce` flag (`appCheckAttestation.ts` now returns
  `{ nonceConsumed }`).
- **Tests (committed):** `escrowDeviceTrustChainSignature.test.ts` (KATs from
  *real vendored libsignal*, both sign-bit cases),
  `approveEscrowDeviceTrustHandler.test.ts`, `appCheckAttestation.test.ts`.
  407 vitest pass (403/4-skip), tsc clean, firestore-rules emulator 52/52.
- **Relationship to C-2:** complementary, not a substitute. B1 stops the
  *server* from rubber-stamping an unverified chain; C-2's client-side
  verify-before-wrap stops a *compromised backend* from harvesting the vault
  key. Land both.

## RESOLVED AND RESIDUAL

1. **Swift `AgentToolBroker` shell surface (A1/A2) is resolved.**
   `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift` now
   gates `shell_run`, `workspace_write_file`, and `desktop_export_file` behind
   explicit per-action approval unless the grant is already trusted. The
   restricted shell profile denies network, denies reads from high-value
   credential/private-data stores (`~/.ssh`, Keychains, Messages, browser
   profiles, cloud CLIs, etc.), and confines writes to the workspace. The profile
   canonicalizes workspace/home paths before emitting Seatbelt rules so `/var`
   versus `/private/var` cannot punch holes in the boundary. Proof:
   `CLIBridgeTests` executes the profile with `sandbox-exec`; 85 tests pass.

2. **Phone-control replay persistence (C3) is resolved.**
   `PhoneControlAuthorityValidator` restores persisted counters on init,
   never clears high-water marks on peer deregistration/revocation, and commits
   each accepted counter through `PhoneControlReplayCounterStore`. If the store
   cannot persist the new high-water mark, validation fails closed with
   `replay_counter_persistence_failed`. Proof:
   `PhoneControlAuthorityValidatorAttestationTests` rejects a captured envelope
   after validator restart and verifies max-merge rollback resistance; 17 tests
   pass.

3. **Live relay-request plane device-rooted trust (B3) remains a tracked residual.**
   `FirestoreHermesRelaySenderTrustResolver.fetchTrustedSenderRecord` still gates
   on the server-asserted `escrow_devices.trustState == "trusted"` (+ HPKE-Auth
   to a server-served key) and does **not** run the device-rooted
   `CloudVaultTrustedDeviceChainVerifier` the at-rest path uses. If C-1/H-2/F1-F6
   already bind this resolver's trust to a Mac-rooted chain, this is closed;
   **confirm the resolver specifically is covered**, otherwise a full
   Admin-SDK-`trustState` forge still reaches the live remote-control plane.
   (Reverted approach: re-verify the sender's chain against the Mac's local
   Signal identity and bind the relay record's `signalIdentityKeyId`/fingerprint
   to the chain-verified device, fail-closed.)

4. **A3 (self-signed local-auth proof) — design, not implemented.** The
   "biometric" local-auth proof is verified only against the controller's *own*
   pinned key (`PhoneControlAuthorityValidator.validateLocalAuthProofIfNeeded`),
   so a device holding a trusted controller key can mint its own proof. Now
   defense-in-depth (B1 + C-1/F1-F6 close the entry path). SOTA fix: a
   Secure-Enclave key provably distinct from the transport/controller key,
   provisioned behind biometry, pinned at enrollment, signing a fresh
   Mac-issued challenge nonce (single-use). Cross-platform wire change (iOS +
   Android `HermesRealtimeRelayAgentGrantLocalAuthProof`) + on-device test.

## The kill-chain (for reference)

Entry (enroll/impersonate a device → live control) is closed by **B1**
(server verifies the chain) + **C-1/C-2/H-2/F1-F6** (authenticated relay +
Mac-rooted trust), with B3 retained above as the live-resolver confirmation
point. Escalation (peer message → code execution) is reduced by **C-4** (Python
guard) plus the Swift broker's A1/A2 approval and sandbox hardening. The
remaining high-value follow-through is to make the live relay resolver verify
the same device-rooted chain the at-rest CloudVault paths use, then replace the
controller-self-signed local-auth proof with a distinct hardware-backed
user-presence key.
