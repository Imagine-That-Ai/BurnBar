# Packet P-13 (DRAFT): move ProviderQuota + XAISuperGrokPacingLog → OpenBurnBarQuota
STATE: QUEUED
LANE: C          DEPENDS-ON: S0, P-01 (SQLiteReader)
BASELINE-TOUCHING: none

`ProviderQuota/` (41 files) + root `XAISuperGrokPacingLog.swift` (which
`ProviderQuota/XAISuperGrokUsageLog.swift` calls, so it moves INTO Quota). 3 quota
adapters use `SQLiteConnection` → depends on SQLiteReader (P-01). NO LogParsers edge
(verified zero refs — the "Quota→Views/LogParser refs" were stale nested-type name
collisions). 18 files use `canImport(FoundationNetworking)` → the Linux-boundary build
is the key check.

## Scope (TO-ENUMERATE-AT-WAVE)
### git mv list
Whole `ProviderQuota/` into `OpenBurnBarQuota/ProviderQuota/` (or flatten — decide at
execution to minimize churn; whole-dir move preferred) + root
`XAISuperGrokPacingLog.swift` → `OpenBurnBarQuota/XAISuperGrokPacingLog.swift`.
Enumerate + verify each. Remove `OpenBurnBarQuota/ModuleMarker.swift`.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (`ProviderQuota/` not in
  `openBurnBarCoreExcludes`; it compiles off-Apple today via FoundationNetworking guards).
  If a Quota file is excluded, add to `openBurnBarQuotaExcludes`.
- **AE-IMPORT / AE-TESTABLE** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): EXPECTED
  here. The 3 SQLite-backed quota adapters reference `SQLiteConnection` (an
  `OpenBurnBarSQLiteReader` symbol post-P-01) and Quota references Kernel/crypto symbols,
  so those moved files need `import OpenBurnBarSQLiteReader` and/or `import
  OpenBurnBarKernel` — add exactly what V1 demands (both are declared deps of
  `OpenBurnBarQuota`); never `import OpenBurnBarCore`. Add `@testable import
  OpenBurnBarQuota` beneath the existing `@testable import OpenBurnBarCore` in any Core
  quota test reaching an INTERNAL moved symbol. Enumerate every added line/file in the
  PR body.

## Slice-specific validation
- Linux-boundary build (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build`) — the
  FoundationNetworking guards must keep the off-Apple graph valid.
- `ProviderQuotaMacParity` harness runner (grep for it at execution; keep green).
- V1–V11. Document in the PR body: "verified zero Quota→Views/LogParser refs".

## Pre-flight
Path-pin grep of `ProviderQuota`, `XAISuperGrokPacingLog.swift` → NONE (verified at S0).
Bundle.module → EMPTY. Not a CANON packet.

## PR / Acceptance
Title: "P-13: move ProviderQuota into OpenBurnBarQuota (the K3 Quota redo)". Invariants:
depends on SQLiteReader + Kernel + crypto, NO LogParsers edge, zero call-site changes.
A1–A6.
