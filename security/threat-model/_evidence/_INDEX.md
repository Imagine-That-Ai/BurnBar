# BurnBar Cure53 Package — Canonical Evidence Index (SPINE)

> **Confidential — security-sensitive.** Handle like `internal/security/`: share with Cure53 out-of-band, do not publish.
> This index is the single source of truth for component names, trust-boundary IDs, threat IDs, claim verdicts, and RR-status reconciliation. Every authoring agent MUST cite from here + the per-domain evidence files (`_evidence/NN-*.md`), `_threats.tsv`, and `_claims.json`. Pin commit: HEAD = `5416ef780` on branch `remediation/tech-debt-fable-2026-06-12`.

## 0. Method & provenance
- Independently derived from **current HEAD code** by 14 domain agents + 14 adversarial claim verifiers (workflow `wf_3f920b33-4cc`). Reconciled against three prior corpora: the in-tree `docs/security/BurnBar-threat-model.md`, the gitignored `internal/security/CURE53_REVIEW_PACKAGE_2026-06-12.md` (snapshot `47eac1fa7`), and `docs/security/SECURITY_CLAIMS_REGISTER.md` (RR remediation status).
- **Code is source of truth.** Where a doc/name implies more than the code delivers, it is flagged as an OVERCLAIM (`_gaps_overclaims.txt`).
- Evidence files: `01-crypto-relay` `02-cloudvault-signal` `03-pairing-trust-revocation` `04-transport-iroh` `05-gateway-pop` `06-cloud-authz` `07-daemon-privsocket` `08-agent-runtime-tools` `09-agentic-prompt-memory` `10-ios-masvs` `11-android-masvs` `12-attachments` `13-privacy-logging` `14-supply-chain`.

## 1. What BurnBar is (one paragraph)
BurnBar (product) / OpenBurnBar (codebase) is a **local-first** system to run AI coding/computer-use agents on the user's own Mac and observe/control them from iPhone, iPad, Android, and a web console. The canonical store is **local SQLite on the Mac**; every cloud feature is **opt-in**. When cloud sync is on, content fields are **sealed client-side** (AES-256-GCM under a per-user "CloudVault" key the servers never hold) before reaching Firestore; phone⇄Mac lanes carry **HPKE-sealed ciphertext**; push is content-minimized. It is **not** a single universal E2EE product — it is a local-first multi-device agent-control system with several sealed sub-flows, a Firebase control plane that sees rich metadata, a trusted-device graph, and powerful local agent runtimes that necessarily see plaintext.

## 2. Components (canonical names → code → trust)
| ID | Component | Code root | Trust |
|---|---|---|---|
| C1 | macOS app "AgentLens" | `AgentLens/` | Fully-trusted endpoint; **NOT sandboxed** in Developer-ID builds |
| C2 | Daemon (launchd, unix socket) | `OpenBurnBarDaemon/` | Same-user trust domain; token-auth socket; **unsandboxed** |
| C3 | Shared core (crypto/wire) | `OpenBurnBarCore/` | Security-critical library |
| C4 | iOS/iPadOS app | `OpenBurnBarMobile/` (+ Keyboard/Widget) | Trusted endpoint (weaker physical assumptions) |
| C5 | Android app | `android/app/` | Trusted endpoint; **parity gaps** |
| C6 | iroh transport | `crates/openburnbar-iroh/`, `crates/burnbar-remote/` | Transport; relays untrusted |
| C7 | iroh relays | n0 public set / optional hosted | **Untrusted** (metadata only) |
| C8 | Firebase backend | `functions/`, `firestore.rules`, `storage.rules` | **Untrusted for content; trusted for availability/authz-metadata/ordering** |
| C9 | Hermes Gateway (hosted lane) | `functions/src/callables/hermesGateway.ts` | Blind store-and-forward; untrusted for content |
| C10 | Hermes agent runtime (model loop) | vendored `~/.hermes/hermes-agent` (`.pyc` in-repo) | Trusted endpoint; **source not fully in-repo** |
| C11 | Hosted MCP | `services/hosted-mcp/` | Untrusted for content (no decrypt path) |
| C12 | Web console | `apps/console/` | Semi-trusted once a native device approves the wrap |
| C15 | CI/CD + release | `.github/workflows/` | Supply-chain critical |
| C16 | Model providers | external | Untrusted third party, by design (see plaintext) |

## 3. Trust boundaries (canonical IDs)
- **B1** Same-user processes ↔ Mac app/daemon — *all UID processes equally trusted* (documented). Compromise = full local domain.
- **B2** Device ↔ Cloud (Firestore/Functions) — honest-but-curious for content; trusted for availability/ordering/authz-metadata; **Admin SDK bypasses rules**.
- **B3** Device ↔ Device (pairing/escrow) — pending→trusted needs a distinct native approver's XEdDSA trust-chain sig, server-verified + client-re-verified from key bytes before any vault wrap.
- **B4** Phone ↔ Mac control — Mac verifies locally (pinned keys, counters, intent hashes, OS-auth proofs); phone state cosmetic.
- **B5** Gateway ↔ Agent (hosted lane) — blind store-and-forward; agent key pinned at pairing, immutable; clients PoP-bound.
- **B6** User ↔ Agent (model output) — model output untrusted; authority only from signed grants + typed-action approvals.
- **B7** Cloud ↔ Storage — Admin SDK + short-TTL (10–15 min) signed URLs; rules deny-by-default.
- **B8** Repo/CI ↔ released artifacts — PR gates + tag-gated deploys + signing; **solo operator**.
- **B9** BurnBar ↔ model providers — providers see plaintext; BYOK keys do not transit BurnBar servers (gateway lane verified).
- (New, transport-specific) **B2-iroh** Cloud-published iroh pairing key / inbound allowlist ↔ phone — see **T-TRN-01 / T-PTR-03**: phone→Mac host key is **not pinned** (in-memory TOFU), asymmetric vs Keychain-pinned Mac→phone controller key.

## 4. Cryptographic construction map (as implemented — verified current)
| Lane | Construction | Evidence |
|---|---|---|
| CloudVault at-rest seal | AES-256-GCM, 12B nonce, 16B tag; per-user 32B vault key (`SecRandomCopyBytes`); AAD v2 path-binds `uid\|coll\|doc\|field\|schema\|purpose` | `CloudVaultCrypto.swift`; Kotlin mirror |
| Vault-key device wrap / escrow | ECIES eph-static P-256 ECDH → HKDF-SHA256 → AES-256-GCM; **no AAD** | `CloudVaultCrypto.swift` |
| Relay request seal (realtime/iroh/Firestore-request) | **HPKE v3 RFC 9180 Auth mode**, P256/HKDF-SHA256/AES-256-GCM; AAD binds uid\|conn\|requestID\|operation\|senderDevice\|peerNode\|counter\|keyID; open binds **pinned** sender key not wire field; replay = counter + requestID TTL cache | `HermesRelayCrypto.swift:493-557`, `HermesRelayAuthenticatedRequest.swift:195-246` |
| Gateway envelopes | v2 sender-auth 2-DH P-256; v3 HPKE-Auth; ratchet lane homegrown P-256 double-ratchet; **v4 read-tolerant only**; v5 PQ **unmerged** | `hermesGateway.ts`, vendored adapter |
| Signal at-rest (INERT) | per-doc key→AES-GCM; key HPKE-sealed per recipient; sender XEdDSA `senderAuth` over domain-separated binding, reader verifies vs pinned set, fail-closed | `SignalAtRestSealer.swift`, `SignalAtRestFallbackPolicy.swift` |
| Phone-control signing | Ed25519 / SE-P256 (`.biometryCurrentSet`); canonical-JSON→BLAKE3 intent hash; monotonic counter; single-use local-auth proof | `PhoneControlAuthorityValidator.swift` |
| Trust chain | XEdDSA over Curve25519 identity keys; server-verified + client-re-verified from key bytes before wrap | `computerUseSecurity.ts`, `CloudVaultTrustedDeviceChainVerifier.swift` |
| Gateway PoP | Ed25519 over `tokenHash\nMETHOD\npath\nbodyHash\nnonce\nts`; 5-min skew; Firestore-txn nonce replay guard | `hermesGateway.ts` |
| Recovery bundle | PBKDF2-HMAC-SHA256 (100k) → AES-256-GCM over DB key | `DatabaseEncryptionService.swift` |
| Update channel | DMG Ed25519 vs pinned key; notarization; cosign; post-publish live-feed verify | `release.yml` |

**Crypto red-flag scan (Phase 5.4): clean on primitives** — standard CryptoKit, no homegrown AEAD/curve, no static IV, no nonce reuse, no encrypt-without-MAC, no hardcoded keys, no disabled TLS verify, CSPRNG checked, no catch-and-continue. Caveats live in **lane wiring**, not primitives. Self-documented non-goals: **no static-leg PFS, no KCI protection** on the relay scheme.

## 5. Adversarial claim verdicts (the 14 headline claims)
| ID | Claim (abbrev) | Verdict | Conf |
|---|---|---|---|
| C1 | Cloud cannot read current Gateway message bodies | **Defensible** | Med |
| C2 | Cloud cannot read CloudVault at-rest content | **Partial** | High |
| C3 | Attachments sealed before upload; cloud can't read bytes/filenames | **Partial** | Med |
| C4 | Gateway bearer alone insufficient (PoP required) | **Defensible** | High |
| C5 | Revoked device can't receive newly-sealed material (rotation) | **Partial** | High |
| C6 | Untrusted content can't directly trigger high-impact action | **Partial** | High |
| C7 | High-risk grants need single-use local-auth bound to op hash | **Partial** | Med |
| C8 | Only pinned paired devices exchange Gateway msgs; relay can't impersonate | **Partial** | Med |
| C9 | Iroh pairing records can't be spoofed/replayed | **Partial** | Med |
| C10 | Provider creds not in Firestore plaintext (KMS/Secret Manager) | **Defensible** | High |
| C11 | Object-level authz: no cross-user data access | **Partial** | Med |
| C12 | Old messages/pairing codes can't be replayed | **Partial** | High |
| C13 | Logs/crash/push contain no plaintext bodies/secrets | **Partial** | Med |
| C14 | BurnBar does NOT claim production Signal E2EE (honestly gated) | **Defensible** | High |

**Reading:** 4 Defensible, 10 Partial, **0 NotDefensible**. The claims hold *with material caveats* — the package's job is to state each caveat precisely (safe vs unsafe wording in `_claims.json`). The biggest Partials: C2 (metadata + legacy + endpoint), C5 (rotation wired but client-driven, no claw-back), C6 (true for *minting* grants/approvals — cryptographic — but injection steers *within* granted scope via unwrapped tool/oracle output), C8/C9 (TOFU on first pairing; cloud-substituted host key — T-TRN-01).

## 6. Headline risks (Critical + top High, current code)
- **T-TRN-01 / T-PTR-03 (Critical/High)** — iOS host-pairing key is **in-memory TOFU, not pinned/persisted** (`FirestoreIrohPairingPublicKeyProvider.swift:27-47`); a compromised cloud/admin can substitute the key + signed record and **MITM/redirect the iroh control channel** and force downgrade. Asymmetric trust vs Keychain-pinned Mac→phone controller key. Payload confidentiality survives via the independent E2E relay layer.
- **T-TOOL-02 / T-AI-07 (Critical/High)** — **YOLO** (`isYOLOGrant`, `CLIArgumentBuilder.swift:52,87,168,189,215`) emits `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`; broker `runShellUnrestricted` runs `/bin/zsh` **unsandboxed at full user privilege with no per-action approval** → prompt-injection-to-RCE when the user opts into trusted/YOLO mode. No per-N-action re-auth (TODO in code).
- **T-DMN-01 / T-DMN-02 (High)** — daemon treats a **valid first-party code signature as authorization** (no capability attenuation) and runs **unsandboxed** as the login user; one signed-app RCE = full local agency + credential access.
- **T-AI-01 / T-AI-02 / T-TOOL-05 (High)** — **indirect prompt injection**: Computer-Use tool results (file/shell/screenshot/clipboard outside a 2-tool allowlist), the chat **oracle "authoritative findings"**, and the CLI lane inject **untrusted content unwrapped** into model context; can chain into further tool calls incl. shell under YOLO. (Confirms RR-15 is only *partly* closed at HEAD.)
- **T-CVS-03 (High)** — identity/vault private keys are **extractable on a compromised unlocked endpoint** (no hardware-bound non-extractable signing, no per-use auth on the signing key); no PFS to bound blast radius.
- **T-TOOL-01 / T-TOOL-03 (High)** — external CLI agents run with **no in-process policy gate**; grant **revoke ≠ kill** (in-flight subprocess not terminated, expiry not re-checked mid-run).
- **T-ATT-01 (High)** — Mercury media transfer trusts `manifest.size`: **no streaming byte ceiling / no post-fetch size==manifest reject** on the iroh blob path (GCS lane has the check, Mercury doesn't) → decompression/oversize disk-fill DoS.
- **T-SC-01 / T-SC-02 / T-SC-03 (High/Med)** — CI uses **mutable action tags** (not SHA-pinned) in several workflows; the supply-chain-provenance **`cargo deny` ecosystem-deny silently no-ops** (false assurance); **single CODEOWNER** = no separation of duties.
- **T-AZ (cloud authz)** — see `06-cloud-authz.md`: `cloud_vault_key_wrappers` owner-delete (availability), `users/{uid}` root-doc allowlist gap, avatars cross-tenant read (accepted), Admin-SDK bypass; App Check console enforcement is **UNKNOWN from repo**.

## 7. RR-1…RR-20 reconciliation (internal pkg snapshot → current HEAD)
The internal package (snapshot `47eac1fa7`) listed RR-1…RR-20. The claims register marks many CLOSED/build-gated. Authoring agents MUST state status as **verified at HEAD** where their domain agent checked it, else cite the register and mark "register-claimed, not re-verified here." Notable at HEAD:
- **RR-15 (prompt-injection wrapping)** — only **partially** closed: evidence-pack/RAG wrapped, but CU tool results, oracle findings, and CLI lane still unwrapped (T-AI-01/02, T-TOOL-05).
- **RR-5 (revocation→rotation)** — rotation machinery now **wired and client-driven** (C5 Partial, not "unwired"); **no claw-back** of pre-revocation cached keys remains.
- **RR-1 (local DB at rest)** — verify SQLCipher codec status at HEAD (see `02`/`10`); "encrypted database" still likely unsafe wording.
- **RR-16 (supply chain)** — partly closed (Kotlin/Rust SAST added) but mutable tags + no-op cargo-deny remain (T-SC-01/02).
- Items needing **deployed evidence** (UNKNOWN from repo): App Check console enforcement, PITR/backups, alert channels, Remote Config live values, branch protection — see `open-questions.md`.

## 8. Non-claims BurnBar must keep stating (honest boundaries)
Not E2E for the whole product; cloud sees rich **metadata** (IDs, timestamps, sizes, counters, statuses, model/provider/cost facets, search token/semantic hashes, push tokens, routing); **endpoint/local-agent compromise defeats confidentiality** (plaintext is intentionally in scope there); **no forward secrecy / PCS** beyond the ephemeral relay leg; **provider creds are backend-decryptable** (IAM/KMS is the boundary, not zero-knowledge); **no production Signal/libsignal E2EE** (flag-OFF, fail-open-to-legacy); **revocation does not claw back** already-cached plaintext; **model providers see everything routed to them**.

## 9. Framework lenses to map (do not name-drop — map findings)
STRIDE; LINDDUN (Linking/Identifying/Non-repudiation/Detecting/Disclosure/Unawareness/Non-compliance); OWASP Top 10 LLM Apps 2025; OWASP Agentic Apps 2026; MITRE ATLAS; OWASP ASVS 5.0; OWASP API Security Top 10 2023; OWASP MASVS/MASTG; MITRE CWE Top 25 2025; NIST CSF 2.0 (Govern/Identify/Protect/Detect/Respond/Recover); NIST Zero Trust; NIST SSDF; OWASP SCVS; SLSA.

## 10. Severity model
- **Critical**: many users' plaintext, RCE, signing-key compromise, pairing bypass at scale, operator impersonation of devices.
- **High**: one user's sensitive data, unauthorized tool execution, object-authz bypass, privileged-component compromise.
- **Medium**: meaningful impact w/ specific preconditions or limited blast radius.
- **Low**: defense-in-depth / hardening / low-impact leak. **Info**: documentation/assumption/future.
