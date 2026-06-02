# Cleanup opportunities

This page tracks known technical-debt and cleanup areas across the OpenBurnBar codebase. For the active remediation program, see [`hardening/sota-100`](../../plans/2026-05-30-sota-security-remediation.md).

## Naming and architectural debt

- **`*Manager` suffix sprawl** — ADR-001 deprecated `*Manager` for new code. Legacy singletons (`SettingsManager`, `OpenBurnBarDaemonManager`) remain until opportunistically migrated during god-file splits.
- **`CloudSyncService` god file** — Still shrinking per ADR-005. New domains must extract a `*SyncService` rather than add logic here. The active split is `CloudSyncCoordinator` (UI state) + `DownloadSyncService` / `ConversationSyncService` (domain work).
- **`OpenBurnBarCore` mixing models and UI** — The core SPM module embeds SwiftUI views under `Sources/OpenBurnBarCore/Views/`. Extracting `OpenBurnBarUI` is deferred until view-only dependencies are fully catalogued.

## Concurrency and threading

- **`Task.detached` legacy** — `CLIBridge` and several quota adapters still use naked `Task.detached`. ADR-002 forbids this in new code; remediation is tracked in [`docs/TECH_DEBT_METRICS.md`](../../docs/TECH_DEBT_METRICS.md).
- **`@MainActor` I/O facades** — `UsageAggregator` and `OpenBurnBarDaemonManager` carry class-scoped `@MainActor` while delegating heavy work outward. Monthly reviews count these via `scripts/ci/update-tech-debt-metrics.sh`.
- **`nonisolated` escape hatches on `DataStoreActor`** — New stores inject through initializers; legacy `nonisolated` properties remain for compatibility.

## Error handling

- **Empty `catch {}` blocks** — CI counts these in `scripts/ci/update-tech-debt-metrics.sh`; any new empty catch fails review. ADR-003 requires domain + stable code logging instead.
- **`try?` without justification** — Allowed for truly optional cosmetic paths; forbidden for Firestore writes, daemon RPC, and ledger persistence.

## Schema and type drift

- **Hand-maintained `functions/src/types.ts`** — Still migrating to the TypeSpec canon chain (`tools/schema-sync/`). Legacy interfaces remain until their TypeSpec module ships. Breaking changes require a coordinated version bump.

## Testing

- **Quarantine / Archive suites** — Previously quarantined Swift suites moved to `AgentLensTests/Archive/` on 2026-05-27. The [`QUARANTINE_MANIFEST.md`](../../AgentLensTests/Quarantine/QUARANTINE_MANIFEST.md) tracks revival status. `AgentLensTests/Active/` is the only compiled test surface.
- **Stale parser performance tests** — Archived per `docs/adr/2026-05-27-archive-legacy-parser-performance-tests.md`.

## Misc

- **`AgentLens` folder name** — The macOS app source folder is still named `AgentLens/` while the bundle ID is `com.openburnbar.app`. Renaming the folder is a low-priority cleanup because Xcode project restructuring carries regression risk.
