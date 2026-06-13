> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780` (branch `remediation/tech-debt-fable-2026-06-12`). Prepared for an external Cure53 review. Share out-of-band; do not publish to the public repo. The local repository is the evidence source — deployed Firebase/IAM/KMS state, live branch protection, store-release config, and production Remote Config flags were **not** verified here unless explicitly stated (see [`open-questions.md`](open-questions.md)).

# BurnBar Security Assurance Package — Executive Summary

## What BurnBar is

BurnBar (product) / OpenBurnBar (codebase) lets a user run AI coding/computer-use agents on their **own Mac** and observe and control them from iPhone, iPad, Android, and a web console. It is **local-first**: the canonical store is local SQLite on the Mac, and every cloud feature is opt-in. When cloud sync is enabled, content is **sealed on-device** (AES-256-GCM under a per-user “CloudVault” key the servers never hold) before it reaches Firestore; phone⇄Mac lanes carry HPKE-sealed ciphertext; push is content-minimized. The codebase spans native Apple apps + a shared crypto core (`OpenBurnBarCore`, `AgentLens`, `OpenBurnBarDaemon`, ~3,200 Swift files), an Android app (~890 Kotlin), a Firebase backend (`functions`, ~115 callables; `firestore.rules` 4,254 lines), a Rust iroh P2P transport (`crates/openburnbar-iroh`, `burnbar-remote`), and the Hermes Gateway store-and-forward relay.

## What “secure” means here (the honest model)

BurnBar is **not** a single universal end-to-end-encrypted product, and it is **not** “the cloud is blind.” The defensible model is: **the user’s devices and local agent runtimes are the trusted core; several message/at-rest sub-flows are sealed so the cloud handles only ciphertext + metadata; the cloud remains trusted for auth, authorization-metadata, routing, availability, and provider-secret custody; and the central security problem is bounding what an AI agent — or content that manipulates one — can do on the user’s machine.** Full definition: [`security-definition.md`](security-definition.md).

## Top security goals

1. Content confidentiality vs the cloud on sealed surfaces (Gateway bodies, CloudVault at-rest, attachments).
2. Cryptographic device identity + control authority (signed, replay-protected, OS-auth-gated) that model output cannot forge.
3. Bounded, approved, audited, reversible agent action — the agentic surface is the crown-jewel risk.
4. Metadata minimization where cheap; honest, code-backed claims; operational recoverability.

## Method

Independently derived from current HEAD code by **14 domain review agents + 14 adversarial claim verifiers** (each verifier tried to *refute* a headline claim before scoring it), then reconciled against three prior corpora: the in-tree `docs/security/BurnBar-threat-model.md`, the gitignored `internal/security/CURE53_REVIEW_PACKAGE_2026-06-12.md` (older snapshot `47eac1fa7`), and `docs/security/SECURITY_CLAIMS_REGISTER.md`. Raw findings: [`_evidence/`](_evidence/). Result: **106 threats** (2 Critical, 21 High, 41 Medium, 34 Low, 8 Info), **14 verified claims** (4 Defensible, 10 Partial, 0 Not-defensible), **157 controls** catalogued.

## Top 10 risks (current code)

| # | ID | Risk | Sev |
|---|---|---|---|
| 1 | T-TRN-01 / T-PTR-03 | iOS **host-pairing key is in-memory TOFU, not pinned** → a compromised cloud/admin can MITM/redirect the iroh control channel & force downgrade (asymmetric vs the Keychain-pinned Mac→phone key). Payload E2E survives. | **Critical** |
| 2 | T-TOOL-02 / T-AI-07 | **YOLO** emits `--dangerously-skip-permissions` + runs an **unsandboxed shell** at full user privilege with no per-action approval → prompt-injection-to-RCE when the user opts into Trusted/YOLO. | **Critical** |
| 3 | T-DMN-01 / T-DMN-02 | Daemon treats a valid **first-party code signature as authorization** (no capability attenuation) and runs **unsandboxed**; one signed-app RCE = full local agency + credentials. | High |
| 4 | T-AI-01 / T-AI-02 / T-TOOL-05 | **Indirect prompt injection**: CU tool results (file/shell/screenshot/clipboard), the chat **oracle “authoritative findings”**, and the CLI lane inject untrusted content **unwrapped**; can chain into further tool calls incl. shell under YOLO. | High |
| 5 | T-PRV-03 | **Client crash reports (iOS+macOS) ship to Sentry unscrubbed, no consent** — plaintext prompts/paths/tokens can egress to a third party. | High |
| 6 | T-CVS-03 / T-IOS-09 | Identity/**vault private keys extractable on a compromised unlocked endpoint** (not SE/biometry-bound on iOS); no PFS to bound blast radius. | High |
| 7 | T-PRV-01 / T-PRV-02 | **VoIP/call pushes leak caller name + stable device correlators** to Apple/Google; push-queue root docs **never deleted on account erase, no TTL** (GDPR erasure gap). | High |
| 8 | T-TOOL-01 / T-TOOL-03 | External CLI agents run with **no in-process policy gate**; grant **revoke ≠ kill** (in-flight subprocess survives, expiry not re-checked mid-run). | High |
| 9 | T-AZ (several) | Cloud authz soft spots: `cloud_vault_key_wrappers` owner-delete (availability), `users/{uid}` root-doc allowlist gap, avatars cross-tenant read (accepted), Admin-SDK rule bypass; App Check console enforcement **UNKNOWN from repo**. | High |
| 10 | T-SC-01/02/03 + T-ATT-01 | Supply chain: **mutable CI action tags**, **`cargo deny` ecosystem-deny silently no-ops**, **single CODEOWNER**; plus Mercury media DoS (no streaming byte ceiling). | High/Med |

Full ranked detail: [`threat-register.md`](threat-register.md) / [`threat-register.csv`](threat-register.csv) and the abuse-case attack trees in [`abuse-cases.md`](abuse-cases.md).

## Top 10 missing controls

1. **Pin the iOS host-pairing key** (persist + safety-number/QR out-of-band verification) — closes T-TRN-01.
2. **A hard, in-process policy gate + real sandbox for the CLI/shell lane**, and remove/strongly-gate `--dangerously-skip-permissions`/`runShellUnrestricted` — closes T-TOOL-02/01.
3. **Per-N-action re-auth** (not one-time-at-grant) for shell/desktop classes, and **terminate in-flight agents on revoke**.
4. **Wrap CU tool results + the oracle path as untrusted** at the point they re-enter model context (finish RR-15).
5. **Client-side Sentry `beforeSend` scrubber + consent gate** (and `sendDefaultPii:false`).
6. **SE/biometry-bind the iOS vault & escrow keys** (the pattern already exists for the CU signing key).
7. **Daemon sandbox + capability attenuation** (don’t equate code-signature with authorization).
8. **Drop caller display name from VoIP pushes; add TTL + account-erase coverage** to push-queue collections.
9. **SHA-pin all GitHub Actions; make `cargo deny` actually run; add a second CODEOWNER/reviewer.**
10. **Streaming byte-ceiling + post-fetch size==manifest reject on the Mercury media path.**

## Top 10 defensible security claims (safe to make, with caveats)

C1 cloud can’t read **current** Gateway bodies (✅); C4 **bearer alone insufficient — PoP required** (✅); C10 provider creds not in Firestore plaintext, KMS-wrapped (✅); C14 **no production Signal E2EE is claimed** (✅, honest gating); plus the strong-with-caveat set: C2 CloudVault at-rest sealed for current schema; C8 post-pairing key pinning + immutability; C5 atomic revoke + scheduled re-key; C6 fail-closed Manual-mode approval + deny-regions + SSRF denies; C12 replay defenses on the authenticated lanes; C3 attachments sealed before upload. Exact safe wording: [`security-claims.md`](security-claims.md).

## Top 10 claims BurnBar should NOT make

“End-to-end encrypted” unqualified · “zero-knowledge” / “server learns nothing” · “Signal Protocol / Double Ratchet / forward secrecy / post-quantum” for the live product · “BurnBar can never read your data” (metadata + legacy) · “API keys never leave the device” · “encrypted database” (while SQLCipher codec/migration is incomplete) · “revocation immediately makes old data safe” · “all kill switches fail closed” · “our CI enforces X” for orphaned/advisory gates · “the assistant cannot read your messages” (provider lane decrypts by construction).

## What is ready for audit vs not

**Ready:** the cryptographic identity/control spine (signing, counters, OS-auth proofs, deny-regions); the Gateway sealed-write + PoP model; CloudVault at-rest sealing + rules; the crypto primitives (clean red-flag scan); provider-secret KMS custody; the honest claims discipline.

**Not ready / fix first:** pin the iOS pairing key (T-TRN-01); contain the CLI/shell/YOLO lane (T-TOOL-02); finish untrusted-content wrapping (RR-15); client Sentry scrubbing (T-PRV-03); align user-facing copy down to the safe wording; and produce the **deployed-state evidence** (App Check enforcement, PITR/backups, alerting, Remote Config values, branch protection) listed in [`open-questions.md`](open-questions.md) — several controls are code-correct but unprovable from the repo alone.

## Package contents

`README.md` · `security-definition.md` · `architecture.md` · `assets.md` · `trust-boundaries.md` · `security-claims.md` · `crypto-review.md` · `agentic-ai-threat-model.md` · `privacy-threat-model.md` · `cloud-and-ops-threat-model.md` · `supply-chain-threat-model.md` · `threat-register.csv` · `threat-register.md` · `abuse-cases.md` · `mitigation-roadmap.md` · `security-test-plan.md` · `cure53-audit-brief.md` · `open-questions.md` · `evidence-map.md` · `_evidence/` (raw per-domain findings, the 14-claim JSON, the threat TSV, and `_prior-cut/` = an earlier parallel draft preserved for reference).
