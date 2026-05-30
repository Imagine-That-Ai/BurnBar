# ADR: Wave 2 stale-contract tests as legacy reference

**Status:** Accepted (2026-05-30)  
**Context:** `AgentLensTests/Quarantine/` holds no Swift sources; Wave 2 rows in `QUARANTINE_MANIFEST.md` document tests that were quarantined for stale contracts or environmental coupling.

## Decision

- Treat **revived** Wave 2 tests (listed as Done in the manifest) as the only executable coverage for those flows.
- Treat **open** Wave 2 rows as **legacy reference**: they remain documented in `QUARANTINE_MANIFEST.md` with revival criteria, but are not compiled until a subsystem owner rebuilds fixtures against current APIs.
- **Skipped-with-issue** stubs in `AgentLensTests/Active/` stay in Active with `XCTSkip` and an issue string so CI stays green while intent is visible.

## Open Wave 2 reference (not compiled)

| Area | Representative tests | Blocker |
|------|---------------------|---------|
| Operating Layer | `testOperatingLayerBuildsMissionDirectionBurnFromIndexedProjectData` | Mission direction-burn thresholds drifted |
| CloudSync / merge | `test_circuitBreaker_halfOpenToClosed_recovery` | Active XCTSkip — fake gateway does not trip breaker |
| Database | `test_runMigrationsSafely_integrityCheckFails_throws` | Integrity check dispatch path changed |
| Usage aggregation | `test_refreshAll_*`, `test_refresh_providerWithNoParser_*` | Needs hermetic FS sandbox |
| Session log sync | `test_sessionLogUpload_writesManifestAndChunks` | Chunk manifest format drifted |
| Search / Hermes | `test_send_hermesProviderRankingQuery_*` | Ranking heuristics changed |
| Provider quota | `test_factoryRefresh_estimatesRemainingFromPlanTierAndMonthlyUsage` | Factory plan-tier fixtures stale |
| Metrics | `test_compute_searchLatencies_*`, rerank/semantic fallback | Needs `retrieval_health_history` or multi-row mock |
| Switcher / daemon | cross-surface log redaction, daemon RPC smoke | Log routing / RPC shape drifted |
| Settings | `test_detectAvailableProviders_returnsFalseForAllOnCleanSystem` | Environmental — host FS walk |
| Usage conflict | `test_remoteExact_*`, `test_remoteEqualConfidence_*` | Provenance rules realigned |
| Database encryption | `testMakeConfigurationWithKey_reportsCipherVersion` | Active XCTSkip — SQLCipher release build |

## Consequences

- Manifest totals count **legacy reference rows**, not quarantined Swift files.
- New quarantines must either land in Active with `XCTSkip` + issue, or add a LegacyReference Swift file with an explicit ADR link.
