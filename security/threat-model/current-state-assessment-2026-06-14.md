# BurnBar / OpenBurnBar — Current-State Security Assessment

> **CONFIDENTIAL — Cure53 audit-prep material.** Internal security working document. Do not distribute outside the audit engagement. Conservative, evidence-backed, repo-only verification.

**This document supersedes `current-state-addendum.md`.** Where the addendum and this assessment disagree, this assessment governs; several addendum claims were re-checked and found to describe controls that are **not present at the audited HEAD** (see §6, "Documentation drift").

---

## 0. Branch-state reconciliation — READ FIRST

**The biggest finding of this pass is not a single code bug; it is that BurnBar's security remediation is fragmented across divergent branches, and the branch audited here contains only a slice of it.** This is verified git topology, not inference:

| Fact | Evidence |
|---|---|
| HEAD audited | `f70565fcfb` on `security/iroh-host-key-pin-ttrn01` — a narrow branch whose principal security delta is the iroh host-key pin. |
| The 06-13 package + addendum were authored against | `remediation/tech-debt-fable-2026-06-12` (dirty worktree at `6eb8340d1`) — a **different** line of history; `6eb8340d1` is **not an ancestor of HEAD**. |
| The two branches have diverged | `git rev-list --left-right --count HEAD...remediation/tech-debt-fable-2026-06-12` → **1669 HEAD-only / 1664 remediation-only** commits. |
| Controls the package documents as landed that are **present on `remediation/…` but ABSENT at this HEAD** (verified with `git cat-file -e HEAD:<path>`) | `AgentLens/Services/CLIBridge/AgentSecurityPolicy.swift` (the T-TOOL-02 / T-AI-07 dangerous-autonomy gate), `OpenBurnBarMobile/Services/HermesGatewayVersionFloorStore.swift`, `OpenBurnBarMobile/Services/Hermes/HermesTransportFallbackGuard.swift`, `OpenBurnBarMobile/Services/IrohRelay/IrohPairingAdmissionStore.swift`, `OpenBurnBarMobile/Services/Media/MercuryManifestMAC.swift`, plus the addendum's "second CODEOWNER", push-minimization, and avatar owner-read edits. |

**Consequence.** The "74 Open" rollup in §3 is accurate **for this checkout** but **understates** the union of remediation work that exists elsewhere in the repo; conversely the prior package **overstates** what is true on any single shippable branch. Before a Cure53 engagement, converge on **one** auditable branch (ideally `main` after merge) and re-run this verification against it — auditing a fragmented worktree produces contradictory findings. **This is the #1 fix-first item**, ahead of any individual threat.

---

## 1. Snapshot

| Field | Value |
|---|---|
| As of | 2026-06-14 |
| HEAD | `f70565fcfb` (full: `f70565fcfbf3850636dc8b4e73ff599f5346864f`) |
| Branch | `security/iroh-host-key-pin-ttrn01` |
| Baseline (prior code-verified pass) | `5416ef780` |
| Scope of delta | 187 files changed, **+10,655 / -692** |
| Verification basis | **Repo source at HEAD only.** Deployed/live state (Firebase IAM, KMS, App Check console enforcement, Remote Config values, branch protection, store-release config, deployed Functions revisions, Firestore TTL indexes, live APNs/FCM payloads, deployed launchd job) is **Unverifiable** from the repo and is marked as such. |

**Reading note.** "Source of truth = current code at HEAD." Statements about controls are backed by `path:line — what it shows` citations. Anything depending on runtime/console/deployed configuration is explicitly flagged **Unverifiable**. We prefer "we do not currently guarantee this" over an unsupported claim.

**Headline.** Real, load-bearing progress landed since baseline on three fronts: (1) a new fail-closed iroh **host-key pin** (T-TRN-01/T-PTR-03), (2) a new fail-closed daemon **main-socket peer code-signature gate** (RR-3 / T-DMN-01/03/05), and (3) substantially **hardened supply-chain CI** (SHA-pinned actions + enforcing pin-verify gate, broader OSV/cosign attestation). At the same time, the most dangerous standing items — **YOLO/unsandboxed-shell RCE (T-TOOL-02, Critical)**, **client crash-report PII to Sentry (T-PRV-03)**, **push-queue retention/erasure gaps (T-PRV-01/02)**, and **at-rest key extractability (T-CVS-03 / T-IOS-09 / T-AND-01)** — are **unchanged**. A separate, material concern surfaced this pass: **committed cloud security-evidence JSON leaks IAM/PII/Secret-Manager recon data** (new, High, §6).

---

## 2. Executive scorecard

| Domain | Current posture (1 line) | Trend vs baseline |
|---|---|---|
| **Transport / Pairing** | Post-pairing iroh key substitution now closed by a fail-closed Keychain host-key pin (iOS); first-contact TOFU still default-off and Android has no pin. | **Improved** |
| **Agentic / Tools** | Default Manual gate is fail-closed and robust; YOLO/unrestricted-shell remains a standing full-privilege RCE channel (Critical), revoke ≠ kill on the CLI lane. | **Unchanged** |
| **Daemon / Desktop** | New fail-closed main-socket first-party code-sign gate (RR-3) blocks non-first-party peers; daemon still unsandboxed, user-writable binary, one-directional app↔daemon auth. | **Improved** |
| **Crypto / Vault / Keys** | Sealing model intact and zero server-decrypt; vault/Signal/identity keys still software-extractable on an unlocked endpoint (no SE/biometry/StrongBox binding). | **Unchanged** |
| **Cloud-Authz / Gateway** | Object-level authz airtight at the rules layer; bearer+PoP enforced; endpoint-authz matrix + drift test added; Admin-SDK per-handler ownership still convention. | **Improved** |
| **Privacy / Telemetry** | Push payloads still leak cleartext caller identity + correlators; client crash reports still ship to Sentry with no scrubber/consent; no push-queue TTL/erasure. | **Unchanged** |
| **Supply-chain / CI** | Actions SHA-pinned with enforcing pin-verify gate; cosign attests as-shipped bytes; OSV broadened — but single CODEOWNER (no SoD) and SwiftPM advisory gap persist. | **Improved** |
| **Attachments / Media** | Mac receive gained capability gate + quarantine + at-rest seal (tested); iOS receive path has none, Mercury manifest still unauthenticated, oversize size-lie unbounded. | **Improved** |
| **iOS / Apple** | Vault + escrow keys decryptable on unlocked device; unlocked-device full access; App-Group/lock-screen leaks; no hardware key binding for at-rest. | **Unchanged** |
| **Android** | Vault/Signal/relay keys on weakest Keystore profile (no StrongBox/user-auth), even though F2 demonstrates the secure pattern in-tree for PhoneControl only; cleartext base-config persists. | **Unchanged** |

---

## 3. Threat status rollup

### 3.1 Counts by current status

| Status | Count |
|---|---|
| Open | 74 |
| Partial | 21 |
| Mitigated-in-code | 8 |
| Unverifiable | 2 |
| Fixed | 1 |
| **Total tracked** | **106** |

> Note: "Mitigated-in-code" and "Fixed" denote code-level remediation only; live enforcement of several still depends on deployed-state (rules, App Check, callable revisions) that is **Unverifiable** here.

### 3.2 All Critical / High threats

| ID | Title | Prior sev | Current status | Current sev | Key evidence | Residual risk |
|---|---|---|---|---|---|---|
| **T-TOOL-02** | YOLO emits `--dangerously-skip-permissions`, runs unsandboxed shell at full user privilege | Critical | **Open** | **Critical** | `CLIArgumentBuilder.swift:52-53,168-169,215-217`; `OpenAICompatibleChatGatewayClient.swift:367-393` (`runShellUnrestricted` runs `/bin/zsh -lc`, skips per-action approver by design); both files byte-identical to baseline; `AgentSecurityPolicy.swift` absent at HEAD | A prompt-injection obeyed under an active trusted/all-caps grant = arbitrary RCE at full user privilege; no per-N-action reauth; standing channel until expiry/revoke. |
| **T-TRN-01** | Cloud-substituted pairing public key MITMs the verified iroh link | Critical | **Partial** | **High** | `IrohHostKeyPinStore.swift:124-153` (always refuses differing key, fail-closed); `FirestoreIrohPairingPublicKeyProvider.swift:58-83`; `IrohHostKeyPinStoreTests.swift:61-75` (10 tests) | First-contact (cold-start, no pin) cloud MITM still succeeds: `IrohHostKeyPinEnforcementFlag.defaultEnabled=false` (`IrohHostKeyPinStore.swift:205`), no compare UI wired. Once pinned, substitution refused. |
| **T-PTR-03** | iOS host-pairing-key in-memory TOFU enables cloud-MITM dial redirection | High | **Partial** | **High** | `IrohHostKeyPinStore.swift:219-264` (Keychain `WhenUnlockedThisDeviceOnly`, survives restart); `FirestoreIrohPairingPublicKeyProvider.swift:11-19,57` | First-pin still TOFU with safety-number confirmation default-off; backend serving a swapped key to a never-pinned device accepted on first contact. |
| **T-TRN-02** | Cloud-controlled inbound allowlist admits attacker or locks out owner | High | **Open** | **High** | `FirestoreIrohInboundPeerAllowlist.swift:16-29` (cloud-authoritative); `HermesIrohRelayHostClient.swift:292-305`; `firestore.rules:2769-2774` (controllers Admin-SDK-only); claimed mobile `IrohPairingAdmissionStore` **does not exist at HEAD** | Compromised backend/Admin SDK can inject `controllers/{attackerNodeId}` (handler reachability) or delete docs (owner DoS); downstream E2E gates limit to reachability+DoS, not command injection. |
| **T-TRN-03** | Attacker-induced silent downgrade iroh→Firestore | High | **Open** | **High** | `HermesCompositeRelayTransport.swift:57-61,119-121` (only chat hard-fails; control-plane + CLI streams auto-fall-back); 0 diff vs baseline; claimed `HermesTransportFallbackGuard` **does not exist at HEAD** | On-path adversary cheaply forces the more-observable Firestore path; payload stays E2E-sealed (metadata exposure, not disclosure). No rate alarm. |
| **T-TOOL-03** | Grant revocation does not terminate in-flight CLI agent | High | **Open** | **High** | `ChatSessionController.swift:382-389` (revoke flips state, does not kill `Process`); `OpenAICompatibleChatGatewayClient.swift:130-135` (broker re-checks; external-CLI lane does not) | Long-running YOLO CLI run keeps dangerous flags to completion after revoke. |
| **T-TOOL-04** | Panic/kill coordinator compiled out of MAS build | High | **Open** | **High** | `ComputerUsePanicHaltCoordinator.swift:1` (`#if !DISTRIBUTION_MAS`); software/remote kill (`ComputerUseSessionCoordinator.swift:280-281`) persists | Degraded local emergency stop in shipped MAS build; remote/coordinator kill is the only path. (Residual itself is Medium; family-High.) |
| **T-TOOL-01** | External CLI agents run with no in-process policy gate | High | **Open** | **High** | `CLIArgumentBuilder.swift:29-178` (capability-derived flags only; no per-tool-call interposition); default-deny fallback at `:57-64` | Under workspace/all/YOLO, in-CLI behavior is a residual agency boundary BurnBar cannot enforce. |
| **T-TOOL-05** | CLI lane does not tag repo/tool/web content as untrusted | High | **Open** | **High** | `CLIArgumentBuilder.swift:248-264` (only chat turn wrapped); `CLIBridge.swift:100,…,612` | Poisoned file/tool output the CLI ingests can steer a write/shell-granted agent with no tagging/gate. |
| **T-AI-07** | Unrestricted shell obeys injected instructions under YOLO (injection→RCE) | High | **Open** | **High** | `OpenAICompatibleChatGatewayClient.swift:155,176-177,367-393` (approval skipped for trusted; audit-only); no `actionsSinceProof`/reauth anywhere at HEAD | Indirect injection chains into arbitrary local command execution; audit is attribution, not prevention. |
| **T-AI-01** | CU tool results outside 2-tool allowlist injected raw into model context | High | **Open** | **High** | `OpenAICompatibleChatGatewayClient.swift:529-532` (positive-list of 2 tools), `:1165-1169` (verbatim); daemon `:791-799` | Indirect injection via any non-allowlisted tool output chains into further tool calls, incl. shell under YOLO. |
| **T-AI-02** | Oracle "authoritative findings" inject unwrapped indexed snippets | High | **Open** | **High** | `ChatSessionController.swift:1609-1614` ("Treat … as authoritative"), `:2411-2418` (strips only 4 strings) | Instruction injection via parsed conversation history framed as authoritative; durable (corpus indexed from agent logs). |
| **T-DMN-01** | Compromised first-party app fully trusted by daemon (code-sign == authZ) | High | **Partial** | **High** | RR-3: `OpenBurnBarDaemonServer.swift:577-596` (`validatePeer` before any RPC, fail-closed); `BurnBarDaemonPeerAuthenticator.swift:62-112`; `OpenBurnBarDaemonMain.swift:85` (`enforced:true`); e2e test `BurnBarDaemonServerPeerAuthEnforcementTests.swift:13-40` | Gate stops non-first-party/swapped binary, but a compromised *signed* first-party app still passes the gate and gains full main-socket RPC; no capability attenuation, no daemon sandbox. |
| **T-DMN-02** | Daemon runs unsandboxed as login user with broad filesystem access | High | **Open** | **High** | `project.yml:246-262` (daemon has no entitlements / no hardened runtime, unlike helpers at `:264-301`); `OpenBurnBarDaemonManager+Lifecycle.swift:273-282`; `OpenBurnBarConfigStore.swift:608-612` | RPC parse/memory bug or foothold executes with no OS sandbox: full home dir, provider creds, sockets, HID lane. |
| **T-CVS-03** | Identity/vault private key extractable on compromised unlocked endpoint (no SE/biometry) | High | **Open** | **High** | `CloudVaultCrypto.swift:1426,1435` (`WhenUnlockedThisDeviceOnly`, no `kSecAttrAccessControl`); `CloudVaultCrypto.kt:1210-1218` (no user-auth/StrongBox); SE/biometry only on unrelated PhoneControl keys | Endpoint compromise → raw vault/identity key bytes → forge sender-auth + decrypt all at-rest; no hardware-bound signing, no PFS. |
| **T-PRV-01** | VoIP/call push leaks cleartext caller display name + call graph to Apple & Google | High | **Open** | **High** | `voipPush.ts:39-45,68-76` (cleartext `displayName`/`connectionId`/`pairedDeviceId`/`callId`); `apnsSender.ts:220,257,368`; 0 diff vs baseline | Every call exposes caller identity + stable device/connection correlators to two external sub-processors → social/device graph. |
| **T-PRV-02** | Push-queue root collections never deleted on account erase, no TTL | High | **Open** | **High** | `voipPush.ts:57,78` (top-level `voip_outbound`/`fcm_outbound`, no `expireAt`); `accountDeletion.ts:93-131` (no push paths); `firestore.indexes.json` (no TTL override for these) | Right-to-erasure violated for call/push metadata; identifying payloads persist indefinitely post-deletion. |
| **T-PRV-03** | Client crash reports (iOS+macOS) ship to Sentry with no scrubber/consent | High | **Open** | **High** | `OpenBurnBarMobile/App/AppDelegate.swift:60-79` & `AgentLensApp.swift:1176-1195` (no `beforeSend`/`beforeBreadcrumb`/`sendDefaultPii=false`; macOS seeds `NSFullUserName()`); server-side `sentry.ts:42,45,59` scrubs (asymmetry) | Breadcrumbs (URLs, lifecycle, logs) + exception context can carry plaintext prompts/paths/peer IDs/tokens to Sentry SaaS, no consent. |
| **T-SC-03** | Single CODEOWNER = no separation of duties / insider single point of compromise | High | **Open** | **High** | `.github/CODEOWNERS:4` (`* @Ajnunezg`), `:18`, `:21`; 0 diff vs baseline; addendum's "second CODEOWNER" claim **not present** | Compromise/coercion of one identity merges malicious workflow/rules/release with self-approval. |
| **T-IOS-02** | Unlocked-device full app access | — | **Open** | **High** | `AuthGateView.swift:88-97` | Unlocked iPhone = full access. |
| **T-IOS-09** | Vault + escrow key decryptable on iOS | — | **Open** | **High** | `CloudVaultCrypto.swift:1418-1428`; `iOSDeviceKeypair.swift:100-114` | Vault + escrow keys decryptable on a compromised/unlocked device. |
| **T-ATT-01** | Decompression/oversize exhaustion via lied-about Mercury `manifest.size` | High | **Open** | **High** | `crates/openburnbar-iroh/src/blobs.rs:258-284` (full blob exported, no ceiling, no actual-vs-advertised check); `MacFileTransferService.swift:391-395` (charges advertised size); GCS path enforces `observedByteCount===byteCount` but P2P path does not | Paired peer advertises 1 KB, commits multi-GB → disk-fill / quota exhaustion before any reject. No test covers size-lie. |
| **T-DMN-01 (doc-drift)** | Addendum claims dangerous-autonomy fix (`AgentSecurityPolicy.swift`) | — | **Open** (newly-flagged) | **High** | Cited file absent at HEAD *and* at the addendum's own commit `6eb8340d1` (not an ancestor of HEAD) | Audit-misleading: package wording claims T-TOOL-02/T-AI-07 mitigated when not present on this branch. |
| **New: committed cloud-evidence recon** | `firebase-security-evidence-latest.json` exposes IAM topology, owner PII, project number, Secret Manager name inventory | — | **Open** (new) | **High** | `security/evidence/firebase-security-evidence-latest.json:415,52`; project number ×204; full secret-name inventory; `collect-firebase-security-evidence.mjs:165-183` (redaction misses `members`/`email`/`name`); `.gitignore:197` (tracked by policy) | Complete recon map of the prod GCP project (owner Gmail, SA→role map, KMS key path, secret IDs leaking UIDs). Persists in git history regardless of repo visibility. |

> Other High/Critical context: T-AND-01 (Vault/Signal/relay keys recoverable on rooted/forensic device) is rated **Medium** in the register but is the clearest at-rest gap given F2 demonstrates the secure pattern in-tree; tracked in §6.

---

## 4. Claim matrix (updated)

| Cx | Claim (short) | Prior status | Current status | Safe wording (1 line) | Top caveat |
|---|---|---|---|---|---|
| **C1** | Cloud cannot read CURRENT Gateway message/event bodies | Defensible (Med) | **Defensible** (Med-High) | Current-version bodies are E2E-sealed on-device; the server validates envelope shape, holds no recipient private key, and never decrypts. | First-pairing key authenticity is TOFU via an authenticated approval channel; the safety-code compare is **advisory**, not a blocking gate. |
| **C2** | Cloud cannot read CloudVault at-rest content | Partially defensible (High) | **Partially defensible** (High) | Current content is client-sealed under a device-bound vault key; rules require sealed payloads; no Function decrypts vault content. | Admin SDK bypasses rules; legacy plaintext rows readable until the daily backfill converges (**Unverifiable** it has). |
| **C3** | Attachments sealed client-side; cloud can't read bytes/filenames | Partially defensible | **Partially defensible** (Med) | Current (schema-2+) attachments are sealed client-side; server stores opaque bytes, forces octet-stream, denies direct Storage SDK reads. | Sealing is client-enforced (cloud can't prove ciphertext); legacy plaintext Storage **objects** are not routinely purged. |
| **C4** | Bearer token alone insufficient — PoP of pinned key required | Defensible | **Defensible** (High) | Every active-access Gateway route additionally requires a per-request Ed25519 PoP over the pinned key, single-use nonce, fail-closed. | Scope: bearer-HTTP surface only; phone-inject lane uses Firebase auth, not bearer+PoP. Header forwarding by the deployed proxy is **Unverifiable**. |
| **C5** | Revoked device can't receive newly-sealed vault material | Partially defensible (High) | **Partially defensible** (High) | Revoke is atomic and records a rotation requirement; once a survivor completes rotation, new material is unreadable to the revoked device. | Rotation is client-driven (no server rotate), deferred; bounded window where revoked device's cached key still decrypts new writes; no survivor ⇒ no rotation. |
| **C6** | Untrusted content can't DIRECTLY trigger high-impact action without approval | Partially defensible (High) | **Partially defensible** (High) | In default Manual mode the gate is fail-closed; high-impact actions need explicit human approve/reject. | Trusted mode auto-dispatches scope-allowed actions; Step-mode burst covers up to 9 identical actions/30 s; no re-approve-on-new-domain control. |
| **C7** | High-risk grants need single-use local-auth proof bound to op hash | Partially defensible (Med) | **Partially defensible** (Med) | For ed25519 controllers, high-risk grants require a single-use proof bound to the canonical request hash, replay-protected both sides. | SE-P256 controllers are **exempt** on-device; live-relay grants validate on-device only (bypass cloud proof); SE custody class is self-declared, not attested. |
| **C8** | Only pinned paired devices exchange Gateway msgs | Partially defensible (Med) | **Partially defensible** (Med) | The host accepts only v3 HPKE-Auth requests sealed by the pinned, Signal-verified sender key; a forwarding relay can't forge/replay. | Host-side relay trust is resolved from **admin-SDK-writable Firestore** with no local chain re-verify; parallel PiAgent relay lane has **no** pinned-sender auth. |
| **C9** | Iroh pairing records can't be spoofed/replayed | Partially defensible (Med) | **Partially defensible** (Med) | For an established pairing, records are Ed25519-signed, uid/NodeId-bound, freshness-checked, fail-closed; iOS now pins the host key. | Android has **no** host-key pin (cloud-MITM open); server never verifies the signature on publish; 3-min replay window, no per-dial nonce. |
| **C10** | Provider credentials not in Firestore plaintext — Secret Manager + KMS-wrapped DEKs | Defensible | **Defensible** (High) | Credentials are envelope-encrypted (AES-GCM under a KMS-wrapped DEK) into Secret Manager; Firestore stores only the version name + metadata. | **Not** E2E: the Function KMS-decrypts to plaintext in memory for quota refresh; local macOS daemon holds creds plaintext on-device. |
| **C11** | Object-level authz holds across users | Partially defensible (Med) | **Partially defensible** (Med-High) | Rules layer is airtight (every private read owner-gated, no fail-open); the new signed-URL callable clamps to the caller's namespace. | Admin SDK bypasses rules; ~40+ callables not exhaustively re-audited; `storage.rules:19` avatars cross-user readable. |
| **C12** | Old messages/pairing codes can't be replayed | Partially defensible (High) | **Partially defensible** (High) | Live in-transit replay defense is solid (monotonic counter + unique request-ID + single-use nonces). | At-rest envelopes bind location only (server can re-serve an old valid record = rollback); pairing record has a 3-min replay window. |
| **C13** | Logs/crash/push contain no plaintext bodies or secrets | Partially defensible (Med) | **Partially defensible** (Med) | Push carries a generic preview; gateway rejects plaintext bodies; server logs/crash scrub by allowlist. | Three **client** Sentry inits have no `beforeSend`/`beforeBreadcrumb`; free-form `Error` strings only pattern-scrubbed; VoIP push carries caller display name. |
| **C14** | BurnBar does NOT claim production Signal/libsignal E2E (honestly gated) | Defensible (High) | **Defensible** (High) | No domain carries the Signal sealing scheme; RC kill switch off; gateway prod Signal set empty; rules reject client `signalEnvelope` writes; CI parity job enforces the non-claim. | Deployed RC/env flags are **Unverifiable**, but flipping any single lever is inert without the absent registry scheme; floor stays AES-256-GCM (never plaintext). |

---

## 5. What's now FIXED / improved since baseline (the wins)

| Area | What landed | Evidence | Threat IDs |
|---|---|---|---|
| **iroh host-key pin (post-pairing MITM closed)** | Phone Keychain-pins the Mac host key on first use and **always** refuses a later differing key; fail-closed on Keychain read/write; 10 tests incl. the keystone `testMismatchedAdvertisedKeyIsAlwaysRefused`. | `IrohHostKeyPinStore.swift:124-153,219-264`; `FirestoreIrohPairingPublicKeyProvider.swift:58-83`; `IrohHostKeyPinStoreTests.swift:61-75` | T-TRN-01, T-PTR-03, C9 (iOS) |
| **Daemon main-socket peer code-sign gate (RR-3)** | A first-party code-signature check runs on the live control socket **before** any RPC is honored; fail-closed; production wires `enforced:true`; e2e test proves an unsigned peer with a valid bearer token is refused. | `OpenBurnBarDaemonServer.swift:577-596`; `BurnBarDaemonPeerAuthenticator.swift:62-112`; `OpenBurnBarDaemonMain.swift:85`; `BurnBarDaemonServerPeerAuthEnforcementTests.swift:13-40` | T-DMN-01, T-DMN-03, T-DMN-05 |
| **Supply-chain CI hardening** | All 133 `uses:` refs SHA-pinned across 33 workflows; **new** enforcing pin-verify gate (`verify-github-action-pins.mjs`, did not exist at baseline); cosign now attests **as-shipped** DMG/zip/source/appcast bytes (not just source SBOM); OSV lockfile coverage 2→8. | `verify-github-action-pins.mjs:25-27`; `workflow-lint.yml:45-46`; `release.yml:732-751`; `security-pr.yml:233-240` | T-SC-01 (→Mitigated), T-SC-08 (→Partial), T-SC-04 (→Partial) |
| **Endpoint authorization matrix + drift test** | Structural matrix enumerates ~110 callables with mandatory BOLA/ownership/AppCheck fields; CI drift test fails if any exported Function is missing. | `endpointAuthorizationMatrix.ts:129-246`; `endpointAuthorizationMatrix.test.ts:21-48` | T-AZ-05 (→Partial, improved) |
| **Gateway attachment download callable (owner-scoped)** | New `getHermesGatewayAttachmentDownloadUrl` derives uid server-side, clamps the signed object key to the caller's `users/{uid}/…` namespace, App-Check + auth gated. | `hermesGateway.ts:1607-1670` | C11 (closed the prior signed-URL scoping gap) |
| **Mac Mercury receive hardening (tested)** | Mac receive path gained capability gate + quarantine xattr + atomic AES-256-GCM at-rest seal (OBMFA1) under the session key, with tests covering both seal-with-key and no-key fall-through. | `MacFileTransferService.swift:391,420-422,523-543`; `MacFileTransferSecurityTests.swift:112-178` | T-ATT-06 (→Partial), T-ATT-01 partial (Mac quarantine) |
| **PhoneControl replay/lifetime hardening** | File-backed strictly-monotonic replay counter survives daemon restart (fail-closed on unreadable), persisted single-use proof IDs, authority lifetime tightened 300 s → 120 s. | `PhoneControlAuthorityValidator.swift:96-130` | C12 (in-transit), C7 |
| **Server-side ownership/sender-auth strengthening** | `publishRelaySenderKey` binds the relay key to a published, fingerprint-matched Signal identity; resolver re-checks Signal identity; `escrow_devices` update rule hardened to forbid introducing absent identity fields. | `computerUseSecurity.ts:1936-1948`; `HermesRelaySenderTrustResolver.swift:29-57`; `firestore.rules:3453-3479` | C8, T-CVS family |
| **Gateway plaintext floor permanently closed** | `gatewayPlaintextWriteAllowed()` and `isWithinGatewayGraceWindow()` hardcode `false`; current writes are sealed-only; scheduled daily sweep strips legacy plaintext. | `hermesGateway.ts:166-168,188-190`; `callables/hermesGateway.ts:413-455`; `privacyBackfill.ts:218-236` | C1, C2, C3 |

---

## 6. Newly-identified issues

| Title | Severity | Evidence | Note |
|---|---|---|---|
| **Committed Firebase/GCP security-evidence JSON leaks IAM topology, owner PII, project number, full Secret Manager name inventory** | **High** | `security/evidence/firebase-security-evidence-latest.json:415` (owner `user:alberto8793@gmail.com`/`roles/owner`), `:52` (gcloud account verbatim); project number `246956661961` ×204; full secret-name list (STRIPE_*, APNS_KEY_P8, ANDROID_KEYSTORE_*, OPENROUTER_API_KEY, REMOTE_MCP_TOKEN_HMAC_SECRET, per-user `obb-<UID>-…`); KMS path `projects/burnbar/.../credential-encryption-key`; `collect-firebase-security-evidence.mjs:165-183` (redaction misses `members`/`email`/`name`); `.gitignore:197` (tracked by deliberate policy) | High-grade cloud recon (no secret *values*, but owner Gmail for targeted phishing, SA→role map, secret IDs leaking Firebase UIDs, KMS key path). Persists in git history regardless of current repo visibility. **Stop tracking + purge history, or extend redaction to IAM members/emails/resource names.** |
| **Addendum over-claims dangerous-autonomy fix not present at HEAD** | **High** | Cited `AgentSecurityPolicy.swift`/tests absent at HEAD and at commit `6eb8340d1` (not an ancestor of HEAD); `CLIArgumentBuilder.swift`/`OpenAICompatibleChatGatewayClient.swift` 0 diff vs baseline | Audit-integrity defect: package claims T-TOOL-02/T-AI-07 mitigated when they are not on this branch. |
| **Documentation drift: T-TRN-02/03/05, T-CRY-01, T-AZ-01, T-GW-05, T-PRV-02/04/06, T-ATT-04/08 remediation files absent at HEAD** | **Medium** | `IrohPairingAdmissionStore.swift`, `HermesGatewayVersionFloorStore.swift`, `HermesTransportFallbackGuard.swift`, `MercuryManifestMAC.swift` all absent via `git ls-tree -r HEAD`; remediation commits `9947384fd7`/`c2877993f8`/`ff2359f490`/`6eb8340d1` are **not** ancestors of HEAD; `storage.rules`/`firestore.rules`/`logging.ts`/`agentNotifications.ts`/`voipPush.ts` are 0-diff vs baseline | A reviewer trusting the addendum would believe ~12 controls ship at HEAD; they live only on unmerged branches + stale DerivedData. **Reconcile docs to HEAD or re-land the controls before audit.** |
| **App↔daemon auth is one-directional (RR-3 not symmetric)** | **Medium** | `OpenBurnBarDaemonSocketClient.swift:1174-1184,1219` (app validates daemon by same-uid-readable bearer token only, no `SecCode`); `BurnBarDaemonPeerAuthenticator.swift:24-26` (docstring claims bidirectional) | A swapped same-uid daemon winning the KeepAlive race (T-DMN-03) can impersonate the daemon **to** the app and capture RPC (provider-cred writes, run dispatch). XPC privileged-input lane *is* bidirectional; main socket is not. |
| **Daemon opens shared SQLite DB in plaintext when no SQLCipher codec linked** | **Medium** | `BurnBarDaemonDatabaseCipher.swift:19-24,130-141,232-236` (no-op on stock-SQLite build); contrast app GRDB-SQLCipher fail-closes (`DatabaseEncryptionService.swift:340-352`) | Shared `openburnbar.sqlite` can be plaintext on disk whenever the daemon writes. Whether the shipped daemon links `SQLITE_HAS_CODEC` is **Unverifiable** from repo — probe the released binary. |
| **`cloud_vault_rotation_required` FCM payload sends stable vault-key id to Google in no-TTL/no-erase queue** | **Low** | `cloudVaultRotationResilience.ts:155-170` (top-level `fcm_outbound`, `current_vault_key_id`, no `expireAt`) | New post-baseline payload extends T-PRV-02/T-PRV-07 surface; fold into push-queue TTL + erase remediation; reconsider including the key id in cleartext. |
| **cosign attestations keyless with no verify-time identity/Rekor policy** | **Low** | `release.yml:732-751`, `supply-chain-provenance.yml:89-93` (`cosign attest --yes`, no `--certificate-identity`/`--certificate-oidc-issuer`) | Consumers can't pin which OIDC identity signed; provenance value depends on a verify policy not codified in-repo. |
| **Cursor nightly CI-repair feeds attacker-influenceable failure logs into an autonomous PR-opening agent** | **Low** | `cursor-nightly-ci-repair.yml:181,303-311,314-347` (concatenates `--log-failed` tail + posts to Cursor agent, autoCreatePR); workflow token read-only `:34-37` | New prompt-injection surface into a code-authoring agent; bounded by read-only token + non-merging PR + required checks/CODEOWNERS (deployed enforcement **Unverifiable**). |
| **PR-triggered vendored-agent-provenance job git-clones an arbitrary repo URL from the PR-modifiable manifest** | **Low** | `security-pr.yml` (`git clone "$repo"` where `repo` = `manifest.forkRepository`); `third_party/hermes-agent/manifest.json` (PR-editable string) | SSRF/arbitrary-fetch; impact bounded (read-only token, no secrets to forked PRs, hash-mismatch catches). Allowlist the host. |
| **`runShellUnrestricted` audit lacks injection-rate signal** | **Low** | `OpenAICompatibleChatGatewayClient.swift:155,382-387` (per-line audit only; approval bypassed for trusted) | A runaway injected shell loop appears only as N log lines; a per-run rate threshold feeding `updateKillSwitch` would convert attribution into detection. |
| **Host-key pin clear does not invalidate in-memory `PublicKeyCache`** | **Low** | `FirestoreIrohPairingPublicKeyProvider.swift:96-98,38-41,82` | Robustness only (cache can only hold a previously-pinned key); after re-pair the stale cache could delay adoption of the new key until relaunch. |
| **First-use safety-number confirmation default-off, no compare UI (residual of T-TRN-01/T-PTR-03)** | **Low** | `IrohHostKeyPinStore.swift:202-212`; `FirestoreIrohPairingPublicKeyProvider.swift:63-73` | Concrete residual: shipping config admits the first host key a malicious backend serves; `safetyCodeForConfirmation` plumbing exists but no UI consumes it. |
| **Cloud-vault/Signal/relay key custody not upgraded alongside F2 hardware-keystore work (Android)** | **Medium** | `PhoneControlSecureEnclaveKeystore.kt:121-124` (StrongBox + user-auth) vs `CloudVaultCrypto.kt:1210-1218` (none) | Inconsistency makes T-AND-01 more glaring: the secure pattern exists in-tree but was not applied to the higher-value vault/Signal/relay keys. |
| **`RemoteUnlockSavedCredentialStore.load()` blanket-catches `Throwable`** | **Low** | `RemoteUnlockSavedCredentialStore.kt:55-63` | Fail-safe for confidentiality but masks auth-required vs absent; no unit test pins behavior. |
| **Mercury inbox extension taken unsanitized from sender manifest** | **Low** | `MediaFileTransferService.swift:162-168,120-128` | Traversal neutralized by blobHash-derived basename, but sender fully controls on-disk extension (compounds T-ATT-04/05). |
| **`cosign … --type slsaprovenance \|\| cosign attest` silently degrades to untyped** | **Info** | `supply-chain-provenance.yml:89-92` | Provenance lane can pass while emitting a weaker untyped attestation. |
| **Task/addendum reference non-existent scripts/docs** | **Info** | `scripts/ci/verify-supply-chain-hardening.sh` absent; `.github/CODEOWNERS` is 22 lines/single owner (addendum cites `:29-58` second owner) | Prior docs overstate controls; verify against the tree. |
| **cargo-audit/cargo-deny ignore-list duplicated, drift-prone** | **Info** | `rust-sast.yml:95-98` vs `crates/openburnbar-iroh/deny.toml:8-18`; `burnbar-remote` has no `deny.toml` | Accepted-advisory boundary maintained by hand in two places; burnbar-remote never covered by cargo-deny. |

---

## 7. Top 10 current risks (ranked)

| # | ID | Why (1 line) |
|---|---|---|
| 1 | **T-TOOL-02** | Critical, unchanged: an active YOLO/trusted grant is a standing full-privilege RCE channel reachable by prompt injection; no per-action reauth, no sandbox (non-MAS). |
| 2 | **New — committed cloud-evidence JSON** | High: leaks complete prod-GCP recon (owner Gmail, SA→role map, KMS path, secret IDs leaking UIDs) into the repo and git history. |
| 3 | **T-PRV-03** | High: client crash reports ship to Sentry with no scrubber/consent and a real-name seed; breadcrumbs can carry prompts/tokens/peer IDs. |
| 4 | **T-CVS-03 / T-IOS-09 / T-AND-01** | High: vault/identity/Signal/relay keys are software-extractable on an unlocked/rooted endpoint (no SE/biometry/StrongBox) → decrypt all at-rest. |
| 5 | **T-PRV-01 / T-PRV-02** | High: every call leaks cleartext caller identity + stable correlators to Apple/Google, and push queues never expire/erase (right-to-erasure breach). |
| 6 | **T-TRN-01 / T-PTR-03 (first-contact)** | High: post-pairing MITM closed, but cold-start cloud-served host key is still admitted by default (gate off, no compare UI); Android has no pin at all. |
| 7 | **T-AI-01 / T-AI-02 / T-TOOL-05** | High: tool/oracle/CLI-ingested content is injected unwrapped or framed authoritative → indirect injection chains into further tool calls (incl. shell). |
| 8 | **T-TOOL-03** | High: grant revoke does not kill an in-flight CLI agent; a revoked YOLO run runs to completion with its dangerous flags. |
| 9 | **T-DMN-01 / T-DMN-02 (+ doc-drift)** | High: a compromised signed first-party app gains full main-socket RPC; the daemon is unsandboxed; addendum falsely claims the autonomy fix shipped. |
| 10 | **T-ATT-01** | High: Mercury size-lie disk-fill/quota exhaustion on the P2P path (no streaming ceiling, no actual-vs-advertised check); iOS receive entirely unhardened. |

---

## 8. Top 10 still-missing controls

| # | Missing control | Closes / reduces |
|---|---|---|
| 1 | **Per-N-action / fresh local-auth reauth at YOLO execution time** (re-check at flag emission and during long runs), plus a per-run shell-rate kill threshold. | T-TOOL-02, T-AI-07 |
| 2 | **Kill-on-revoke for the external CLI lane** (mid-run grant re-check that terminates the spawned `Process`). | T-TOOL-03 |
| 3 | **Client-side Sentry scrubber + consent gate** (`beforeSend`/`beforeBreadcrumb`/`sendDefaultPii=false`, drop screenshot/view-hierarchy/network-body breadcrumbs, remove macOS real-name seed) across all three client inits. | T-PRV-03, C13 |
| 4 | **Hardware-bound, non-extractable key custody for vault/Signal/identity/relay keys** (Secure Enclave / StrongBox + per-use auth) — the F2 pattern already exists in-tree. | T-CVS-03, T-IOS-09, T-AND-01 |
| 5 | **Push-payload minimization + queue TTL + account-erase enumeration of root push collections** (`voip_outbound`/`fcm_outbound`/rotation nudges). | T-PRV-01, T-PRV-02, T-PRV-07 |
| 6 | **First-contact host-key safety-number compare UI + default the enforcement flag ON; add the Android host-key pin.** | T-TRN-01, T-PTR-03, C9 |
| 7 | **Default-deny untrusted-content wrapping for ALL tool/oracle/CLI-ingested content** (replace the 2-tool allowlist; wrap the oracle snippet; tag CLI-lane repo/web/tool input). | T-AI-01, T-AI-02, T-TOOL-05 |
| 8 | **Local trust-chain re-verification on the relay receive path** (call the chain verifier instead of trusting admin-SDK-writable Firestore) + pinned-sender auth on the PiAgent relay lane. | T-TRN-02, C8 |
| 9 | **Daemon App Sandbox / hardened-runtime + entitlement minimization + per-op capability attenuation; symmetric app↔daemon code-sign validation.** | T-DMN-02, T-DMN-01, app↔daemon one-directional auth |
| 10 | **Mercury P2P streaming size ceiling + actual-vs-advertised size reject + iOS receive capability gate/quarantine/at-rest seal + manifest MAC.** | T-ATT-01, T-ATT-02, T-ATT-04, T-ATT-06 (iOS) |

---

## 9. Cure53-readiness verdict

### 9.1 Ready (defensible to share as-is, with caveats stated)

- **Cloud crypto / zero-decrypt narrative (C1, C2, C10, C14):** strong, test-backed, and honestly gated. C14 (the *non*-claim of Signal production E2E) is well-defended and CI-enforced.
- **Object-level authorization rules layer (C11):** airtight at the rules layer; the prior signed-URL scoping gap is closed.
- **Gateway bearer+PoP (C4) and PoP path/body/query/nonce binding (T-GW-03 Fixed):** code-level solid and test-backed.
- **Supply-chain action pinning (T-SC-01) and as-shipped cosign attestation (T-SC-08):** materially improved.

### 9.2 Not-ready (must fix or explicitly scope before audit)

- **Documentation integrity:** the package (addendum + REMEDIATION) claims **~12+ controls that do not exist at HEAD** (dangerous-autonomy fix, version-floor store, fallback guard, admission store, Mercury MAC, avatar owner-only read, gateway inert headers, event-query targeting, log-scrubber expansion, notification TTL). This is the single biggest blocker — an auditor handed the addendum will chase fixes that aren't on the branch. **Reconcile every claim to HEAD or re-land the branches first.**
- **Committed cloud-evidence recon leak (new High):** remove from tracking + purge history before any external party touches the repo.
- **Critical RCE (T-TOOL-02):** ship the reauth-cadence/sandbox mitigation (currently only on an unmerged branch) or document it as a known, accepted, opt-in-gated Critical with compensating controls.
- **Client telemetry PII (T-PRV-03) and push retention (T-PRV-01/02):** privacy-impactful and trivially demonstrable; expect Cure53 to flag.

### 9.3 Ordered "fix-first" list

1. **Reconcile the security package to HEAD** (remove/scope every unmerged-control claim; pin the exact commit each control lands on). *(Audit-integrity; do first.)*
2. **Purge `security/evidence/firebase-security-evidence-latest.json`** from tracking + git history; extend redaction.
3. **Land (or formally scope) the YOLO reauth/sandbox mitigation** (T-TOOL-02 / T-AI-07).
4. **Add client-side Sentry scrubber + consent** (T-PRV-03).
5. **Push-payload minimization + queue TTL + erase enumeration** (T-PRV-01/02/07).
6. **Kill-on-revoke for the CLI lane** (T-TOOL-03).
7. **First-contact host-key compare UI + default-on; Android host-key pin** (T-TRN-01/T-PTR-03).
8. **Default-deny untrusted-content wrapping across tool/oracle/CLI paths** (T-AI-01/02, T-TOOL-05).
9. **Relay-path local trust-chain re-verify; PiAgent pinned-sender auth** (T-TRN-02, C8).
10. **Daemon sandbox/entitlement minimization + symmetric app↔daemon auth** (T-DMN-02/01).

---

## 10. Deployed-state proof still owed (Unverifiable from repo)

These cannot be confirmed from source and must be evidenced out-of-band before the relevant claims are treated as live:

| # | Item | Bears on |
|---|---|---|
| 1 | **App Check console enforcement** ON for the Firestore/Storage SDK datapath (rules cannot attest this). | T-AZ-06, C1, C2, C11 |
| 2 | **Deployed Firestore ruleset + indexes** match HEAD (incl. TTL fieldOverrides for `pop_nonces`/`high_risk_nonces`/etc.). | C1–C3, C11, C12, T-GW-03 |
| 3 | **`backfillPrivacyPlaintextScheduled` actually deployed and converged** across all users (no legacy plaintext bodies/filenames/Storage objects remain). | C1, C2, C3 |
| 4 | **KMS / Secret Manager IAM** (who holds `cloudkms.cryptoKeyDecrypter` + `secretmanager.secretAccessor`; whether `KMS_KEY_NAME` is set). | C10 |
| 5 | **Remote Config / Functions env values** (`REQUIRE_HIGH_RISK_NONCE`, `ENFORCE_APP_CHECK`, `phoneControlRespectsDenyRegions`, `signal_at_rest_*_enabled`, gateway Signal-required mode). | C6, C7, C9, C12, C14 |
| 6 | **Branch protection** requiring the pin-verify gate as a *required* check on a protected branch, and code-owner review on sensitive paths. | T-SC-01, T-SC-03 |
| 7 | **Store/MAS release config** (whether the shipped daemon is first-party-signed/notarized; whether the daemon links `SQLITE_HAS_CODEC`; the deployed launchd job does not set `*_DISABLE_PEER_CODESIG`). | T-DMN-01/02/03/05, §6 SQLite |
| 8 | **Hosting→Cloud Run header forwarding** preserves the `x-openburnbar-pop-*` / `x-obb-pop-*` PoP headers intact. | C4 |
| 9 | **Deployed Functions revisions** match HEAD (callable ownership/PoP/AppCheck enforcement actually live). | C4, C11, T-AZ-05 |
| 10 | **Live APNs/FCM payloads + provider (Sentry/Crashlytics) retention/scrubbing**, and whether client `SENTRY_DSN` is set in release. | T-PRV-01/03, C13 |
| 11 | **Escrow-device platform attestation** (no DeviceCheck/App Attest/MDM proves an escrow device is a real Mac) and **Firebase Auth session revocation** on escrow revoke. | C5, C9 |

---

## 7. MDASH 2026-06-14 follow-up findings (from `mdash-security-scan-report-2026-06-14.md`)

A focused MDASH-style pass was run against the same HEAD after the baseline assessment. It confirms several prior risks and surfaces new launch blockers, cross-platform parity gaps, and rule-drift issues. All findings are persisted in `threat-status-2026-06-14.csv` as `MDASH-001` through `MDASH-038`.

### 7.1 New launch blockers (P0)

| ID | Title | Why it blocks | Evidence |
|---|---|---|---|
| MDASH-001 | Panic kill switch not wired to root watchdog | User app cannot write `/var/run`; Virtual HID continues after panic | `ComputerUseSessionCoordinator.swift:554-556`, `PrivilegedInputKillSwitch.swift:8,23-30`, kill-switch watchdog exists but unused |
| MDASH-002 | Remote Unlock nonce ledger at `/var/run` | User LaunchAgent cannot write it → all Remote Unlock tokens rejected | `RemoteUnlockSetupProbe.swift:29`, `CapabilityTokenVerifier.swift:66` |
| MDASH-003 | Remote Unlock issuer trust at `/Library/Application Support` | User app cannot write it → leaf verifier has no issuer key | `RemoteUnlockSetupProbe.swift:26-27`, `RemoteUnlockCapabilitySigningKeyStore.swift:35-42` |

### 7.2 New / sharpened High risks (P1)

| ID | Title | Threat family | Key issue |
|---|---|---|---|
| MDASH-004 | Trust/data-destructive callables lack high-risk Computer Use guard | T-AZ / T-TOOL | `approveHermesGatewayDeviceGrant`, provider connect/update, `exportUserData`, `deleteUserCloudData`, `revokeAllAccess`, `revokeRemoteMcpClient` use only `enforceAuthAndAppCheck` |
| MDASH-005 | Android iroh host-key pinning missing | T-TRN/T-AND | Reopens T-TRN-01 on Android; no `Source.SERVER` fetch |
| MDASH-006 | CloudVault AAD not path-bound in rules | T-CVS/T-AZ | `validCloudSealedPayload`/`validCloudSealedText` accept global/regex AAD → same-account transplant/replay |
| MDASH-007 | `users/{uid}/devices` push-token injection | T-PRV/T-AZ | Owner-writable devices collection allows attacker-controlled push tokens |
| MDASH-008 | Mission claiming spoofable via escrow device ID | T-TOOL/T-AZ | Rules trust any trusted macOS `claimedBy` without Mac-signed proof |
| MDASH-009 | Initial `cloud_vault_state/current` client-writable | T-CVS/T-AZ | Race creates attacker-chosen vaultKeyID; delete denied |
| MDASH-010 | RR-13 Remote MCP HMAC claim drift | T-AZ/T-SC | Token issuers still permit HMAC; only verifier enforces posture |
| MDASH-011 | Local agent runtimes inherit full parent environment | T-TOOL/T-AI | Agent can dump daemon/auth tokens from env |
| MDASH-012 | Sandboxed `shell_run` inherits full environment | T-TOOL/T-AI | Seatbelt does not prevent env exfiltration |
| MDASH-013 | iOS iroh host-key confirmation default-off | T-TRN/T-PTR | First-pin TOFU window remains open |
| MDASH-014 | Queued agent grants broken / no trust re-check | T-TOOL | No Mac approval UI for queued delivery; no escrow trust re-check |
| MDASH-015 | Single device can exclude all others from CloudVault rotation | T-CVS/T-TOOL | Survivor set not required to equal all trusted devices |
| MDASH-016 | Accessibility revocation not polled | T-TOOL | Mid-session Accessibility revocation not detected until next action |
| MDASH-017 | Remote Unlock credential ack before validation | T-TOOL | UI may briefly show success before denial |

### 7.3 Medium / Low additions

- **Endpoint matrix integrity:** mislabeled trigger types, missing high-risk column, no enforced BOLA tests (MDASH-018–020).
- **Config/test gaps:** `requireHighRiskNonce` default untested; pairing completion lacks high-risk guard (MDASH-021–022).
- **Rules/availability:** `session_logs` manifest hits 1000-expression limit; `cloud_vault_key_wrappers` direct client writes (MDASH-023–024).
- **Android hardening:** cacheable iroh host-key fetch (MDASH-025).
- **Privacy/push:** unbounded VoIP `displayName`; agent notification reply schema version drift (MDASH-026–027).
- **Capability tokens:** no escrow/attestation binding, `scopeHash` not verified, `actionBudget` not decremented (MDASH-028–029).
- **Local runtime:** executable resolution without signature verification (MDASH-030).
- **Gateway hardening:** attachment init no `relayCapable` check; PoP v2 non-ASCII query canonicalization mismatch (MDASH-032–033).
- **Low/Info:** push deep link `threadId`; deterministic provider secret-ref IDs; narrow prompt sanitizer; `deleteHostedQuotaCredentials` default provider; `insightsHostedAnswer` non-standard auth (MDASH-034–038).

### 7.4 Impact on prior counts

The MDASH pass adds **3 Critical / 15 High / 15 Medium / 5 Low** findings to the prior rollup, for a running total of **4 Critical / 36 High / 55 Medium / 39 Low / 8 Info** when combined with the baseline assessment. The prior branch-fragmentation and live-state caveats remain in force.

---

*End of assessment. Cite as: `security/threat-model/current-state-assessment-2026-06-14.md` @ HEAD `f70565fcfb`.*
