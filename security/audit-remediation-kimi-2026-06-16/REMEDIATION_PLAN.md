# OpenBurnBar Security Remediation Master Plan
**Auditor:** Kimi Code CLI (kimi)
**Date:** 2026-06-16
**Source audits:** security/audit-kimi/, security/audit/glm-5.2/, security/audit/opus-4-8-1m/, /private/tmp/burnbar-security-audit-main-SDM6Rq/security/audit/codex-gpt-5/, security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md
**Target:** SOTA 2026 security, privacy, and operational readiness.

---

## 1. Verified State Summary

| ID | Finding | Severity | Status (2026-06-16) | Owner | Score Impact |
|---|---|---|---|---|---|
| FINDING-001 / T-DMN-04 | Daemon local-auth proof verifier not wired in production | High | **OPEN** | Daemon / Computer Use | -12 |
| FINDING-002 | Daemon Computer Use synthetic entitlement / killSwitch=false | Medium | **OPEN** | Computer Use | -5 |
| FINDING-003 | Stripe redirect URL localhost-substring bypass | Medium | **OPEN** | Functions / Billing | -4 |
| FINDING-004 | Firestore App Check deployment state not repo-verified | Medium | **PARTIAL** (smoke script exists, not gate-integrated) | Cloud/Ops | -5 |
| FINDING-005 | Public HTTP endpoints lack product-layer rate limits | Medium | **OPEN** | Functions / Cloud Ops | -3 |
| FINDING-006 | Data deletion audit best-effort | Medium | **OPEN** | Privacy / Functions | -3 |
| FINDING-007 | Production deploy still supports long-lived secret fallbacks | Low | **OPEN** | Platform / Release | -3 |
| FINDING-008 | SQLCipher key creation continues after Keychain persistence failure | Low | **OPEN** | macOS data store | -2 |
| FINDING-009 | Signal/E2EE privacy claims wording | Low | **FIXED** (claim lint in CI) | Product / Security | -2 → 0 |
| FINDING-011 | Signal prekey directory allows direct client writes | Medium | **OPEN** (by-design; needs hardening decision) | Crypto / Cloud | — |
| FINDING-013 / M-001 | Remote Unlock helper not bundled | High | **FIXED** | macOS platform | — |
| FINDING-014 / M-005 | session_logs rule fail-open (denylist) | High | **FIXED** | Cloud security | — |
| FINDING-015 / M-007 | CloudVault path-bound AAD partial | High | **OPEN** (safe subset ready; defer bricked writers) | Crypto / Cloud | — |
| FINDING-016 / M-023 | agentNotifications sweeper logs full UID | Medium | **FIXED** | Functions | — |
| FINDING-017 / M-037 | Phone-control cross-pairing hijack | Medium | **FIXED** | iroh / Computer Use | — |
| FINDING-018 / M-028 | Capability token not bound to HID presenter | Medium | **FIXED** | Computer Use security | — |
| FINDING-019 / M-006 | Android iroh cached-key / plaintext pin store | Medium | **FIXED** | Android | — |
| FINDING-001-kimi | Local SQLite plaintext by default | Critical | **OPEN** (build-level; requires SQLCipher codec vendoring) | Core platform | — |
| FINDING-002-kimi | App/daemon unsandboxed | Critical | **ACCEPTED RISK** | macOS platform | — |
| FINDING-003-kimi | Computer Use adversarial tests incomplete | High | **PARTIAL** | Computer Use | — |
| FINDING-004-kimi | Prompt / RAG injection defenses partial | High | **PARTIAL** | AI / agent | — |
| FINDING-008-kimi | Local MCP server exposes raw search snippets | Medium | **OPEN** | MCP / integrations | — |
| OPUS-F-005 | accountDeletion.ts logs UID + storage path | Low | **OPEN** | Functions | — |
| OPUS-F-006 | buildFcmMessage ships stable thread_id correlator | Low | **OPEN** | Functions / Privacy | — |
| OPUS-F-012 | CODEOWNERS lacks security-sensitive tree rules | Low | **OPEN** | Platform | — |

---

## 2. SOTA 2026 Design Principles

1. **Fail-closed by default.** Every high-risk action refuses to proceed if a security control cannot be verified.
2. **Defense-in-depth.** No single control is treated as sufficient; controls are layered and independently testable.
3. **Continuous verification.** Security claims are enforced in CI and, where possible, by automated production probes.
4. **Least-privilege identity.** Long-lived credentials are eliminated in favor of OIDC/WIF, short-lived tokens, and capability scopes.
5. **Input provenance.** All untrusted content reaching an LLM is structurally separated, tagged, and wrapped.
6. **Allowlist > denylist.** URL hosts, Firestore fields, capabilities, and tool scopes use explicit allowlists.
7. **Transparent residual risk.** Accepted risks are documented, measured, and periodically re-audited.

---

## 3. Remediation Streams

### Stream A — Local authorization and agentic safety (P0)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| A.1 | Daemon local-auth proof verifier | Wire `DaemonLocalAuthProofVerifier` with a persistent pinned-key/replay store; fail closed when store or proof is unavailable. | Production daemon rejects missing/stale/replayed/wrong-intent/unsigned proofs; tests cover each case. |
| A.2 | Daemon synthetic entitlement/kill switch | Replace synthetic context with live entitlement snapshot + Remote Config kill-switch resolver in daemon. | Daemon denies browser Computer Use when kill switch is active or entitlement is inactive. |
| A.3 | Computer Use adversarial tests | Parameterized abuse-case matrix for all 13 tool kinds, trust modes, scope-rule precedence, deny regions, kill-switch latency. | CI test target asserts every abuse case is blocked. |
| A.4 | Phone HID binding | Keep current A→A binding; add cross-pairing negative tests. | A-bound token presented by B-device rejects. |

### Stream B — Cloud functions and API hardening (P0/P1)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| B.1 | Stripe redirect URL validation | Exact loopback allowlist (`localhost`, `127.0.0.1`, `[::1]`); HTTPS-only for all non-loopback; optional production origin allowlist; block parser-differential bypasses. | Unit tests reject `localhost.attacker.example`, `malocalhost.com`, IP obfuscation, userinfo tricks. |
| B.2 | Public endpoint rate limits | Sliding-window counter per identity (IP + UID/App Check where available) using Firestore; inventory in endpoint catalog; default limits for all public HTTP routes. | Every public endpoint has a declared limit; CI inventory check fails on unbounded public route. |
| B.3 | Callable rate limits | Per-callable token-bucket / sliding-window for expensive operations; integrate into `onCallProduction` wrapper. | High-risk callables (export, deletion, provider connect, search) enforce per-UID limits. |
| B.4 | Deletion audit durable | Required pre-delete audit intent; post-delete completion record; fail closed if intent cannot be persisted. | Audit failure blocks deletion; every successful deletion has durable intent + completion records. |
| B.5 | Account deletion log scrubbing | Route all account-deletion logs through `logWarn`/`logError` with hashed UIDs; remove raw UID/path strings. | Privacy-invariant gate detects no raw UID in accountDeletion logs. |
| B.6 | FCM thread_id correlator | Remove stable `thread_id` from push payloads or add to privacy-invariants gate with documented rationale. | Gate covers `buildFcmMessage`; no stable conversation correlator in push data unless accepted. |

### Stream C — Firestore rules and cloud crypto (P1)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| C.1 | Firestore App Check verifier | Production probe script integrated into ops-readiness gate; attestation max-age policy documented; alert if enforcement off. | Release gate fails if Firestore App Check enforcement is off or unknown. |
| C.2 | Signal prekey direct writes | Tighten rules to server-only for prekey directory; callable becomes sole write path; migration window for existing client writes. | Rules tests assert direct client prekey write fails. |
| C.3 | CloudVault path-bound AAD | Apply `validPathBoundSealedPayloadForUser` to `conversations` and `mobile_assistant_chats` now; migrate `chat_threads`/`cli_sessions` writers to path-bound AAD before tightening rules. | Relocated ciphertext fails; correct AAD succeeds. |

### Stream D — Local data protection (P1/P2)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| D.1 | SQLCipher key persistence fail-closed | Throw typed error on `SecItemAdd` failure; do not create encrypted DB with unpersisted key; surface recovery path. | Injected Keychain failure aborts SQLCipher setup; test passes. |
| D.2 | SQLCipher codec vendoring | Vendor SQLCipher amalgamation / XCFramework so `PRAGMA cipher_version` is non-empty in release builds; migrate plaintext DBs on first launch. | Release build links active SQLCipher; regression test verifies `PRAGMA cipher_version`; plaintext fallback rejected when encryption requested. |

### Stream E — Supply chain and CI/CD (P1/P2)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| E.1 | WIF-only production deploy | Remove `GCP_SA_KEY`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`, and `FIREBASE_TOKEN` fallback paths; enforce OIDC/WIF with workload identity provider. | Production deploy workflow fails if WIF unavailable; static CI policy blocks legacy secret references. |
| E.2 | CODEOWNERS security trees | Add explicit path rules for `functions/src/security`, `functions/src/callables/stripe*`, `scripts/ci`, `Vendor/libsignal`, `firestore.rules`, `project.yml`, etc. | PRs touching security-sensitive trees require review by security/platform code owners. |
| E.3 | Release artifact hardening | Post-release canary installs DMG/APK on clean runner, verifies signature, known-good behavior, and cosign attestation. | Canary job runs on every release. |

### Stream F — AI/Agentic hardening (P1)

| Item | Finding | SOTA 2026 approach | Acceptance criteria |
|---|---|---|---|
| F.1 | Uniform untrusted-content wrapping | Wrap parser output, MCP results, session-log formatter output, and remaining system-prompt sections; attach provenance metadata. | Red-team payloads stay inside wrappers; no raw untrusted text reaches model context. |
| F.2 | MCP server snippet hardening | Wrap search snippets with `<UNTRUSTED_CONTENT>` + provenance; add user-visible audit log of MCP reads. | MCP server returns wrapped snippets; UI shows recent MCP queries. |
| F.3 | Model allowlist enforcement | Enforce model selection against `openburnbar_models.json` / `HermesModelID` allowlist; reject unknown or switched models. | Unknown model IDs fail with validation error. |

---

## 4. Score Targets

| Milestone | Required work | Expected final score |
|---|---|---|
| +10 points | A.1, B.1, C.1 | ~69 |
| 70 (external audit ready) | A.1, A.2, B.1–B.4, C.1, D.1 | ~72 |
| 80 | Above + B.2, B.5–B.6, C.2–C.3, E.1–E.2, F.1 | ~80 |
| 90 | Above + A.3, D.2, E.3, F.2–F.3, production access review evidence | ~90 |
| 95+ | Independent external review, stable across two reruns, all findings fixed or formally accepted | 95+ |

---

## 5. Implementation Order

1. **Immediate (this run):** B.1, B.4, B.5, B.6, B.2 inventory, E.2, C.1 verifier, D.1, A.1 wiring (with stub store), F.1/F.2 MCP wrapping, tests.
2. **Next sprint:** A.2 (Remote Config in daemon), B.3 callable rate limits, C.2 Signal rules, C.3 path-bound AAD migration, E.1 WIF-only deploy.
3. **Build-level:** D.2 SQLCipher codec vendoring.
4. **Continuous:** A.3 adversarial matrix, F.3 model allowlist, E.3 release canary.
