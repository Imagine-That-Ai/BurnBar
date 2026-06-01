# BurnBar / OpenBurnBar SOTA Security Review — Reproducible Test Plan
**Date:** 2026-06-01
**Scope:** All minimum tests from the query + additional high-value cases from completed subagents (Architecture, Web/API, Remote Control). Safe, local-first / emulator / staging only. No production.

**Execution notes (per AGENTS.md):**
- App tests: `./scripts/test-openburnbar-app.sh` (normalizes `AgentLensTests/...` alias; uses `-only-testing:OpenBurnBarTests/...` for raw xcodebuild).
- Daemon/SwiftPM: `swift test --package-path OpenBurnBarDaemon` or `./scripts/test-openburnbar-swift.sh`.
- Functions: Firebase emulator + `firebase emulators:start`; `npm test` in functions/ where present.
- Android: `./scripts/test-openburnbar-android.sh` or `./gradlew :app:testDebugUnitTest`.
- iOS mobile: `./scripts/test-openburnbar-mobile.sh` (physical preferred; Simulator fallback in CI).
- Red-team / integration probes: Opt-in env vars (e.g., `RUN_PRIVILEGED_SOCKET_REDTEAM=1`); never against prod.
- N+1: `OpenBurnBarQueryTracer` in relevant DB tests.
- Fast-feedback first on any change.
- Update `CHANGELOG.md` + affected docs for every security test addition.

## 1. Pairing / Device-Code / Ticket / Revocation Tests (Iroh + Cloud)

- **Iroh pairing record freshness / stale replay (critical cross-platform gap)**:
  - Capture signed iroh_pairing/{conn} record from Mac (or Android).
  - On iOS/Android test client: inject record older than the *other* platform's freshness window (Swift ~3min vs 24h Android/TS) and attempt verify + dial. Assert rejection on the strict side; document the window on the lenient side.
  - Revoke on host → replay pre-revoke record from client. Measure time-to-failure vs freshness + heartbeat.
  - Evidence: Iroh subagent (freshness discrepancy); `IrohRelayPairing.swift:74`, `legacy.ts:316`, Android `IrohRelayPairing.kt:68`; `HermesIrohRelayHostClient.swift` heartbeat.

- **Pairing code replay / expired / stolen / brute-force**:
  - Create Hermes/Pi pairing → use code on second device → complete succeeds.
  - Replay same code after expiry or on different account → 403/expired.
  - Brute-force short window on userCode / deviceSecretHash (CLI Link + Hermes device sessions) → rate limit or 403 (see P0 fixes).
  - Stolen post-pairing iroh_pairing record / NodeId / endpoint → control paths (screen start, input intent, grant) denied without fresh escrow trust + biometric/approval.
  - Revoked device reconnect → all control/escrow grants invalidated; new pairing required.
  - Evidence: functions/src/callables/hermes.ts + piAgent + cliLink.ts; Firestore iroh_pairing/escrow rules; Remote Control subagent + Architecture subagent abuse cases.

- **Escrow device trust elevation BFLA**:
  - Client attempts direct Firestore write of `trustState: "trusted"` on escrow_devices → rules + callable-only path block it (only `approveEscrowDeviceTrust` callable succeeds, high-risk).
  - Cascade revoke test (revoke device → all grants using it become invalid).

## 2. Remote Control / Screen Share Safety Tests (Highest Risk)

- **View-only → control escalation** (mobile → Mac iroh paths):
  - Start mirror-only session (consent + always-allow toggle) → attempt control input / grant without explicit biometric + Mac approval → denied + audited (`.denied` frame + audit entry).
  - Explicit "view-only lock" that survives restart without re-approval.

- **Silent start / no-consent control**:
  - Any path that could auto-accept control/mirror without pendingRequest, IncomingCallSheet, or grant UI → assert surfaces consent or explicit trust action.
  - Hermes Gateway approve → downstream control without additional grant → denied.

- **Kill / panic efficacy (all paths reach leaf + survive crash)**:
  - Global hotkey (⌃⌥⌘.), phone 3-finger, NSWorkspace (sleep/loginwindow), Remote Config kill switch, AX revocation poll, watchdog socket → all block further input at VirtualHID leaf + CGEvent dispatchers.
  - Coordinator crash mid-dispatch → no further input (flag + process death + AX poll); time vs. SLOs (hotkey ≤500ms, phone ≤1s, watchdog ≤200ms).
  - Post-panic input attempts → rejected + specific audit (`.panic` entry + signed head).
  - Evidence: Remote Control subagent (existing strong harness + red-team probes + kill-switch tests); `ComputerUseSafetyInvariantHarness` ("no inputAction in panicHalted"); `PrivilegedInputKillSwitchTests`.

- **Phone replay / no-TTL / attestation bypass**:
  - Expired authority envelope (300s default + `authorityMaxLifetime`) → `expiredAuthority`.
  - Revoked escrow/peer → validator rejects.
  - Intent without required attestation hash (high tier) → rejected when binding is mandatory.
  - Counter replay / rollback → rejected (monotonic + persisted lastSeen).

- **Scope / deny / budget enforcement**:
  - Action matching built-in deny (loginwindow, SecurityAgent, keychain, password fields, Mail send) → denied + audited.
  - User attempt to allow overlapping built-in → editor refuses.
  - Budget hard cap / Remote Config kill → actions halted + audited.
  - Trust downgrade only (phone cannot escalate).

- **Clipboard / file / high-impact**:
  - Background clipboard sync without explicit user "Paste to Mac" / "Grab from Mac" → blocked.
  - Password in Remote Unlock path never appears in clipboard/audit/agent (certified HID sequence only).

## 3. Web/API / Cloud Callable Authorization Tests (OWASP Focus)

- **BOLA/IDOR / cross-tenant** (every high-risk + standard callable + gateway path):
  - Supply other user's `uid` / `deviceId` / `accountID` / `storagePath` / `clientId` / `pairingId` / `pairingCode` in any mutation or collectionGroup query → ownership assert + rules reject before read/write.
  - Signed upload request for path outside `assertUserStoragePath` → permission error.
  - Download URL for other-uid blob → not-found or ownership fail.

- **BFLA / function-level (view → control, pending → trusted, etc.)**:
  - Escrow register/approve/revoke, Remote MCP grant/issue, CLI complete, validate OTS, computer-use budget reserve, Hermes Gateway approve → all require correct tier (high-risk bound claim where applicable).
  - Direct Firestore write of privileged state → blocked.

- **Auth bypass / missing App Check / entitlement**:
  - High-risk callables without Auth / without App Check / without fresh bound attestation claim / without active entitlement → `unauthenticated` / `permission-denied` / `failed-precondition`.
  - Public surfaces (health, routerRundown post-fix, CLI start) behave as documented.

- **Rate limiting + resource exhaustion**:
  - Rapid pairing create/complete, gateway enqueue, high-risk callables → hard limits or 429 after window; no partial writes or grant issuance.
  - Oversized payloads (text > MAX, attachment >50MB, huge arrays, bad hex/base64) → 400 + no partial state.

- **Signed upload / attachment abuse**:
  - Upload then commit with mismatched hash/size/ctype → precondition error.
  - Expired signed URL behavior.
  - Replay of attachment init URL.

- **SSE / real-time / notifications**:
  - Gateway SSE under valid/invalid/revoked grants.
  - Push token registration + delivery authz.

- **Webhooks**:
  - Stripe/AppStore: invalid/expired signature → 400 (not 5xx); oversized → 413; invalid JWS chain → 400.

**Execution:** Firebase emulator for most; full client SDK calls (Android `FunctionsRepository`, iOS equivalent) for end-to-end. Load + concurrency on transactional paths (pairing complete).

## 4. Local Gateway + Daemon + Privileged Socket Tests

- **Local HTTP gateway (127.0.0.1:8317 default)**:
  - Non-loopback bind without token → validation error (existing tests in OpenBurnBarDaemonTests).
  - Wildcard bind → rejected.
  - Token exposure via process listing / plist → documented residual (same-UID only).

- **Daemon UNIX socket (0o600 + per-request authToken from launchd env)**:
  - Same-UID process without token → rejected.
  - Token via argv (instead of env) → not possible (enforced).

- **Privileged sockets (post-P0)**:
  - Unsigned / non-matching DR console-user process → connection + any dispatch rejected (existing red-team probe + integration tests).
  - Legitimate signed first-party caller (Remote Unlock sequence + CU scenarios) → succeeds.
  - Capability token missing / disallowed type / expired / wrong domain / budget exhausted → rejected at leaf + audited.

## 5. AI / LLM / Agent Flow Tests (Prompt Injection + Agency)

- **Prompt injection via untrusted channels**:
  - Malicious content in parsed logs, screenshots (browser CU or Hermes mirror), webpages (Playwright), attachments, documents → does not alter system/developer instructions, tool permissions, or produce unauthorized high-impact actions.
  - Retrieval poisoning / memory cross-user leakage (shared workspaces or cloud search) → isolated.

- **Tool permission bypass / excessive agency**:
  - Agent attempts high-impact action (shell, file modify outside scope, send message/email, spend, security change) without explicit confirmation gate → blocked + audited.
  - Stale/revoked grant → tool broker re-check fails.

- **Model-switch spoof / cost exhaustion**:
  - Spoofed model-switch event → rejected.
  - Agent loop causing budget burn → hard caps + hourly eval + kill switch.

**Execution:** Local harnesses + golden evals (existing retrieval + authoring suites) + targeted adversarial payloads. No production models for red-team.

## 6. Supply Chain / Build / CI Tests

- **Provenance / signing / SBOM**:
  - Release artifacts (DMG, AAR/APK, extensions, crates) have cosign attestations + SBOM (SPDX) + OpenVEX where the workflow is wired.
  - Tampered artifact → verification fails.

- **Dependency hygiene**:
  - Run OSV / CodeQL / Scorecard on repo + critical deps (Firebase, Iroh, Playwright, QUIC-related, GRDB-SQLCipher, etc.).
  - No unpinned Actions, broad CI perms, exposed secrets, unsafe install scripts.
  - CISA KEV scan for relevant vulns.

- **CI enforcement**:
  - `verify-resilience-wiring.sh` + `verify-ops-readiness.sh` + fast-feedback all green.
  - Any raw `fetch` in functions/src → CI failure.

## 7. Privacy / Data / Deletion / Backup Tests

- **Account deletion / export**:
  - Full user data export (usage, threads, session logs, grants, etc.) succeeds and contains only expected ciphertext where documented.
  - Deletion removes or renders unrecoverable all user-controlled data (local + cloud) within stated windows; no orphan grants/escrow/docs.

- **Opt-in backup / iCloud / cloud search**:
  - Chat bodies / session logs only present when the explicit setting is enabled.
  - Sealed content remains unreadable server-side (vault key never leaves device).

- **Log secret leakage**:
  - Structured logs + Sentry beforeSend + redaction never emit API keys, pairing secrets, tokens, full prompts, screenshots, or PII beyond truncated UID.

## 8. Incident Response / Detection / Blue Team Tabletop

- **Detection matrix triggers** (pairing failures/abuse, new device/escrow enrollment, remote control start, privilege escalation, workspace role change, high-risk agent action, unusual relay bandwidth/duration, suspicious signed upload, high token burn, model switch anomalies, unusual export/download, admin data access, failed authorization).
  - Simulate each in staging/emulator → alerts fire with correct context + severity.
- **Playbooks**: Run tabletop for stolen ticket, compromised paired phone, supply-chain release, relay cost blowup, AI prompt injection leading to spend.
- **Forensics gaps**: Audit export + signed head + OTS + verifier must allow offline "no actions after kill" proof.

## 9. Cross-Platform + Self-Hosted

- Android/iOS parity on all phone-control + grant + attestation + kill paths (JVM + instrumented where possible).
- Self-hosted / CLI-only / no-Firebase paths: reduced surface still enforces local grants, no silent privileged execution, local gateway hardening.
- Browser/WASM Iroh limitations (if any client paths) + metadata/cost notes.

## Execution Cadence & Gates

- Every PR touching daemon, computer-use, pairing, callables, or privileged paths: run relevant red-team probes + invariant harness + authz tests.
- Pre-release: full minimum list + new P0/P1 cases in staging + smoke on physical devices.
- Monthly: full swarm-style re-review delta + dependency/KEV scan + Scorecard run.
- On-call: detection matrix + playbook drills.

**Artifacts to collect per run:** Test logs, red-team probe output, harness results, timing for kills, audit export + verification output, emulator screenshots of consent flows.

This plan is reproducible today with existing harnesses + the additions called out in the subagent reports. Execute after every P0 batch and before any public launch.

Update this file + the master report as new evidence or gaps are found.
