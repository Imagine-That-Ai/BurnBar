> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780` (branch `remediation/tech-debt-fable-2026-06-12`). Prepared for an external Cure53 review. Share out-of-band; do not publish to the public repo. The local repository is the evidence source — deployed Firebase/IAM/KMS state, live branch protection, store-release config, and production Remote Config flags were **not** verified here unless explicitly stated (see [`open-questions.md`](open-questions.md)).

> ⚠️ **SUPERSEDED BY POST-REMEDIATION SYNTHESIS.** This package is retained as input evidence only. For the current deduped finding set and post-fix dispositions, use [`../../security-audit/merged/FINAL_REPORT.md`](../../security-audit/merged/FINAL_REPORT.md) and companion files under [`../../security-audit/merged/`](../../security-audit/merged/). In particular, the broad YOLO/Trusted-mode claim below was narrowed: the no-auth silent-escalation framing is rejected, while the reachable CLI/broker bypass + ambient environment issue is tracked and fixed as M-040 in the merged report.

> ⚠️ **CURRENT-STATE REFRESH (2026-06-14).** This README and the docs below were code-verified at baseline `5416ef780`. They have since drifted: see **[`current-state-assessment-2026-06-14.md`](current-state-assessment-2026-06-14.md)** (governs on conflict), **[`threat-status-2026-06-14.csv`](threat-status-2026-06-14.csv)**, **[`mitigation-roadmap-2026-06-14.md`](mitigation-roadmap-2026-06-14.md)**, and the MDASH follow-up **[`mdash-security-scan-report-2026-06-14.md`](../mdash-security-scan-report-2026-06-14.md)**. Re-verified at HEAD `f70565fcfb` (branch `security/iroh-host-key-pin-ttrn01`): **baseline 106 threats → 1 Fixed · 8 Mitigated-in-code · 21 Partial · 74 Open · 2 Unverifiable**; plus MDASH pass adds **3 Critical / 15 High / 15 Medium / 5 Low** findings (`MDASH-001`–`MDASH-038`). **Read §0 and §7 of the assessment first** — the remediation is fragmented across divergent branches and this checkout holds only a slice of it.

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
| 1 | MDASH-001 / MDASH-002 / MDASH-003 | **Computer Use / Remote Unlock launch blockers**: panic kill switch writes `/var/run` from a user app (not wired to root watchdog); Remote Unlock nonce ledger and issuer trust are under root-owned paths, so both fail in production. | **Critical** |
| 2 | MDASH-004 | **Trust/data-destructive callables use only Auth + App Check**: approving Gateway clients, connecting provider credentials, exporting/deleting all user data, and revoke-all lack the high-risk nonce + trusted-device proof. A stolen session can perform these actions. | **Critical** |
| 3 | T-TRN-01 / T-PTR-03 / MDASH-005 | iOS **host-pairing key pinning is default-off TOFU**; **Android has no pin at all** and uses a cacheable Firestore fetch → a compromised cloud/admin can MITM/redirect the iroh control channel on Android (and on iOS at first contact). Payload E2E survives. | **Critical** |
| 4 | T-TOOL-02 / T-AI-07 | **YOLO** emits `--dangerously-skip-permissions` + runs an **unsandboxed shell** at full user privilege with no per-action approval → prompt-injection-to-RCE when the user opts into Trusted/YOLO. | **Critical** |
| 5 | MDASH-006 | **CloudVault path-bound AAD is not enforced**: `validCloudSealedPayload`/`validCloudSealedText` accept global or regex-matching AAD, allowing same-account ciphertext transplant/replay across docs/fields/collections claimed to be path-bound. | High |
| 6 | MDASH-007 / MDASH-008 / MDASH-009 | **Same-account authz soft spots**: owner-writable `devices` collection allows push-token injection; mission `claimedBy` is spoofable via any trusted Mac escrow ID; initial `cloud_vault_state/current` is client-writable and can lock out the legitimate device. | High |
| 7 | T-DMN-01 / T-DMN-02 | Daemon treats a valid **first-party code signature as authorization** (no capability attenuation) and runs **unsandboxed**; one signed-app RCE = full local agency + credentials. | High |
| 8 | T-AI-01 / T-AI-02 / T-TOOL-05 / MDASH-011 / MDASH-012 | **Indirect prompt injection + secret exfiltration**: CU tool results, oracle snippets, and CLI lane content are injected unwrapped; local agents and sandboxed shell inherit the full parent environment, exposing daemon/auth tokens. | High |
| 9 | T-PRV-03 | **Client crash reports (iOS+macOS) ship to Sentry unscrubbed, no consent** — plaintext prompts/paths/tokens can egress to a third party. | High |
| 10 | T-CVS-03 / T-IOS-09 / MDASH-015 | Identity/**vault private keys extractable on a compromised unlocked endpoint** (not SE/biometry-bound on iOS); a single trusted device can rotate the vault key and exclude all others. | High |

Full ranked detail: [`threat-register.md`](threat-register.md) / [`threat-register.csv`](threat-register.csv) / [`threat-status-2026-06-14.csv`](threat-status-2026-06-14.csv) and the abuse-case attack trees in [`abuse-cases.md`](abuse-cases.md).

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
