# Security Audit — OpenBurnBar

**Run date:** 2026-06-16
**Run mode:** FULL_BASELINE
**Commit/branch:** `60faa70227` on `security/run-09-privacy-invariants-hardening`
**Model:** GLM 5.2 (Z.ai)
**Auditor:** Automated security audit (codebase-grounded, evidence-backed)
**Confidence:** Medium-High
**Previous audit:** `security-audit/merged/FINAL_REPORT.md` (2026-06-14, 40 root-cause findings across 9 model runs)

---

## Product Overview

OpenBurnBar is a cross-platform AI agent observability and control platform. Core capabilities:

- **Token/cost tracking:** Parses local session logs from Claude Code, Codex, Factory Droid, Kimi, MiniMax, and other AI agents on macOS/iOS/Android
- **CloudVault:** End-to-end encrypted cloud sync of session content using AES-256-GCM with path-bound AAD; vault key never leaves trusted devices
- **Computer Use (Phases 8-13):** AI agents control a Mac through Virtual HID with three trust modes (Manual/Step/Trusted), SHA-256-linked audit chains, three+ panic-kill paths, budget caps, and capability tokens bound to escrow device identity
- **Hermes:** Real-time communication (messaging, media, screen-share, calls) via iroh P2P with Firestore fallback
- **Hosted quota:** Server-side provider API quota refresh using KMS-encrypted credentials
- **Payments:** Stripe, Apple App Store, Google Play Billing subscriptions

---

## Current Score

| Metric | Value |
|--------|-------|
| **Final Score** | **71 / 100** |
| Raw Score | 72 |
| Confidence | Medium-High |
| Auditor Readiness | Focused security review ready |
| Highest Applied Cap | Engineering Maturity Cap (Max 79) |

**Rationale:** The codebase demonstrates mature, defense-in-depth architecture with strong crypto, comprehensive BOLA testing, and a sophisticated supply chain. The score is capped at 79 by: (1) the kill-switch watchdog socket lacking peer auth, (2) the local-auth-proof verifier being dormant in production, (3) several product-decision-gated residuals from the prior audit, (4) live verification gaps (TTL materialization, deployed rules drift, clean-Mac proof).

---

## Top Risks

| Rank | ID | Severity | Title |
|------|----|----------|-------|
| 1 | FINDING-001 | **High** | Kill-switch watchdog socket has no peer authentication; root can silently disarm panic-halt |
| 2 | FINDING-002 | **Medium-High** | Local-auth-proof verifier hardcoded to nil in production daemon; high-risk Computer Use RPCs lack independent phone-proof re-verification |
| 3 | FINDING-003 | **Medium-High** | Phone-side trust mode picker presents all modes including Trusted, violating documented "downgrade-only" invariant |
| 4 | FINDING-004 | **Medium** | CloudVault first-vault creation and rotation quorum not server-mediated (M-008 residual) |
| 5 | FINDING-005 | **Medium** | First-contact iroh safety-number confirmation not default-on (M-018 residual) |
| 6 | FINDING-006 | **Medium** | CLI executable provenance from user-writable directories without signing policy (M-030 residual) |
| 7 | FINDING-007 | **Medium** | App Check attestation max-age is 30 days (M-031 residual) |
| 8 | FINDING-008 | **Medium** | CloudVault path-bound AAD not enforced on chat_threads and cli_sessions (M-007 partial residual) |
| 9 | FINDING-009 | **Medium** | SSRF guard does not pin DNS (TOCTOU / DNS rebinding / redirect gap) |
| 10 | FINDING-010 | **Medium** | Stable APNs/FCM routing IDs visible to push providers (M-021 residual) |

---

## Top Blockers (Before External Audit)

1. Fix kill-switch watchdog socket authentication (FINDING-001) - add `PrivilegedPeerAuthenticator` to watchdog
2. Wire local-auth-proof verifier in production daemon (FINDING-002) - requires phone-key store + app-side proof
3. Fix phone trust mode UI to filter to downgrade-only (FINDING-003) - one-file Swift change
4. Live verification of deployed Firestore/Storage rules and Functions hashes
5. Firestore TTL policy materialization in production
6. Clean standard-user Mac smoke test for Remote Unlock and panic-halt
7. Shipped client telemetry DSN and Sentry org PII settings readback
8. Git history purge decision for committed security evidence (M-004)

---

## Immediate Next Actions

1. **FINDING-001:** Add `PrivilegedPeerAuthenticator` codesig gate to `PrivilegedInputKillSwitchWatchdogMain.swift handleClient()` before honoring activate/clear
2. **FINDING-003:** Filter `ComputerUseTrustMode.allCases` in `PhoneControlOptionSheet.swift` to only show modes <= current mode
3. **FINDING-008:** Migrate `chat_threads` and `cli_sessions` writers to emit path-bound AAD, then tighten Firestore rules
4. **FINDING-002:** Implement daemon-side pinned phone-key store and wire the `DaemonLocalAuthProofVerifier`
5. Run `verify-firestore-ttl-state.mjs` against production on next deploy
6. Complete clean-Mac install proof for Remote Unlock / panic-halt

---

## Claims Safe to Make Today

- "Session content is encrypted on-device with AES-256-GCM before cloud upload; the server cannot decrypt session content"
- "Every callable endpoint verifies caller ownership of the requested resource, with CI-enforced BOLA test coverage across 60+ endpoints"
- "Computer Use agent actions require approval in manual mode; the audit chain is SHA-256-linked with a signed terminal entry"
- "No plaintext secrets are committed to the repository; triple secret scanning runs pre-commit and at release"
- "Supply chain uses SHA-pinned GitHub Actions with SBOM, SLSA attestations, cosign signing, and live feed verification"
- "High-risk callables require single-use nonce plus App Check attestation binding"
- "The daemon database is SQLCipher encrypted with a fail-closed self-check"

## Claims to Avoid Today

- "The phone can only downgrade trust" (UI presents all modes - FINDING-003)
- "The kill switch cannot be disarmed by a local attacker" (watchdog socket unauthenticated - FINDING-001)
- "End-to-end encrypted with perfect forward secrecy" for iroh first-contact (safety-number not default-on)
- "Signal encryption is live in production" (activation gated, not yet flipped)
- "Fully audited" or "independently verified" (no external audit has occurred)
- "App Check protects all data access" (Firestore rules do not use `request.app`)
