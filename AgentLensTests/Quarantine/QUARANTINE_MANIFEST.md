# Quarantine / Archive Manifest

This document tracks every archived test in `AgentLensTests/Archive/` (moved from `Quarantine/` on 2026-05-27).
Archived tests are excluded from compilation and do not run in CI.
Revival requires updating the test to current public/`@testable` APIs and proving
it with `./scripts/test-openburnbar-app.sh`.

## Legend

| Column | Description |
|--------|-------------|
| **Test Name** | Exact test method name (`func test…`) |
| **Status** | `Done` (revived in Active), `LegacyReference` (documented only), or `Skipped-with-issue` (Active `XCTSkip`) |
| **Reason** | Why the test was quarantined |
| **Owner** | Subsystem or team that should revive it |
| **Source Subsystem** | Product area the test covers |
| **Revival Criteria** | What must be true before the test can return to Active |
| **Target Date** | Suggested revival milestone |

---

## Wave 2 — Stale Contract / Environmental Quarantines

**2026-05-27 remediation:** `CollaborationSyncService` is a standalone `CloudSyncDomain` service. `CloudSyncCoordinator` routes collaboration directly (no legacy `CloudSyncService` delegate) and is no longer `@MainActor` at the type level. `CloudSyncService` upload/download paths delegate to extracted domain services via a thin shim.

**2026-05-30 PR4:** Open Wave 2 rows are **legacy reference** only — see [ADR](../../docs/adr/2026-05-30-wave2-stale-contract-legacy-reference.md). No Swift sources remain under `AgentLensTests/Quarantine/`.

| Test Name | Status | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|--------|-------|------------------|------------------|-------------|
| `testOperatingLayerBuildsMissionDirectionBurnFromIndexedProjectData` | LegacyReference | Stale contract — mission direction-burn signal classification drifted | AgentLens | Operating Layer | Refresh thresholds and realign mission/direction-burn fixtures | 2026-05-17 |
| `test_backoff_suppression_onPermissionDenied` | Done | ~~Stale contract~~ **Revived 2026-05-25** → `AgentLensTests/Active/OfflineOnlineMergeTests.swift` | CloudSync | Offline/Online Merge | — | Done |
| `test_watermark_doesNotAdvanceOnFailure` | Done | ~~Stale contract~~ **Revived 2026-05-25** → `AgentLensTests/Active/OfflineOnlineMergeTests.swift` | CloudSync | Offline/Online Merge | — | Done |
| `test_circuitBreaker_halfOpenToClosed_recovery` | Skipped-with-issue | Stale contract — circuit breaker state machine refactor needed | CloudSync | Offline/Online Merge | Fake gateway must surface retry failures to breaker; Active: `OfflineOnlineMergeTests` XCTSkip | 2026-05-24 |
| `test_runMigrationsSafely_integrityCheckFails_throws` | LegacyReference | Stale contract — integrity check error path now handled before migrations dispatch | Database | Database Migration | Rebuild test against pre-migration integrity-check dispatch | 2026-05-17 |
| `test_conversationUpload_writesToFirestoreAndMarksSynced` | Done | ~~Stale contract~~ **Revived 2026-05-27** → `AgentLensTests/Active/ConversationSyncRoundTripTests.swift` | CloudSync | Conversation Sync | — | Done |
| `test_refreshAll_storesUsagesInDataStore` | LegacyReference | Stale contract — UsageAggregator refresh now scans live provider directories | UsageAggregation | Usage Aggregator | Add hermetic FS sandbox so aggregator does not scan host machine | 2026-05-17 |
| `test_refresh_providerWithNoParser_doesNothing` | LegacyReference | Stale contract — UsageAggregator refresh now scans live provider directories | UsageAggregation | Usage Aggregator | Add hermetic FS sandbox so aggregator does not scan host machine | 2026-05-17 |
| `test_syncStateStore_recordsConflictedState` | Done | ~~Stale contract~~ **Archived — revived in Active** | CloudSync | Shared Artifact Conflict Resolution | — | Done |
| `test_syncStateStore_conflictToResolved` | Done | ~~Stale contract~~ **Archived — revived in Active** | CloudSync | Shared Artifact Conflict Resolution | — | Done |
| `test_sessionLogUpload_writesManifestAndChunks` | LegacyReference | Stale contract — session-log chunk manifest format drifted | CloudSync | Session Log Sync | Rebuild fakeStore writers against current chunk manifest format | 2026-05-17 |
| `test_send_hermesProviderRankingQuery_returnsTopProviderAndAlignedTargets` | LegacyReference | Stale contract — provider ranking heuristics changed | Search | Chat Session Search | Rebuild harness fixtures against current provider ranking heuristics | 2026-05-17 |
| `test_factoryRefresh_estimatesRemainingFromPlanTierAndMonthlyUsage` | LegacyReference | Stale contract — Factory plan-tier limits updated | ProviderQuota | Provider Quota Service | Refresh fixture totals against current Factory plan-tier limits | 2026-05-17 |
| `test_compute_searchLatencies_computesPercentiles` | LegacyReference | Stale contract — schema dedupes on subsystem; needs history table | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_compute_rerankSuccessRate` | LegacyReference | Stale contract — schema dedupes on subsystem; only last insert observable | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_compute_semanticFallbackRate` | LegacyReference | Stale contract — schema dedupes on subsystem; only last insert observable | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_ui_crossSurface_startupLogRedactsSecrets` | LegacyReference | Stale contract — production log routing rewired; capture path no longer observable | AgentLens | Switcher Cross-Flow | Rebuild log capture fixture against current production log routing | 2026-05-17 |
| `test_managerPrefersDaemonRPCForConfigAndRecentUsage` | LegacyReference | Stale contract — daemon RPC URL/recent-usage shape drifted | Daemon | Daemon Manager | Refresh harness fixtures against current daemon RPC shape | 2026-05-17 |
| `test_managerUpdatesProviderConfigurationThroughDaemonRPC` | LegacyReference | Stale contract — provider configuration RPC payload drifted | Daemon | Daemon Manager | Refresh harness fixtures against current provider configuration RPC payload | 2026-05-17 |
| `test_appToDaemonHealthSmoke` | LegacyReference | Stale contract — daemon health smoke uses a transport surface that drifted | Daemon | Daemon Manager | Rebuild health smoke against current hardened transport surface | 2026-05-24 |
| `test_detectAvailableProviders_returnsFalseForAllOnCleanSystem` | LegacyReference | Environmental — requires a hermetic FS sandbox | Settings | Settings Manager | Add hermetic FS sandbox so provider detection does not walk host machine | 2026-05-17 |
| `test_remoteExact_overwritesLocalHighConfidenceEstimate` | LegacyReference | Stale contract — provenance conflict resolution rewrote local rules | CloudSync | Usage Conflict Resolution | Realign test assertions against current provenance conflict resolution rules | 2026-05-17 |
| `test_remoteEqualConfidence_updatesValuesButPreservesUsageSource` | LegacyReference | Stale contract — provenance conflict resolution rewrote local rules | CloudSync | Usage Conflict Resolution | Realign test assertions against current provenance conflict resolution rules | 2026-05-17 |
| `testMakeConfigurationWithKey_reportsCipherVersion` | Skipped-with-issue | Environmental — SQLCipher PRAGMA cipher_version requires release build | Database | Database Encryption Service | Active: `DatabaseEncryptionServiceTests` XCTSkip; verify in release CI or build-config gate | 2026-05-17 |

## Legacy Quarantines

| Test Name | Status | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|--------|-------|------------------|------------------|-------------|
| `ParserTests` (monolithic) | LegacyReference | Legacy parser internals and removed helper types | AgentLens | Log Parsers | Archived — see `docs/adr/2026-05-27-archive-legacy-parser-performance-tests.md` | Archive |
| `PerformanceTests` (suite) | LegacyReference | Legacy `XCTPerformanceMetric` APIs and removed data-store contracts | AgentLens | Performance | Archived — see `docs/adr/2026-05-27-archive-legacy-parser-performance-tests.md` | Archive |

---

## Totals

| Bucket | Count |
|--------|------:|
| Wave 2 rows (this manifest) | 24 |
| Revived (`Done`) | 5 |
| Active `XCTSkip` (`Skipped-with-issue`) | 2 |
| Legacy reference (open Wave 2 + legacy suites) | 17 |
| Compiled quarantine Swift files | 0 |
| `AgentLensTests/LegacyReference/` suites | 2 |
| Archive duplicates removed (2026-05-28) | 14 files |

- **Quarantine directory:** README + this manifest only (no `.swift` sources).
- **Legacy reference:** 17 Wave 2 tests + 2 parser/performance suites documented above; not in `OpenBurnBarTests` until revived per ADR.
- **Fixed to passing (env-gate, not quarantined):** `testParseEmptyDirectory`, `testWrongDeviceDecryptionFails`.

## Maintenance Notes

- Do not add `project.yml` glob exclusions for quarantined files; they live outside the `OpenBurnBarTests` target source paths by directory convention.
- When reviving a test, move the method(s) from the Quarantine file back into the matching Active file, then delete the Quarantine file if it becomes empty.
- Update this manifest immediately when tests are revived or newly quarantined.
- Prefer `XCTSkip("…issue…")` in Active over silent deletion when the contract is known but blocked.
