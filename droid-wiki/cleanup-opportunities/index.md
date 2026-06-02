# Cleanup opportunities

Known maintenance work that improves the codebase without changing behavior.

## TODO and FIXME comments

Two tracked TODOs exist in the active source tree:

| File | Comment | Age |
|------|---------|-----|
| `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager+Lifecycle.swift` | `// MARK: - TODO(per-user-models)` | Unknown |
| `AgentLens/Services/DataStore/DataStoreCoordinator.swift` | `// TODO(1.0): Remove the DataStore typealias and update all import sites.` | Pre-1.0 |

## Quarantined tests

`AgentLensTests/Quarantine/` holds stale test suites that are intentionally excluded from CI. They serve as migration reference but need revival before reintegration. See [`AgentLensTests/README.md`](../../AgentLensTests/README.md).

## Schema migration in progress

`functions/src/types.ts` remains the canonical Firestore schema while `tools/schema-sync/` (TypeSpec emitters) is being adopted. Legacy hand-maintained types still exist during the migration. Run `./tools/schema-sync/check-drift.sh` to verify alignment.

## Related pages

- [How to contribute](../how-to-contribute/index.md)
- [macOS app](../apps/macos-app/index.md)
