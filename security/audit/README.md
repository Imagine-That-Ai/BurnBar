# Security Audit — OpenBurnBar

**Run date:** 2026-06-16
**Run mode:** FULL_BASELINE
**Commit/branch:** `60faa70227` on `security/run-09-privacy-invariants-hardening`
**Auditor:** Automated security audit (codebase-grounded)
**Confidence:** Medium-High

---

## Product Overview

OpenBurnBar is a native macOS menu bar app (with iOS, Android, VS Code extension, and web console) that tracks token usage and cost across AI coding agents (Claude Code, Factory Droid, Codex, Kimi, MiniMax, etc.). It includes a Computer Use subsystem that lets AI agents control a Mac with multi-layered trust modes and audit chains, a Hermes real-time communication layer (iroh P2P with Firestore fallback), CloudVault end-to-end encrypted cloud sync, and Stripe/Apple/Google payment processing.

---

## Current Score

| Metric | Value |
|--------|-------|
| **Final Score** | **71 / 100** |
| Raw Score | 72 |
| Confidence | Medium-High |
| Auditor Readiness | Focused security review ready |
| Highest Applied Cap | Engineering Maturity Cap (Max 79) |

---

## Top Risks

1. **FINDING-001 (Medium-High):** Phone-side trust mode picker presents all modes including Trusted, violating documented "downgrade-only" invariant
2. **FINDING-002 (Medium):** CloudVault first-vault creation and rotation quorum not server-mediated (M-008 residual)
3. **FINDING-003 (Medium):** First-contact iroh safety-number confirmation default-off (M-018 residual)
4. **FINDING-004 (Medium):** CLI executable provenance from user-writable directories without signing policy (M-030 residual)
5. **FINDING-005 (Medium):** App Check attestation max-age is 30 days (M-031 residual)

---

## Top Blockers (Before External Audit)

1. Live verification of deployed Firestore/Storage rules and Functions hashes
2. Firestore TTL policy materialization in production (deploy-time readback gate exists, must run)
3. Clean standard-user Mac smoke test for Remote Unlock and panic-halt
4. Shipped client telemetry DSN and Sentry org PII settings readback
5. Git history purge decision for committed security evidence (M-004)

---

## Immediate Next Actions

1. Fix phone-side trust mode UI to filter to downgrade-only (`PhoneControlOptionSheet.swift`)
2. Run `verify-firestore-ttl-state.mjs` against production on next deploy
3. Complete clean-Mac install proof for Remote Unlock / panic-halt
4. Read back shipped macOS/iOS artifacts for Sentry DSN + scrubber path
5. Decide on git history purge vs. acceptance for M-004

---

## Claims Safe to Make Today

- "Session content is end-to-end encrypted via AES-256-GCM with path-bound AAD"
- "Object-level authorization is enforced and tested on every callable endpoint"
- "Computer Use agent actions require approval in manual mode; audit chain is tamper-evident"
- "No plaintext secrets are committed to the repository"
- "Supply chain uses SHA-pinned GitHub Actions with SBOM, SLSA attestations, and triple secret scanning"

## Claims to Avoid Today

- "End-to-end encrypted" for iroh first-contact (safety-number compare not default-on)
- "Phone can only downgrade trust" (UI presents all modes)
- "Signal encryption is live" (activation gates remain; readiness-gated only)
- "Fully audited" or "independently verified" (no external audit has occurred)
