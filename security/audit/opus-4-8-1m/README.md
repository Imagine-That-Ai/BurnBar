# OpenBurnBar — Security Audit (Opus 4.8 1M lane)

> **Lane note:** Multiple audit lanes run this master prompt concurrently. This package is the **Opus 4.8 (1M context)** lane, self-contained under `security/audit/opus-4-8-1m/`. It does **not** modify the shared `security/audit/*` files written by other lanes, nor the `security-audit/` (06-14 multi-model) lineage. Finding IDs are namespaced `OPUS-F-NNN` / `OPUS-U-NNN` to avoid colliding with the `M-001…M-040` (06-14) and `FINDING-NNN` (concurrent lane) schemes; cross-references to those schemes are given inline.

- **Product:** OpenBurnBar / BurnBar — local-first macOS menu-bar app for AI-agent provider quota/usage tracking; opt-in Firebase cloud sync; iOS + Android apps; iroh P2P transport; Hermes LLM-provider gateway; Computer Use (agentic Mac automation); server-blind "Cloud Vault."
- **Repository:** `Imagine-That-Ai/BurnBar`
- **Run mode:** FULL_BASELINE (this lane's first run)
- **Commit / branch:** `60faa70227` on `security/run-09-privacy-invariants-hardening` (+126 dirty working-tree files)
- **Date:** 2026-06-16
- **Method:** Code-grounded verification by 7 parallel domain agents (authz/BOLA, crypto/secrets, billing, privacy/logging, desktop/daemon/update, AI/agentic, supply-chain/CI-CD) + direct rule reads, cross-checked against the repo's existing threat models and `DILIGENCE_REPORT_2026-06-11.md`. Claims verified against code, not trusted from docs.

## Score

| | |
|---|---|
| **Raw weighted** | **75 / 100** |
| **Final after caps** | **73 / 100** |
| **Binding cap** | Engineering Maturity Cap (≤79, non-binding ceiling) + run-1 confidence-gate hold |
| **Confidence** | Code: High · Deployed/operational state: Low → overall Medium-High |
| **Auditor readiness** | Strong candidate for external audit at the **code** level; **not yet** full-audit-ready operationally |

## Headline verdict

The **code-level** security posture is genuinely strong and, unusually, **machine-enforced** (deterministic endpoint-authorization catalog with a completeness test; tier-2 runtime BOLA proofs; fail-closed App Check; SHA-pinned signed/notarized/attested release chain; in-code approval gates and panic-kill paths for agentic actions). The two most dangerous findings from the prior internal diligence — **P0-6** (privileged-input credential capture) and **LB-2** (software-update integrity) — are **fixed and verified** on this branch.

The score is held in the low-70s, not higher, because:
1. **Operational effectiveness of several high-value controls is unverifiable from code** (live Firestore TTLs, App Check console enforcement, alert-channel deliverability, production deploy currency, branch-protection ruleset) — see `open-questions.md`.
2. **Two Medium findings remain open** (collaboration artifacts written plaintext to Firestore; macOS crash-scrubber lacks a regression test).
3. **This is run 1** — the confidence gate requires score stability across ≥2 runs before maturity is asserted.

## Top risks (this lane)

| Rank | ID | Title | Severity |
|---|---|---|---|
| 1 | OPUS-F-001 | Collaboration / shared-source artifacts (`body`,`title`,`relativePath`) written **plaintext** to Firestore + keyless content-hash oracle | Medium |
| 2 | OPUS-F-002 | macOS `MacSentryScrubber` + per-install anonymized ID have **no unit test** (iOS twin does) | Medium |
| 3 | OPUS-F-003 | CloudVault path-bound AAD only partial — `chat_threads`/`cli_sessions`/sealed-text surfaces still global AAD (same-account ciphertext relocation) | Low-Med |
| 4 | OPUS-U-001..005 | Deployment/operational state unverified (live TTLs, App Check console, alert deliverability, prod deploy currency, branch protection) | (cap drivers) |

## Verified-fixed since prior lineages (disposition updates)

| Prior ID | Item | Now |
|---|---|---|
| P0-6 (06-11) | Privileged-input `/tmp` credential-capture lane | **FIXED** — per-uid 0700 dir, client-side server-peer auth, `LOCAL_PEERTOKEN`=0x006, launchd supervision restored |
| LB-2 (06-11) | Updater "signature non-emptiness" check | **FIXED** — real Ed25519 verify vs pinned `SUPublicEDKey` + SHA-256 |
| M-005 (06-14) | session_logs fail-open denylist | **FIXED** — `hasOnly` allowlist wired (firestore.rules:651-660) |
| M-025 (06-14) | BOLA tests not executing | **RESOLVED** — tier-2 cross-user tests run in fast-feedback/harness/release |
| CG-1 (06-11) | Coverage-gate gaming | **FIXED** (Swift); minor Android presence-fallback residual (OPUS-F-011) |
| LB-5 (06-11) | Stripe watermark-erase | **FIXED** in code (entitlements.ts:202-207) |
| — | qa.yml secrets / submodule checkout | **FIXED** |

## Immediate next actions

1. Resolve `open-questions.md` OPUS-U-001..005 with operator-side evidence (mostly minutes-to-hours).
2. Triage OPUS-F-001 (seal artifacts vs. document the non-claim in UX) and OPUS-F-002 (add `MacSentryScrubberTests`).
3. Re-run as DELTA_REVIEW after the next production deploy to establish score stability and lift the run-1 hold.

## Files in this package

`audit-state.json`, `repository-map.md`, `security-definition.md`, `architecture.md`, `assets.md`, `security-claims.md`, `authz-review.md`, `crypto-secrets-review.md`, `app-api-review.md`, `privacy-logging-review.md`, `cloud-ops-review.md`, `supply-chain-review.md`, `ai-agentic-review.md`, `threat-register.md`, `threat-register.csv`, `abuse-cases.md`, `findings.md`, `findings.json`, `evidence-map.md`, `security-test-plan.md`, `remediation-roadmap.md`, `security-score.md`, `security-score.json`, `release-gate.md`, `auditor-brief.md`, `open-questions.md`, `rerun-instructions.md`.
