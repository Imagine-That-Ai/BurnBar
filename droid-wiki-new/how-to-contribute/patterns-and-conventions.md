# Patterns and conventions

## Naming boundaries

Follow ADR-001 (`docs/ARCHITECTURE/001-naming-conventions.md`):

| Suffix | Meaning | Example |
|--------|---------|---------|
| `*Service` | Long-lived singleton that owns a subsystem | `UsageAggregator`, `CloudSyncService` |
| `*Store` | Observable model container for a screen | `DashboardStore`, `SettingsStore` |
| `*Actor` | Swift actor for state isolation | `DatabaseActor`, `SyncActor` |
| `*Client` | Network or RPC caller | `DaemonRPCClient`, `FirestoreClient` |

## Error handling

- Use typed errors (ADR-003). Prefer `Result<T, Error>` or `throws` with concrete error types.
- Callable errors auto-capture via `wrapCallableHandler` → `withCallableLogging` → `captureException()` in `functions/src/logging.ts`.
- Never silently swallow errors; log with structured context.

## Actor isolation

- `@MainActor` for SwiftUI views and view-model state.
- Background actors (`DatabaseActor`, `SyncActor`) for I/O and concurrent work.
- ADR-002 covers actor boundary rules.

## Database patterns

- GRDB is the local SQLite wrapper. Use `DataStoreCoordinator.swift` for database lifecycle.
- Update `docs/SCHEMA_SQLITE.sql` alongside any migration.
- Use `OpenBurnBarQueryTracer` in tests to detect N+1 queries.

## Feature rollouts

- Use `node scripts/rollout.mjs --flag <flag> --stage ring-N` to advance feature flags.
- Remote Config flags are defined in `functions/src/config.ts`.

## Functions conventions

- Prefer `onCallProduction(name, options, handler)` from `functions/src/logging.ts` for new callable exports.
- Use circuit breakers from `functions/src/resilienceHelpers.ts`: `stripeWithResilience`, `firestoreWithResilience`, `resilientFetch`, etc.
- New provider HTTP must use `providerFetch` from `functions/src/providers/httpClient.ts`.
- CI enforces no raw `await fetch` in `functions/src/`: `bash scripts/ci/verify-resilience-wiring.sh`.

## Extension conventions

- Import alerting from `extensions/openburnbar/src/alerting.ts` — `alertDaemonUnreachable()`, `alertRunFailed()`, etc.
- Never use `vscode.window.showErrorMessage` directly.

## Related pages

- [Testing](testing.md) — how to write and run tests
- [Debugging](debugging.md) — logs and troubleshooting
- [Tooling](tooling.md) — build system and CI
