# Quarantine Manifest

This document tracks every quarantined test in `AgentLensTests/Quarantine/`.
Quarantined tests are excluded from compilation and do not run in CI.
Revival requires updating the test to current public/`@testable` APIs and proving
it with `./scripts/test-openburnbar-app.sh`.

## Legend

| Column | Description |
|--------|-------------|
| **Test Name** | Exact test method name (`func test…`) |
| **Reason** | Why the test was quarantined |
| **Owner** | Subsystem or team that should revive it |
| **Source Subsystem** | Product area the test covers |
| **Revival Criteria** | What must be true before the test can return to Active |
| **Target Date** | Suggested revival milestone |

---

## Wave 2 — Stale Contract / Environmental Quarantines

| Test Name | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|-------|------------------|------------------|-------------|
| `testOperatingLayerBuildsMissionDirectionBurnFromIndexedProjectData` | Stale contract — mission direction-burn signal classification drifted | AgentLens | Operating Layer | Refresh thresholds and realign mission/direction-burn fixtures | 2026-05-17 |
| `test_backoff_suppression_onPermissionDenied` | Stale contract — sync gateway error-classification surface drifted | CloudSync | Offline/Online Merge | Retune mocks against current gateway error-classification | 2026-05-17 |
| `test_watermark_doesNotAdvanceOnFailure` | Stale contract — watermark advancement now happens through a different code path | CloudSync | Offline/Online Merge | Rebuild mock surface to match new watermark advancement path | 2026-05-17 |
| `test_circuitBreaker_halfOpenToClosed_recovery` | Stale contract — circuit breaker state machine refactor needed | CloudSync | Offline/Online Merge | Complete circuit breaker state machine refactor and rebuild test harness | 2026-05-24 |
| `test_runMigrationsSafely_integrityCheckFails_throws` | Stale contract — integrity check error path now handled before migrations dispatch | Database | Database Migration | Rebuild test against pre-migration integrity-check dispatch | 2026-05-17 |
| `test_conversationUpload_writesToFirestoreAndMarksSynced` | Stale contract — Firestore mock surface drifted | CloudSync | Conversation Sync | Rebuild fakeStore writers against current conversation sync contract | 2026-05-17 |
| `test_refreshAll_storesUsagesInDataStore` | Stale contract — UsageAggregator refresh now scans live provider directories | UsageAggregation | Usage Aggregator | Add hermetic FS sandbox so aggregator does not scan host machine | 2026-05-17 |
| `test_refresh_providerWithNoParser_doesNothing` | Stale contract — UsageAggregator refresh now scans live provider directories | UsageAggregation | Usage Aggregator | Add hermetic FS sandbox so aggregator does not scan host machine | 2026-05-17 |
| `test_syncStateStore_recordsConflictedState` | Stale contract — sync state schema rewrote conflict-status columns | CloudSync | Shared Artifact Conflict Resolution | Update schema and assertions to match new conflict-status columns | 2026-05-17 |
| `test_syncStateStore_conflictToResolved` | Stale contract — sync state schema rewrote conflict-status columns | CloudSync | Shared Artifact Conflict Resolution | Update schema and assertions to match new conflict-status columns | 2026-05-17 |
| `test_sessionLogUpload_writesManifestAndChunks` | Stale contract — session-log chunk manifest format drifted | CloudSync | Session Log Sync | Rebuild fakeStore writers against current chunk manifest format | 2026-05-17 |
| `test_send_hermesProviderRankingQuery_returnsTopProviderAndAlignedTargets` | Stale contract — provider ranking heuristics changed | Search | Chat Session Search | Rebuild harness fixtures against current provider ranking heuristics | 2026-05-17 |
| `test_factoryRefresh_estimatesRemainingFromPlanTierAndMonthlyUsage` | Stale contract — Factory plan-tier limits updated | ProviderQuota | Provider Quota Service | Refresh fixture totals against current Factory plan-tier limits | 2026-05-17 |
| `test_compute_searchLatencies_computesPercentiles` | Stale contract — schema dedupes on subsystem; needs history table | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_compute_rerankSuccessRate` | Stale contract — schema dedupes on subsystem; only last insert observable | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_compute_semanticFallbackRate` | Stale contract — schema dedupes on subsystem; only last insert observable | Metrics | Local Metrics Aggregator | Add `retrieval_health_history` table or mock store supporting multiple observations per subsystem | 2026-05-24 |
| `test_ui_crossSurface_startupLogRedactsSecrets` | Stale contract — production log routing rewired; capture path no longer observable | AgentLens | Switcher Cross-Flow | Rebuild log capture fixture against current production log routing | 2026-05-17 |
| `test_managerPrefersDaemonRPCForConfigAndRecentUsage` | Stale contract — daemon RPC URL/recent-usage shape drifted | Daemon | Daemon Manager | Refresh harness fixtures against current daemon RPC shape | 2026-05-17 |
| `test_managerUpdatesProviderConfigurationThroughDaemonRPC` | Stale contract — provider configuration RPC payload drifted | Daemon | Daemon Manager | Refresh harness fixtures against current provider configuration RPC payload | 2026-05-17 |
| `test_appToDaemonHealthSmoke` | Stale contract — daemon health smoke uses a transport surface that drifted | Daemon | Daemon Manager | Rebuild health smoke against current hardened transport surface | 2026-05-24 |
| `test_detectAvailableProviders_returnsFalseForAllOnCleanSystem` | Environmental — requires a hermetic FS sandbox | Settings | Settings Manager | Add hermetic FS sandbox so provider detection does not walk host machine | 2026-05-17 |
| `test_remoteExact_overwritesLocalHighConfidenceEstimate` | Stale contract — provenance conflict resolution rewrote local rules | CloudSync | Usage Conflict Resolution | Realign test assertions against current provenance conflict resolution rules | 2026-05-17 |
| `test_remoteEqualConfidence_updatesValuesButPreservesUsageSource` | Stale contract — provenance conflict resolution rewrote local rules | CloudSync | Usage Conflict Resolution | Realign test assertions against current provenance conflict resolution rules | 2026-05-17 |
| `testMakeConfigurationWithKey_reportsCipherVersion` | Environmental — SQLCipher PRAGMA cipher_version requires release build | Database | Database Encryption Service | Verify in release CI configuration or add build-config conditional | 2026-05-17 |

## Legacy Quarantines

| Test Name | Reason | Owner | Source Subsystem | Revival Criteria | Target Date |
|-----------|--------|-------|------------------|------------------|-------------|
| `ParserTests` (monolithic) | Legacy parser internals and removed helper types | AgentLens | Log Parsers | Rewrite against current per-provider parser public APIs | Archive |
| `PerformanceTests` (suite) | Legacy `XCTPerformanceMetric` APIs and removed data-store contracts | AgentLens | Performance | Rewrite against current GRDB/performance contracts | Archive |

---

## Totals

- **Wave 2 quarantined:** 24 tests
- **Legacy quarantined:** 2 suites
- **Fixed to passing:** 2 tests (`testParseEmptyDirectory`, `testWrongDeviceDecryptionFails` env-gate)
- **Deleted:** 0 tests

## Maintenance Notes

- Do not add `project.yml` glob exclusions for quarantined files; they live outside the `OpenBurnBarTests` target source paths by directory convention.
- When reviving a test, move the method(s) from the Quarantine file back into the matching Active file, then delete the Quarantine file if it becomes empty.
- Update this manifest immediately when tests are revived or newly quarantined.
