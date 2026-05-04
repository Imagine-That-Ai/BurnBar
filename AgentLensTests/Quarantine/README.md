# Quarantined Tests

These tests are intentionally outside the compiled `OpenBurnBarTests` target.

Quarantine is for suites that cannot honestly compile against the current runtime
contracts. Do not add `project.yml` glob exclusions for these files. Move a suite
back under `AgentLensTests/Active/` only after updating it to current public or
`@testable` APIs and proving it with `./scripts/test-openburnbar-app.sh`.

## Canonical reference

See **[QUARANTINE_MANIFEST.md](QUARANTINE_MANIFEST.md)** for the full table of
quarantined tests with owner, reason, revival criteria, and target dates.

## Current quarantined suites

### Legacy

- `Parsers/ParserTests.swift` — legacy monolithic parser white-box tests that
  reference removed parser internals, removed helper types, old provider cases,
  and private methods now covered by per-provider parser suites.
- `PerformanceTests.swift` — legacy performance benchmarks that use obsolete
  `XCTPerformanceMetric` APIs and removed data-store/token-usage contracts.

### Wave 2 — Stale contract / environmental

- `OpenBurnBarOperatingLayerTests.swift`
- `OfflineOnlineMergeTests.swift`
- `OpenBurnBarDatabaseMigrationTests.swift`
- `ConversationSyncRoundTripTests.swift`
- `UsageAggregatorTests.swift`
- `SharedArtifactConflictResolutionTests.swift`
- `SessionLogSyncRoundTripTests.swift`
- `ChatSessionControllerSearchStateTests.swift`
- `ProviderQuotaServiceTests.swift`
- `LocalMetricsAggregatorTests.swift`
- `SwitcherCrossFlowTests.swift`
- `OpenBurnBarDaemonManagerTests.swift`
- `SettingsManagerTests.swift`
- `UsageConflictResolutionTests.swift`
- `DatabaseEncryptionServiceTests.swift`
