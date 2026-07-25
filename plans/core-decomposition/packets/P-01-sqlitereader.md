# Packet P-01: move Services/SQLite → OpenBurnBarSQLiteReader
STATE: QUEUED
LANE: B          DEPENDS-ON: S0
BASELINE-TOUCHING: none

This is the K3 fix (docs/CORE_DECOMPOSITION_PROGRAM.md §K3). Extract the 325-LOC
read-only SQLite reader into its own micro-target so LogParsers (P-12) and Quota
(P-13) extract independently on top of it, without depending on each other.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/SQLite/SQLiteConnection.swift OpenBurnBarCore/Sources/OpenBurnBarSQLiteReader/SQLiteConnection.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/SQLite/SQLiteReading.swift OpenBurnBarCore/Sources/OpenBurnBarSQLiteReader/SQLiteReading.swift
```
After the moves, `Services/SQLite/` is empty — remove the now-empty directory
(`rmdir OpenBurnBarCore/Sources/OpenBurnBarCore/Services/SQLite` if git leaves it).
Also remove `OpenBurnBarSQLiteReader/ModuleMarker.swift` (the target now has real
sources): `git rm OpenBurnBarCore/Sources/OpenBurnBarSQLiteReader/ModuleMarker.swift`.

### Allowed edit files (exhaustive; edits described per file)
- `OpenBurnBarCore/Package.swift` — ONLY these line-level edits:
  - In the `OpenBurnBarCore` target's `dependencies`, remove `coreSQLiteDependencies`
    from the concatenation (Core no longer links the SQLite backend directly once the
    reader owns it — the reader re-exports nothing SQLite-facing that Core compiles
    against at S1; if the Core build then fails for a missing SQLite symbol, STOP and
    report — do NOT re-add other deps). The reader already carries
    `sqliteReaderSQLiteDependencies` (an alias of `coreSQLiteDependencies`), declared
    by S0.
  - Do NOT add/remove targets, products, or the reader's dependency line (S0 did that).
- **Standard wave-1 allowed-edit classes (see the block at the end of this card):** you
  MAY add `import <Dep>` to MOVED files and `@testable import <NewTarget>` to failing
  `OpenBurnBarCoreTests` files, per the enumerated policies below.

## Shim
None to create. `@_exported import OpenBurnBarSQLiteReader` already exists in
`OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarSQLiteReaderReexport.swift`
(created by S0). Do NOT edit it.

## Forbidden actions (any = STOP, revert, report)
- No reformat/re-indent/reorder. No symbol/file/dir renames beyond the mv list.
- No access-level changes (none are needed — the reader's public API is already
  `public`; confirm with V1/V2, do NOT add `public` speculatively).
- Do not touch: project.yml, *.pbxproj, docs/LINT_RATIONALE.md, budgets/, any file
  not in the Allowed list, tests (stay in OpenBurnBarCoreTests, compile via
  re-export). Do not fix unrelated warnings. No `git worktree remove`.

## Enumerated semantic edits
None expected. (K1/K2 precedent: SQLiteConnection/SQLiteReading are already `public`
because Core's parsers and quota adapters — in other files — use them.)

## Pre-flight checks (BEFORE first git mv; any hit not in Allowed-edits = STOP)
1. Path-pin grep (verified empty at S0 authoring):
   ```
   for p in "Services/SQLite/SQLiteConnection.swift" "Services/SQLite/SQLiteReading.swift" "Services/SQLite"; do
     git grep -nF -- "$p" -- .github scripts tools packages .swiftlint.yml project.yml || true
   done
   ```
   Expected hits: NONE. Any hit → STOP.
2. Bundle.module grep over the mv list → must be EMPTY:
   `git grep -nF "Bundle.module" -- OpenBurnBarCore/Sources/OpenBurnBarCore/Services/SQLite` → empty. If non-empty → BLOCKED(resource-bundle).
3. Platform-conditional grep: neither file is in `openBurnBarCoreExcludes` (verified),
   so no Package.swift exclude-array edit is required for them.
4. Canon membership: mv list does not touch `Sources/OpenBurnBarKernel/Contracts/*`. Not a CANON packet.

## Local validation (ALL, in order; paste outputs into PR matrix)
- V1: `cd OpenBurnBarCore && swift build --target OpenBurnBarSQLiteReader`
- V2: `cd OpenBurnBarCore && swift build --target OpenBurnBarCore`
- V3: `grep -rlE '^\s*import (SwiftUI|AppKit)' OpenBurnBarCore/Sources/OpenBurnBarSQLiteReader || echo PURE` → must print PURE
- V4: `cd OpenBurnBarCore && swift test`
- V5: `cd OpenBurnBarDaemon && swift build`
- V6: `./scripts/debt/check-core-ui-purity-budget.sh`
- V7: `./scripts/debt/check-mission-splitbrain-budget.sh` (NOTE: this gate is already
  red on main for an unrelated AgentLens file — see the S0 PR body; confirm your diff
  does not touch AgentLens and the SAME single failure persists, else STOP)
- V8: `./scripts/debt/check-swift-file-size-budget.sh`
- V9: `./scripts/debt/check-core-target-membership-budget.sh` → exit 0. The main-target
  shrink prints "Improved: 2 file(s) left … run --update", AND the destination sibling
  `OpenBurnBarSQLiteReader` (2 files/325 lines after the move) stays UNDER its planned
  ceiling (3 files/450 lines, seeded at S0-repair — see Wave-1 learnings). Do NOT run
  `--update`; the integrator ratchets the main snapshot per wave.
- V9b: `./scripts/debt/check-core-umbrella-imports-budget.sh`
- V11: `git diff --name-status -M100 origin/main | sort` → 2 lines R100 (the mv), 1 line D (ModuleMarker.swift), 1 line M (Package.swift). Nothing else.

Linux boundary (env-gated SQLite backend): the reader's off-Apple backend rides
`sqliteReaderSQLiteDependencies`; run `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build`
if docker/Linux available, else declare "CI-covered by linux-pr-gate +
openburnbar-engine-windows" in the PR body.

## PR body template
Title: "P-01: move Services/SQLite into OpenBurnBarSQLiteReader (mechanical, shim-covered)"
- Packet: plans/core-decomposition/packets/P-01-sqlitereader.md @ <sha>
- Review map: 2 files git mv (R100 ×2), 1 marker removed, Package.swift 1-line dep edit, 0 call-site changes.
- Invariants: zero call-site changes (@_exported shim), no contract files in scope,
  off-Apple SQLite seam preserved via sqliteReaderSQLiteDependencies, no symbol renames.
- Validation matrix: V1–V11 with literal outputs.
- Deferred to CI (named): linux-pr-gate (IPC drift + Linux boundary), openburnbar-engine-windows.
- Known risks: Core losing its direct coreSQLiteDependencies edge could unmask a
  Core file that still calls SQLite directly — V2/V4 catch it locally.
- Rollback: git revert of this squash commit.
- Cross-agent receipt: saw / reaction / status / next owner.

## Acceptance criteria (reviewer checks mechanically)
A1: `git diff --name-status -M100 origin/main` matches this packet's scope exactly.
A2: Validation matrix V1–V9b all green (V7 = the SAME pre-existing single AgentLens failure, not a new one).
A3: No diff hunks in project.yml/pbxproj/LINT_RATIONALE.md/budgets.
A4: V3 shows PURE.
A5: All pre-flight path-pin hits (none) resolved.
A6: PR body names packet file + sha.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

These two mechanical edit classes were added after Wave-1 executors correctly BLOCKED on
them (see docs/CORE_DECOMPOSITION_PROGRAM.md § Wave-1 learnings). They are ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` lines at the top of MOVED files ONLY, where `<Dep>` is a module the
destination target's manifest already declares as a dependency, exactly as the compiler
demands. In the monolith these were same-module references needing no import; once the
file lives in a standalone target they are cross-module and require the import.
- Enumerate every added `import` line in the PR body (file → line).
- Adding `import OpenBurnBarCore` to a moved file is FORBIDDEN (it would invert the
  layering — the destination targets sit BELOW Core).
- P-01 expectation: the SQLite reader is self-contained (Foundation + its SQLite backend
  via the target's own `sqliteReaderSQLiteDependencies`). NO `import` additions expected;
  if V1 demands one, it must be a declared reader dependency, else STOP.

### EDIT-CLASS 2 — `@testable import <NewTarget>` on OpenBurnBarCoreTests files
For test files under `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/` that fail to COMPILE
because they reach `internal` members of MOVED files (public symbols still resolve via the
`@_exported` shim; `@testable`/internal access does NOT cross the module boundary), add
`@testable import <NewTarget>` beneath the existing `@testable import OpenBurnBarCore`.
- Do NOT modify test logic, assertions, or move test files. Enumerate every touched test
  file in the PR body.
- Pre-flight (run BEFORE the move, to anticipate): grep OpenBurnBarCoreTests for the
  basenames / top-level type names of the moved files.
- P-01 expectation: candidate `SQLiteSeamParityTests.swift` references `SQLiteConnection`
  — but the reader's API is `public` (V1 confirms), so `@testable import
  OpenBurnBarSQLiteReader` is expected to be UNNEEDED. Add it ONLY if V4 fails on an
  internal SQLite symbol.
