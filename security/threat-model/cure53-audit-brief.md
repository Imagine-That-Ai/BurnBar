> **CONFIDENTIAL — BurnBar security package.** Independently code-verified at HEAD `5416ef780`. Share with Cure53 out-of-band; do not publish.

# Cure53 Audit Brief — BurnBar / OpenBurnBar

## 1. System overview

BurnBar lets a user run AI coding/computer-use agents on their own Mac and control them from iPhone/iPad/Android/web. Local-first (canonical store = Mac SQLite; cloud opt-in). Content on sealed surfaces is encrypted on-device (AES-256-GCM “CloudVault” + HPKE relay lanes) before reaching Firebase; phone⇄Mac transport is iroh QUIC P2P with a Firestore fallback; Hermes Gateway is a blind store-and-forward relay. See [`architecture.md`](architecture.md) for components (C1–C16), DFDs, and diagrams; [`security-definition.md`](security-definition.md) for the trust model.

**The model in one line:** the user’s devices + local agent runtimes are the trusted core; some sub-flows are sealed so the cloud sees only ciphertext + metadata; the cloud is trusted for auth/authz-metadata/routing/availability/provider-secret custody and (critically) **first-pairing key distribution**; the central risk is **bounding agent + injected-content actions on the host**.

## 2. Proposed scope

**In scope (highest value):**
- **Iroh pairing-key trust + transport** — TOFU host-key substitution, allowlist control, downgrade (T-TRN-01/02/03). *Try to break the control channel via the cloud.*
- **Computer-Use / agent control spine** — grant signing (Ed25519/SE-P256), monotonic counters, single-use OS-auth proofs, deny-regions, Trusted/YOLO auto-dispatch, the CLI/`runShellUnrestricted` lane (T-TOOL-*, T-AI-*, C6/C7). *The crown-jewel attack surface.*
- **Prompt-injection containment** — CU tool results, chat oracle, CLI lane, RAG/memory (T-AI-01/02/04). *Drive a granted session via hostile content.*
- **Hermes Gateway** — sealed-only writes + PoP, replay, key pinning, approval derivation (C1/C4/C8); cross-language envelope parity (Swift/Kotlin/Python).
- **HPKE v3 relay + CloudVault crypto** — AAD coverage, v2 floor, downgrade, at-rest freshness/replay (RR-8), ECIES no-AAD.
- **Firestore/Storage rules vs callable authority** — Admin-bypass assumptions, `cloud_vault_key_wrappers` delete, `users/{uid}` root gap, signed-URL scope, tenant isolation (T-AZ, C11).
- **macOS daemon** — socket/peer model, code-sign==authz, binary swap, privileged-input lane, sandbox absence (T-DMN-*).
- **Mobile at-rest** — iOS App-Group/pasteboard/push/key-protection (T-IOS-*); Android parity (T-AND-*).
- **Supply chain / CI-CD** — action pinning, cargo-deny, CODEOWNERS, release integrity, vendored AAR/`.pyc` (T-SC-*).
- **Privacy** — VoIP push leakage, push-queue erase/TTL, client Sentry, search-index inference (T-PRV-*).

**Out of scope (or limited):** the model providers themselves (third parties); nation-state QUIC cryptanalysis / hardware implants / Apple-Google platform compromise (declared non-realistic for this tier); deployed GCP IAM/KMS internals beyond what the operator provides as evidence (see §6).

## 3. Test accounts & environments

- **Recommended:** a dedicated test Firebase project (or a clearly-scoped tenant) so destructive tests (revocation, deletion, rotation) don’t touch real users. If only prod is available, use throwaway accounts and coordinate.
- Provide **≥3 paired test devices** (a Mac host + iOS + Android) so two-device flows (pairing, trust-promotion, revocation+rotation, media, approvals) can be exercised end-to-end — several controls (rotation, wire-approval, attestation) only manifest across devices.
- A **web-console** test login (`app.burnbar.ai`) with a native device available to approve the browser vault-wrap.
- Test **provider credentials** (a low-value API key) to exercise the credential-storage / KMS path and the gateway/model lane.

## 4. Credentials & access needed

- Source access at the pinned commit (`5416ef780`), incl. the **vendored Hermes agent source** at `bdb830070` and the ratchet spec / Android iroh AAR (out-of-repo — see [`open-questions.md`](open-questions.md) Q11/Q12).
- Read access to **deployed evidence** for the items in `open-questions.md` §1 (App Check enforcement, PITR/backups, alert channels, Remote Config values, live Functions revision, IAM/KMS policy, branch protection, bucket bindings) — *or* the operator runs the named `scripts/ops/verify-*` / `commercial-launch-gate.mjs` verifiers and shares output.

## 5. Build & run

Polyglot build (SwiftPM/Xcode for Apple targets, Gradle for Android, Node/TS for Functions, Cargo for the iroh crates). Firestore/Storage rules run under the Firebase emulator (`firestore-rules-tests/`). The Mac app is Developer-ID signed + notarized; the daemon runs under launchd. Ask the operator for the current `Makefile`/CI entrypoints; CI workflows in `.github/workflows/` show the canonical build/test/deploy lanes.

## 6. Threat-model summary

106 threats (2 Critical, 21 High, 41 Medium, 34 Low, 8 Info) — [`threat-register.csv`](threat-register.csv) / [`threat-register.md`](threat-register.md). 14 headline claims: 4 Defensible, 10 Partial, 0 Not-defensible — [`security-claims.md`](security-claims.md). Adversary model and attack trees in [`abuse-cases.md`](abuse-cases.md). The dedicated agentic-AI model ([`agentic-ai-threat-model.md`](agentic-ai-threat-model.md)) is the most important read.

## 7. Where expert attack time pays most (our suggestions)

1. **Cloud-MITM of iroh pairing** (T-TRN-01): can you substitute the host key at/after first pairing and redirect the control channel? Is the independent E2E layer truly independent of the cloud-supplied identity?
2. **Injection → action in a granted session** (T-AI-01/02, T-TOOL-02): drive a Trusted/YOLO session via a hostile webpage/AX tree/tool output into a shell/desktop action without re-approval.
3. **Grant/approval spine**: try to forge/replay an OS-auth proof across restarts; exploit the SE-P256 vs ed25519 step-up divergence (C7); break envelope canonicalization or counter persistence.
4. **Rules vs callable authority**: same-path envelope transplant/rollback (RR-8), `cloud_vault_key_wrappers` delete availability attack, workspace path squatting, root-doc gaps.
5. **Daemon local domain**: binary swap, peer-auth, privileged-input lane, TCC interplay.
6. **Gateway/relay cross-language divergence**: Swift/Kotlin/Python HPKE/AAD/downgrade (v2 floor, `senderSetComplete` legacy fallback).
7. **Supply-chain PR-time bypass**: AAR swap, gitlink variants, mutable-tag/no-op-gate gaming, direct-push.

## 8. Known issues we are disclosing up front

The Critical/High set in [`README.md`](README.md) and the roadmap blockers (A1–A5 in [`mitigation-roadmap.md`](mitigation-roadmap.md)): iOS TOFU pairing key; YOLO/unsandboxed-shell injection-to-RCE; daemon code-sign==authz + unsandboxed; unwrapped CU/oracle/CLI content; client Sentry unscrubbed; iOS keys not SE-bound; VoIP push leakage + erase gap; CLI revoke≠kill; cloud authz soft spots; supply-chain pinning/cargo-deny/CODEOWNER. Plus the doc-drift list (retired Redis/WSS still cited; SQLCipher prose; activation-parity CI wiring) and the deployed-state UNKNOWNs in `open-questions.md`.

## 9. Security claims we want validated

Primarily the four **Defensible** claims (C1 current-Gateway-body confidentiality, C4 PoP-required, C10 provider-cred KMS custody, C14 honest no-Signal-claim) and the **Partial** claims’ exact caveat boundaries (C2/C3 legacy/metadata edges, C5 revocation window, C6 Trusted-mode boundary, C8/C9 first-pairing TOFU, C11 tenant isolation, C12 at-rest freshness, C13 client-telemetry). For each, [`security-claims.md`](security-claims.md) gives the safe vs unsafe wording — we want confirmation the safe wording is defensible and the unsafe wording is correctly rejected.

## 10. Questions for Cure53

- Is the **first-pairing TOFU** acceptable for the product’s threat model, or must a verified safety-number be mandatory before any control action?
- Is **Trusted/YOLO auto-dispatch** an acceptable, clearly-consented design, or should high-impact action classes always re-approve?
- Does the **SE-signature-as-presence** substitution for the explicit single-use proof (C7) meet your bar for shell/desktop grants?
- Is the **defense-in-depth-only** untrusted-content wrapping sufficient given current models, or do you consider hard data/instruction isolation a launch requirement?
- For a **solo-operator** product, what is the minimum supply-chain/governance bar (separation of duties, deploy gating) you would require before sign-off?
