# OpenBurnBar — Reliability & Operations Review

**Reviewer:** Senior SRE / Production Engineer  
**Branch:** `release/openburnbar-0.1.2-beta.12`  
**Date:** 2026-04-27  
**Scope:** Logging, monitoring, deployment safety, config hygiene, error handling, operational docs, crash resilience (launchd, daemon supervision, recovery), rollback readiness.

---

## Executive Summary

OpenBurnBar demonstrates **above-average reliability maturity** for a solo-maintained macOS app in beta, with strong CI/CD hygiene, excellent operational documentation, and deliberate resilience architecture in the daemon layer. However, there are **three critical production-readiness gaps** that must be addressed before stable release: a `fatalError` on database init that hard-crashes users for disk/permission issues, a broken artifact flow in the release pipeline that makes the post-build smoke test non-functional, and a few swallows of keychain errors in UI code that could mask credential-loss failures.

**Overall Reliability / Ops Score: 7 / 10**  
(“Solid beta ops with first-class docs and signing, but one critical crash-on-launch risk and one broken release flow block stable production status.”)

---

## Best Operations Practices Found

### 1. Structured Logging with Sentry Integration
Both the app and the daemon use structured `Logger` instances with consistent `event=... metadata=[...]` formatting. `AppLogger` includes category-based loggers (`dataStore`, `chat`, `search`, etc.) and privacy-safe metadata hashing (`private(mask: .hash)`). Errors include breadcrumbs for Sentry when available.

*Evidence:*
- `AgentLens/Services/AppLogger.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonLogger.swift`

### 2. Comprehensive CI/CD & Release Safety
The `release.yml` workflow enforces **strict fail-hard signing**: it validates every required Apple secret (Developer ID certificate, notary API key, Firebase plist, App Check token) before even starting the Xcode build. It then produces code-signed artifacts (app + DMG), notarizes + staples, computes SHA256/SHA512 checksums, optionally GPG-signs the checksums, generates an SPDX SBOM, writes release provenance metadata, and runs a smoke test. This is better than many enterprise release pipelines.

*Evidence:*
- `.github/workflows/release.yml` (notarization, codesigning, checksums, SBOM, GPG signing)
- `scripts/test-openburnbar-release-smoke.sh` (post-build launch verification)
- `Makefile` (deterministic build with checksum targets)

### 3. Operational Documentation (Runbook & Rollback Decision Trees)
`docs/RUNBOOK.md` and `docs/RELEASE_ROLLBACK.md` are genuinely high-quality, with copy-paste diagnosis + remediation commands for daemon crashes, database corruption, cloud sync failures, migration failures, extension disconnects, and release rollbacks at every stage of the pipeline. The database corruption incident even covers SQLCipher-aware recovery and three recovery options (backup → dump → nuclear). This is rare for a codebase this small.

*Evidence:*
- `docs/RUNBOOK.md`
- `docs/RELEASE_ROLLBACK.md`
- `docs/DATABASE_OPERATIONS.md`

### 4. Daemon Supervision with Exponential Backoff & Crash-Loop Detection
`OpenBurnBarDaemonSupervisor` implements stateless exponential backoff with jitter, plus a dedicated `crashLoop` state (5 consecutive failures) that pauses restart attempts for 5 minutes. `OpenBurnBarDaemonManager+Lifecycle.swift` correctly rotates the Unix socket auth token on every reinstall, invalidating leaked tokens without coordination.

*Evidence:*
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonSupervisor.swift`
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+Lifecycle.swift`

### 5. Circuit Breaker + Retry Classification for Cloud Sync
`CloudSyncCircuitBreaker` (actor-backed) provides closed/open/halfOpen states, and `CloudSyncErrorClassifier` correctly distinguishes transient (`.unavailable`, `NSURLErrorTimedOut`) vs. permission-denied vs. terminal errors. The retry executor (`withCloudSyncRetry`) applies exponential backoff with jitter and rejects quickly when the breaker is open.

*Evidence:*
- `AgentLens/Services/CloudSync/CloudSyncCircuitBreaker.swift`

### 6. Telemetry is Privacy-Preserving and Bucketed
`TelemetryService` collects only feature-level outcomes (success/failure/degraded/cancelled) with durations bucketed to 100ms. No PII, no conversation content, no API keys. It buffers up to 100 events in memory with `NSLock` protection and flushes to `os_log`.

*Evidence:*
- `AgentLens/Services/Telemetry/OpenBurnBarTelemetryService.swift`

### 7. Database Encryption Key Recovery with Integrity Checks
`DatabaseEncryptionService` stores SQLCipher keys in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`) and also writes a recovery file at `~/.encryption-key-recovery` with SHA-256 integrity validation and strict permissions (`0o600`). If Keychain access is lost, recovery is possible.

*Evidence:*
- `AgentLens/Services/DataStore/DatabaseEncryptionService.swift`

---

## Worst Reliability Risks

### 🔴 Risk 1: `fatalError` on DataStore Init Crashes the App for Any Database/Permission Failure
`AgentLensApp.swift` contains a hard `fatalError` in the app-level `init()` when `DataStore()` throws. A database lock, disk-full error, corrupted SQLite, or migration failure results in an **immediate hard crash on launch** with no graceful degradation. This is the single biggest production risk — it turns every disk/permission/corruption incident into an unusable app.

*Evidence:*
- `AgentLens/App/AgentLensApp.swift:342`
  ```swift
  do {
      initializedStore = try DataStore()
  } catch {
      fatalError(
          "CRITICAL: Failed to initialize DataStore. The app cannot function …"
      )
  }
  ```

**Mitigation suggestion:** Replace with a non-fatal degraded mode — show an alert offering to restore from backup, reset the database, or quit. Only `fatalError` in an unrecoverable state; database init failure is recoverable per the runbook.

### 🟡 Risk 2: Release Workflow Smoke Test Cannot Run Because Artifacts Are Never Uploaded
The release workflow declares `needs: build-and-release` for the `smoke-test` job, and `needs: [build-and-release, smoke-test]` for the `publish` job. The `build-and-release` job uses `actions/download-artifact@v4`, but **nowhere in the workflow is there an `actions/upload-artifact` step** for the DMG/ZIP/checksums. Therefore the smoke-test job will always fail when it tries to download the artifact. The release pipeline is currently incomplete at the smoke-test stage.

*Evidence:*
- `.github/workflows/release.yml` — steps: `build-and-release` → no `upload-artifact` anywhere before `smoke-test`.

**Mitigation suggestion:** Add an `actions/upload-artifact` step (or matrix artifact output) in `build-and-release` before the download steps in downstream jobs. Ensure `smoke-test` and `publish` consume the same artifact.

### 🟡 Risk 3: Silent Empty `catch` Blocks in Key UI Code
`ProviderQuotaPopoverViews.swift` contains three empty `catch {}` blocks for keychain operations (`setAPIKey`, `removeAPIKey`). If the keychain returns an error (e.g., `errSecItemNotFound` or `errSecAuthFailed`), the UI silently ignores it, leaving the user with a mismatch between what they think is saved and what is actually stored.

*Evidence:*
- `AgentLens/Views/Components/ProviderQuota/ProviderQuotaPopoverViews.swift:401, 407, 413`
  ```swift
  } catch { }  // three occurrences for minimax / zai / cursor_cookie keys
  ```

**Mitigation suggestion:** Replace with `AppLogger.dataStore.silentFailure(...)` or surface an inline error toast so the user knows the save failed.

### 🟡 Risk 4: `DaemonUsageSyncService.swift` Silently Drops Import Failures
`OpenBurnBarDaemonUsageSyncService.refreshState` and `runtimeSnapshot` both call `try? insertUsages(importedUsages)` — if the database insert throws (e.g., unique-constraint or disk issue), the import is silently discarded and the UI never reflects the daemon’s usage data. The `try?` pattern also appears in `CursorConnectorManager` (restore settings, remove proxy files), `SettingsManager`, and `DailyDigestManager`.

*Evidence:*
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonUsageSyncService.swift`
- `AgentLens/Services/CursorConnector/CursorConnectorManager.swift` (multiple `try?`)
- `AgentLens/Services/SettingsManager.swift` (JSON decode)

### 🟡 Risk 5: `RecoveryEngine` Retry Policy Is Hard-Coded and Not Externally Adjustable
`BurnBarRecoveryEngine.decide(...)` caps retries at a literal `attempt < 2`, with no external configuration or metrics emission. A transient tool failure gets exactly one retry, then is treated as terminal. There is no observability into how often retries fire or succeed.

*Evidence:*
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarRecoveryEngine.swift`
  ```swift
  let reason = policyEngine.isRetryable(error) && attempt < 2
      ? "retryable_tool_failure"
      : "terminal_tool_failure"
  ```

### 🟢 Risk 6: `AppSandbox` Disabled Entirely (Accepted Risk)
The entitlements comment correctly justifies disabling sandbox for filesystem access to AI agent logs across the home directory, and the app is distributed via Developer ID signing (not App Store). This is an accepted design choice, but it means the app has full user-level filesystem access. No `com.apple.security.files.user-selected.read-write` or scoped-bookmark pattern is used.

*Evidence:*
- `AgentLens/Resources/OpenBurnBar.entitlements` (`com.apple.security.app-sandbox` = `<false/>`)
- `AgentLens/Resources/OpenBurnBarRelease.entitlements` (same for release)

### 🟢 Risk 7: `SecKeychainInteractionGate.swift` Contains a Global `var` Flag (`isLocked`)
The interaction gate uses a global mutable boolean to prevent reentrant keychain prompts. This is a concurrency anti-pattern — two simultaneous prompts from different threads can race on `isLocked = true`. It should be an `actor` or an `NSLock`-guarded property.

*Evidence:*
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/SecKeychainInteractionGate.swift` (inspected via file list + grep)

---

## Maturity Assessment by Category

| Category | Score (1–10) | Notes |
|----------|--------------|-------|
| Logging & Observability | 8 | Structured logs + Sentry breadcrumbs + telemetry. No distributed tracing. |
| Monitoring / Alerting | 4 | No real-time metrics dashboard or alerting. Telemetry is in-memory only. |
| CI/CD & Artifact Integrity | 7 | Strict signing, notarization, SBOM, checksums, GPG. Artifacts not uploaded → smoke test fails. |
| Config Hygiene & Secrets | 7 | Keychain for DB keys, rotated socket auth tokens, Firebase plist injection with validation. Some `try?` loss in keychain UI. |
| Error Handling | 6 | Good in daemon/server, but bad in app init (`fatalError`) and a few empty catches in UI. |
| Operational Docs & Runbooks | 9 | RUNBOOK.md, RELEASE_ROLLBACK.md, DATABASE_OPERATIONS.md are excellent. Could use a post-mortem template. |
| Crash Resilience / Recovery | 8 | Daemon supervision with backoff + crash-loop detection, recovery engine, SQLCipher key recovery. |
| Idempotency & State Safety | 7 | Deterministic document IDs for Firestore, deterministic UUIDs for daemon usage imports, `insertUsages` dedups. `try? insertUsages` undermines this. |

---

## Key Recommendations (Priority Order)

1. **Remove `fatalError` on DataStore init** — replace with a degraded-launch alert that lets the user restore or reset the database.
2. **Fix the release workflow artifact upload/download chain** — add `upload-artifact` after DMG creation so `smoke-test` and `publish` jobs can actually run.
3. **Surface keychain errors in `ProviderQuotaPopoverViews`** — replace empty `catch {}` with user-visible error feedback.
4. **Avoid `try? insertUsages` in `DaemonUsageSyncService`** — at minimum log the failure; ideally surface it in the UI or retry.
5. **Externalize `RecoveryEngine` retry config** — make `maxRetries`, `backoffBaseDelay`, and `jitterFactor` configurable via `BurnBarDaemonConfiguration`.
6. **Make `SecKeychainInteractionGate` thread-safe** — replace global `var isLocked` with an actor or lock.
7. **Add `actions/upload-artifact` outputs** for DMG, ZIP, checksums, SBOM, and metadata so the release pipeline is fully end-to-end.

---

## Conclusion

OpenBurnBar is clearly built by someone who cares about production safety: strict signing, notarization, runbooks, rollback decision trees, privacy-preserving telemetry, and a well-supervised daemon. Fixing the `fatalError` on launch, the missing artifact upload step, and the silent keychain failures would bring the codebase to an **8–9/10** level and make it genuinely production-ready.
