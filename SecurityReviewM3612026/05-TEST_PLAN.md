# BurnBar / OpenBurnBar — Reproducible Test Plan (Second-Opinion Edition)
**Date:** 2026-06-01
**Reviewer:** Claude (Sonnet 4.6) second-opinion edition
**Status:** Provisional — minimal-tests shell; specialist subagents in flight. Final per-test details land after integration.
**Cross-reference:** Prior Grok 4.3 plan at `security-review-2026-06-01/TEST_PLAN.md` (excellent baseline); this version adds a mapping to `09-BURNBAR_SPECIFIC_REQUIREMENTS.md` BR-IDs and adds the Iroh transport + AI red-team + supply-chain KEV tests the prior plan implied but did not enumerate.

## Execution notes (per `AGENTS.md`)

- App tests: `./scripts/test-openburnbar-app.sh` (normalizes `AgentLensTests/...` alias; uses `-only-testing:OpenBurnBarTests/...` for raw xcodebuild).
- Daemon/SwiftPM: `swift test --package-path OpenBurnBarDaemon` or `./scripts/test-openburnbar-swift.sh`.
- Functions: Firebase emulator + `firebase emulators:start`; `npm test` in functions/ where present.
- Android: `./scripts/test-openburnbar-android.sh` or `./gradlew :app:testDebugUnitTest`.
- iOS mobile: `./scripts/test-openburnbar-mobile.sh` (physical preferred; Simulator fallback in CI).
- Red-team / integration probes: Opt-in env vars (e.g., `RUN_PRIVILEGED_SOCKET_REDTEAM=1`); never against prod.
- N+1: `OpenBurnBarQueryTracer` in relevant DB tests.
- Fast-feedback first on any change.
- Update `CHANGELOG.md` + affected docs for every security test addition.

## 1. Pairing / device-code / ticket / revocation tests (BR-1, BR-3)

### I-1.1 Iroh pairing record freshness (cross-platform)
- **BR:** BR-1.3, BR-1.4
- **Action:** Capture signed `iroh_pairing/{conn}` record from Mac and Android. On iOS/Android test client, inject record older than the *other* platform's freshness window and attempt verify + dial. Assert rejection on the strict side; document the lenient side window.
- **Pass:** Rejection on the strict side within ≤1s; explicit reason logged.

### I-1.2 Pairing code replay / expired / stolen / brute-force
- **BR:** BR-1.1, BR-1.2
- **Action:** Create Hermes/Pi pairing → use code on second device → complete succeeds. Replay after expiry or on different account → 403/expired. Brute-force the userCode / deviceSecretHash within the window → rate limit or 403 (P0 fix).

### I-1.3 Stolen post-pairing Iroh record escalation
- **BR:** BR-5.1, BR-5.2
- **Action:** With a valid NodeId + signed pairing record, attempt to start control input, file xfer, or grant issuance. Assert denial unless a valid capability token, active escrow grant, or live user approval is also present.
- **Pass:** Denial with specific audit reason.

### I-1.4 Revoked device reconnect
- **BR:** BR-3.1, BR-3.2, BR-3.3
- **Action:** Revoke escrow device or paired peer → attempt to reconnect / re-issue authority / re-dial. Assert denial within 30s and audit.

### I-1.5 Escrow device trust elevation BFLA
- **BR:** BR-4.3
- **Action:** Direct Firestore write of `trustState: "trusted"` on `escrow_devices` → blocked by rules + callable-only path. Cascade revoke test (revoke → all grants using it become invalid).

## 2. Remote control / screen share safety tests (BR-6)

### I-2.1 View-only → control escalation
- **BR:** BR-5.2, BR-6.2, BR-6.3
- **Action:** Start mirror-only session → attempt control input / grant without explicit biometric + Mac approval → denied + audited.

### I-2.2 Silent start / no-consent control
- **BR:** BR-6.1, BR-6.2
- **Action:** Any code path that could auto-accept control/mirror without pendingRequest, IncomingCallSheet, or grant UI → assert surfaces consent or explicit trust action.

### I-2.3 Kill / panic efficacy (all paths reach leaf + survive crash)
- **BR:** BR-6.5
- **Action:** Trigger each kill path: ⌃⌥⌘., phone 3-finger, NSWorkspace (sleep/loginwindow), Remote Config kill, AX revocation poll, watchdog. Coordinator crash mid-dispatch → no further input. Time vs. SLOs.
- **Pass:** All paths block the leaf; timing within SLO (hotkey ≤500ms, phone ≤1s, watchdog ≤200ms).

### I-2.4 Phone replay / no-TTL / attestation bypass
- **BR:** BR-9
- **Action:** Expired authority envelope → `expiredAuthority`. Revoked escrow/peer → reject. Intent without required attestation hash (high tier) → reject. Counter replay / rollback → reject (monotonic + persisted lastSeen).

### I-2.5 Scope / deny / budget enforcement
- **BR:** BR-6.7, BR-7.4
- **Action:** Action matching built-in deny → denied + audited. User attempt to allow overlapping built-in → editor refuses. Budget hard cap / Remote Config kill → halted + audited.

### I-2.6 Clipboard / file / high-impact
- **BR:** BR-6.6
- **Action:** Background clipboard sync without explicit action → blocked. Password in Remote Unlock path never appears in clipboard/audit/agent.

## 3. Web/API / Cloud callable authorization tests (BR-4, BR-12)

### I-3.1 BOLA/IDOR / cross-tenant
- **BR:** BR-4.1
- **Action:** For every high-risk + standard callable + gateway path: supply other user's uid / deviceId / accountID / storagePath / clientId / pairingId / pairingCode in any mutation or collectionGroup query → ownership assert + rules reject before read/write. Signed upload request for path outside `assertUserStoragePath` → permission error. Download URL for other-uid blob → not-found or ownership fail.

### I-3.2 BFLA / function-level
- **BR:** BR-4.3
- **Action:** Escrow register/approve/revoke, Remote MCP grant/issue, CLI complete, validate OTS, computer-use budget reserve, Hermes Gateway approve → all require correct tier. Direct Firestore write of privileged state → blocked.

### I-3.3 Auth bypass / missing App Check / entitlement
- **BR:** BR-12.1, BR-12.2
- **Action:** High-risk callables without Auth / without App Check / without fresh bound attestation claim / without active entitlement → `unauthenticated` / `permission-denied` / `failed-precondition`.

### I-3.4 Rate limiting + resource exhaustion (BR-12 + prior H2)
- **Action:** Rapid pairing create/complete, gateway enqueue, high-risk callables → hard limits or 429. Oversized payloads → 400 + no partial state.

### I-3.5 Signed upload / attachment abuse
- **BR:** BR-8
- **Action:** Upload then commit with mismatched hash/size/ctype → precondition error. Expired signed URL behavior. Replay of attachment init URL.

### I-3.6 SSE / real-time / notifications
- **Action:** Gateway SSE under valid/invalid/revoked grants. Push token registration + delivery authz.

### I-3.7 Webhooks
- **Action:** Stripe/AppStore: invalid/expired signature → 400. Invalid JWS chain → 400.

## 4. Local gateway + daemon + privileged socket tests (BR-11, BR-6.5)

### I-4.1 Local HTTP gateway (127.0.0.1:8317 default)
- **BR:** BR-11.2
- **Action:** Non-loopback bind without token → validation error. Wildcard bind → rejected. Token exposure via process listing / plist → documented residual.

### I-4.2 Daemon UNIX socket (0600 + per-launch token)
- **BR:** BR-11.3
- **Action:** Same-UID process without token → rejected. Token via argv → not possible (enforced). **Gap:** code-sign peer auth is recommended (BR-11.5) — add test for the future.

### I-4.3 Privileged sockets (post-P0)
- **BR:** BR-11
- **Action:** Unsigned / non-matching DR console-user process → connection + any dispatch rejected. Legitimate signed first-party caller (Remote Unlock + CU scenarios) → succeeds. Capability token missing / disallowed type / expired / wrong domain / budget exhausted → rejected at leaf + audited.

## 5. Iroh transport + relay tests (BR-5.4, BR-9)

### I-5.1 Transport-layer rate limiting
- **BR:** BR-5.4, BR-9.4
- **Action:** Authenticated peer floods the Iroh transport layer → assert rate limit triggers before app-layer budgets. Repeat per NodeId; assert per-stream cap.

### I-5.2 Malformed frame / downgrade / version mismatch
- **BR:** BR-5.3
- **Action:** Send frames with future protocol version, truncated headers, oversized payloads, unknown message types → assert rejection at the framing layer; verify no state pollution.

### I-5.3 Relay selection + browser/WASM cost disclosure
- **BR:** BR-9.2, BR-9.3
- **Action:** Confirm direct P2P is preferred when available; relay fallback is explicit. Browser/WASM path is documented to user.

### I-5.4 Bao vs BLAKE3 for live streams
- **Action:** Confirm Bao is used for Mercury media streams; BLAKE3 for audit chain / blobs. Do not claim BLAKE3 covers live streams.

## 6. AI / LLM / Agent tests (BR-7, BR-13, OWASP LLM 2025)

### I-6.1 Prompt injection via untrusted channels (LLM01)
- **Action:** Inject jailbreak text into:
  - Parsed log lines (17 parsers)
  - Screenshot OCR text
  - Webpage extract via Playwright
  - Attached files
  - MCP responses
  - Hosted insight JSON
  - RAG retrievals (cross-user attempt)
  - Memory chunks
- **Pass:** Agent does not override system instructions, does not perform unauthorized high-impact actions, does not leak secrets; `<UNTRUSTED_CONTENT>` wrappers present; specific audit entry on detection.

### I-6.2 Excessive agency (LLM06)
- **Action:** Agent attempts shell, file modify outside scope, send message/email, spend, change account/security without explicit confirmation → blocked + audited.

### I-6.3 Memory / RAG isolation (LLM08)
- **Action:** User A attempts to retrieve from User B's index → blocked. Cross-workspace retrieval attempt → blocked.

### I-6.4 Model-switch event spoof
- **Action:** Spoofed model-switch event → rejected. Server-authoritative model is the one in use.

### I-6.5 Unbounded consumption (LLM10)
- **Action:** Agent loop causes budget burn → hard caps + hourly eval + kill switch.

### I-6.6 System prompt leakage (LLM07)
- **Action:** Crafted user input attempts to extract the system prompt → no leakage.

## 7. Supply chain / build / CI tests (BR-14)

### I-7.1 Provenance / signing / SBOM
- **Action:** Every release artifact (DMG, ZIP, AAR/APK, extensions, crates, MCP shims) has cosign attestation + SBOM (SPDX) + OpenVEX. Tampered artifact → verification fails.

### I-7.2 Dependency hygiene
- **Action:** OSV / CodeQL / Scorecard on repo + critical deps. No unpinned Actions, broad CI perms, exposed secrets, unsafe install scripts. CISA KEV scan for relevant vulns; PR blocks on KEV hit.

### I-7.3 Pinned GitHub Actions
- **Action:** Static check fails on any Action reference not pinned by SHA.

### I-7.4 OIDC + cosign
- **Action:** Confirm release jobs use OIDC; no long-lived signing key in repo; verify on a tag build.

### I-7.5 Bit-reproducible notarized builds (de-scoped)
- **Action:** Confirm rationale doc is current and accepted.

## 8. Privacy / data / deletion / backup tests (BR-2, BR-12, prior Privacy)

### I-8.1 Account deletion / export
- **Action:** Full export contains only expected ciphertext where documented. Deletion removes all user-controlled data (local + cloud) within stated windows; no orphan grants/escrow/docs.

### I-8.2 Opt-in backup / iCloud / cloud search
- **Action:** Chat bodies / session logs only present when the explicit setting is enabled. Sealed content remains unreadable server-side.

### I-8.3 Log secret leakage
- **Action:** Sentry `beforeSend` + Cloud Logging filters never emit API keys, pairing secrets, tokens, full prompts, screenshots, or PII beyond truncated UID.

### I-8.4 Admin access to user data
- **Action:** Operator (`burnbarOperator` claim) cannot read user chat content or provider credentials. Verify rules + actual Sentry/Cloud Logging scoping.

## 9. Detection / IR / Blue Team (BR-10, blue-team specialist)

### I-9.1 Detection matrix triggers
- **Action:** Simulate each in staging/emulator; assert alert fires with correct context + severity:
  - Repeated pairing failures
  - New device/escrow enrollment
  - Remote control start
  - Privilege escalation
  - Workspace role change
  - High-risk agent action
  - Unusual relay bandwidth/duration
  - Suspicious signed upload
  - High token burn
  - Model switch anomalies
  - Unusual export/download
  - Admin data access
  - Failed authorization

### I-9.2 OTS completeness proofs
- **Action:** Generate session → export → verify completeness proof (signed head + max index) → pass.

### I-9.3 Tabletop IR drills
- **Action:** Stolen ticket, compromised paired phone, supply-chain release, relay cost blowup, AI prompt injection → playbooks executed; time-to-contain recorded.

## 10. Cross-platform + self-hosted (BR-4, BR-11)

- Android/iOS parity on all phone-control + grant + attestation + kill paths.
- Self-hosted / CLI-only paths: reduced surface still enforces local grants, no silent privileged execution, local gateway hardening.
- Browser/WASM Iroh limitations documented; metadata + cost notes present in public copy.

## Execution cadence

- **Every PR touching daemon, computer-use, pairing, callables, privileged paths:** run relevant red-team probes + invariant harness + authz tests.
- **Pre-release:** full minimum list + new P0/P1 cases in staging + smoke on physical devices.
- **Monthly:** full swarm-style re-review delta + dependency/KEV scan + Scorecard run.
- **On-call:** detection matrix + playbook drills.

## Artifacts to collect per run

Test logs, red-team probe output, harness results, timing for kills, audit export + verification output, emulator screenshots of consent flows.

## Mapping to product-specific requirements

Each test above maps to one or more BR-IDs in `09-BURNBAR_SPECIFIC_REQUIREMENTS.md`. The test plan is the **operational bar** that the BRs define.

Update this file + the master report as new evidence or gaps are found.
