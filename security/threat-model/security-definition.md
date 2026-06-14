> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780` (branch `remediation/tech-debt-fable-2026-06-12`). Share with Cure53 out-of-band; do not publish.

# Definition of Secure for BurnBar

This document answers the core question — *“What does secure mean for BurnBar, for the user, the product, and the business?”* — and then the rest of the package derives architecture, controls, and residual risks from it. It is written conservatively: where the implementation does not support a property, the property is **not** claimed.

## 0. The one-sentence model

> BurnBar is a **local-first, multi-device agent-control system** in which the user’s own devices and local agent runtimes are the trusted core, several message/at-rest sub-flows are sealed so the cloud handles only ciphertext + metadata, and the highest-value security work is **bounding what an AI agent — or content that manipulates one — can do on the user’s machine.**

It is explicitly **not** a single universal end-to-end-encrypted product, and it is not “the cloud is blind to everything.” Treating it as either would produce indefensible claims (see [`security-claims.md`](security-claims.md)).

## 1. Trust assumptions (stated, not assumed away)

These are the load-bearing assumptions. If any is false in a given deployment, the dependent guarantees fall.

| # | Assumption | If false |
|---|---|---|
| A1 | The user’s endpoint OS, app binary, and OS key store are uncompromised while in use. | Plaintext, vault keys, and signing keys are exposed — outside the crypto boundary by design. |
| A2 | The local agent runtime acts within user intent and granted scope. | Prompt-injection / malicious runtime can act within granted scope (see C6, T-TOOL-*, T-AI-*). |
| A3 | The **first** device-pairing key exchange is honest (keys are trusted-on-first-use, then pinned). | A malicious cloud could substitute keys at first pairing — no user-verified safety number exists (T-TRN-01, C8/C9). |
| A4 | BurnBar Cloud / Firebase project IAM, KMS, and deployed rules match the reviewed source. | Admin SDK bypasses Firestore rules; a rogue admin/IAM holder can read metadata, decrypt provider creds, MITM new pairings, delete data. |
| A5 | The macOS daemon and app are genuinely first-party-signed and not swapped/instrumented. | Daemon trusts code-signature **as authorization** (T-DMN-01); a compromised signed app = full local agency. |
| A6 | Model providers are honest-but-curious third parties the user chose. | Anything routed to a provider is visible to it; provider output is still untrusted input. |

## 2. Secure for Users

A user is secure to the extent each statement below holds. Each maps to a verified claim (✅/🟡, see `security-claims.md`) and the residual the user retains.

- **Your message and attachment *content* is sealed before it reaches BurnBar’s cloud.** 🟡 True for current (schema-2+) Gateway messages/events/attachments and CloudVault conversation/chat/session/memory surfaces — the cloud stores ciphertext and is coded never to decrypt (C1 ✅, C2 🟡, C3 🟡). **Residual:** routing metadata is visible; first-pairing key trust is TOFU; legacy/un-migrated rows and legacy attachment *objects* may still be server-readable until a backfill converges.
- **Attachments are readable only by intended recipients.** 🟡 Sealed client-side; filename/content-type sealed; new unsealed writes rejected. **Residual:** sealing is client-enforced (cloud can’t prove ciphertext), metadata visible, legacy plaintext Storage objects not provably purged (T-ATT, C3).
- **A removed/unpaired device loses the ability to receive *new* trusted material.** 🟡 Revocation is atomic (trust flipped, wrappers/controllers/grants revoked) and schedules a vault re-key. **Residual:** re-key is client-driven and needs a surviving trusted Mac; until it completes the revoked device keeps its Firebase session and can still read/decrypt material sealed under the old key; **no claw-back** of already-cached plaintext (C5, T-PTR).
- **A malicious document/webpage/email/tool-output cannot *silently* cause a dangerous action.** 🟡 In the **default Manual mode** the Computer-Use path is fail-closed: every non-read action needs an explicit human approve/reject, deny-regions and SSRF/metadata/`file://` denies are enforced, and untrusted content is provenance-wrapped. **Residual:** in operator-chosen **Trusted/YOLO** mode, scope-allowed high-impact actions auto-dispatch, and CLI/oracle/CU-tool-result content is not fully isolated → injection can act within granted scope (C6, T-AI-01/02, T-TOOL-02/05).
- **You can tell when an agent is about to do something high-impact.** 🟡 Approval prompts are derived from *typed actions*, server-derived for the gateway, and **not spoofable by model output**. **Residual:** the summary text can be attacker-influenced (approval-phishing is a UX risk).
- **Sensitive data is not leaked into logs/analytics/crash/providers.** 🟡 Server logs scrub known secret patterns; agent-reply push uses a generic preview; server Sentry is scrubbed. **Residual:** **client** crash reports (iOS/macOS) ship to Sentry **unscrubbed, no consent** (T-PRV-03); VoIP/call pushes leak caller name + device correlators to Apple/Google (T-PRV-01); the scrubber is pattern-based (numeric/edge fields bypass) (C13, T-PRV-04).
- **A compromised cloud relay cannot impersonate a paired device undetected.** 🟡 After pairing, keys are pinned and immutable; opens bind the pinned key; PoP defeats bearer theft. **Residual:** at *first* pairing the host key is in-memory TOFU and cloud-substitutable (T-TRN-01) — the independent E2E layer still protects payload confidentiality but the control channel can be redirected.
- **A stolen device / compromised endpoint / malicious agent has clearly bounded, documented limits.** ✅ The boundaries are explicit (this document, §1 and the non-claims). **Residual:** they are limits, not protections — an unlocked stolen phone has no app-level re-auth gate (T-IOS-02); vault keys are not SE/biometry-bound on iOS (T-IOS-09).

## 3. Secure for the Product

- **Clear trust boundaries.** ✅ Nine primary boundaries (B1–B9) plus agent/tool/memory/content sub-boundaries are enumerated ([`trust-boundaries.md`](trust-boundaries.md)).
- **Minimized trust in cloud infrastructure for *content*.** ✅ for sealed surfaces (client-side keys, server-shape-only validation, no decrypt path). 🟡 the cloud is still trusted for availability, ordering, authz-metadata, provider-secret custody, and (critically) **first-pairing key distribution**.
- **Security claims backed by implementation.** ✅ This is enforced: the repo has a `SECURITY_CLAIMS_REGISTER.md`, honesty-copy CI gates, and a crypto-architecture policy checker. This package adds adversarial verification at HEAD.
- **High-impact actions gated by policy + identity + approval.** 🟡 Strong cryptographic grant/approval spine (Ed25519/SE-P256 signed, counter-replay-protected, OS-auth-bound, deny-regions override even signed authority). **Gap:** the gate is a *deterministic code* policy for *minting* authority, but tool-output that steers an already-granted session is only defense-in-depth-wrapped; YOLO removes per-action approval.
- **Fail-closed where appropriate.** 🟡 Auth/PoP/audit/crypto-open paths fail closed; **but** several RC-driven kill switches and media/budget negotiations historically fail *open* on fetch failure — verify current state (open question).
- **Critical controls testable and monitored.** 🟡 Good CI coverage (CodeQL incl. Kotlin, rust SAST, rules emulator tests, honesty gates); gaps in mutable action pins, no-op cargo-deny, single CODEOWNER (T-SC), and several controls depend on **deployed** state not provable from the repo.
- **Incident-response paths exist for key/relay/provider/agent compromise.** 🟡 Revocation, rotation, panic/kill paths, audit hash-chains exist; operational readiness (PITR/backups/alerting) needs deployed evidence.

## 4. Secure for the Business

- **Explainable to auditors.** ✅ This package + the in-tree threat model + claims register give a defensible, evidence-cited story at a pinned commit.
- **Risks prioritized and tracked.** ✅ 106-threat register ([`threat-register.csv`](threat-register.csv)) + RR-1…RR-20 reconciliation + roadmap ([`mitigation-roadmap.md`](mitigation-roadmap.md)).
- **User-facing claims are defensible.** 🟡 The 14-claim matrix gives safe vs unsafe wording; **the business must align website/app-store copy down to the safe wording** (the repo flags specific over-claims to fix).
- **Logging supports IR without creating privacy risk.** 🟡 Server side yes; **client crash reporting is an open privacy liability** (T-PRV-03).
- **Supply-chain/dependency risk is visible.** 🟡 SBOM/VEX/cosign/notarized release lane is strong; CI hardening gaps remain (T-SC).
- **Regressions caught before release.** 🟡 Strong PR gate suite; gaps where gates are advisory, orphaned (`verify-signal-activation-parity.sh` wiring), or bypassable by direct-push (solo-operator).

## 5. Goals / Non-Goals (crisp)

**Goals:** content confidentiality vs the cloud for sealed surfaces; cryptographic device-identity and control authority; bounded, approved, audited, reversible agent action; metadata minimization where cheap; honest claims; operational recoverability.

**Non-Goals (current):** universal E2EE; zero-knowledge cloud; forward secrecy/PCS as a product property; anonymity / full metadata privacy; protection of a compromised endpoint or fully-compromised paired device; production Signal-protocol guarantees; protection against a user intentionally sharing data with a model provider; screenshot/shoulder-surf resistance app-wide.

## 6. How to read the rest of this package

[`architecture.md`](architecture.md) (decomposition + DFDs) → [`assets.md`](assets.md) → [`trust-boundaries.md`](trust-boundaries.md) → [`security-claims.md`](security-claims.md) (what we may/may not say) → [`crypto-review.md`](crypto-review.md) → [`agentic-ai-threat-model.md`](agentic-ai-threat-model.md) (the highest-risk surface) → [`privacy-threat-model.md`](privacy-threat-model.md) → [`cloud-and-ops-threat-model.md`](cloud-and-ops-threat-model.md) → [`supply-chain-threat-model.md`](supply-chain-threat-model.md) → [`abuse-cases.md`](abuse-cases.md) → [`threat-register.csv`](threat-register.csv)/[`.md`](threat-register.md) → [`mitigation-roadmap.md`](mitigation-roadmap.md) → [`security-test-plan.md`](security-test-plan.md) → [`cure53-audit-brief.md`](cure53-audit-brief.md) → [`open-questions.md`](open-questions.md) → [`evidence-map.md`](evidence-map.md).
