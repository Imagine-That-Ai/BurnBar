# Packet P-03: move root mission/search contracts → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none
CANON: not required (verified — see pre-flight 4)

The daemon's dominant Core usage is these root mission/search contracts; moving them
into the UI-free Kernel is the biggest single security-surface reduction before the
S17 daemon repoint.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root — 6 files; SearchContracts RE-SLICED OUT)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionControlContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionControlMissionsContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlMissionsContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionNextActionPlanner.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionNextActionPlanner.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarDistributedNotifications.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarDistributedNotifications.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TraceContext.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/TraceContext.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/ClientTelemetrySanitizer.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/ClientTelemetrySanitizer.swift
```

**RE-SLICE (S0-repair, wave-1 learning):** `OpenBurnBarSearchContracts.swift` was REMOVED
from this list. It references `BurnBarEmbeddingDistanceMetric` (defined in
`OpenBurnBarVectorKit.swift`) and `BurnBarSearchPlan` (in `OpenBurnBarSearchPlanner.swift`)
— both VectorKit-bound, so SearchContracts CANNOT precede them into the leaf Kernel target
(Kernel cannot see Core). SearchContracts now moves in **P-14 (VectorKit)** alongside
SearchPlanner + the vector index files; the daemon reaches it via the Engine umbrella, so
Kernel-residency is not required. A symbol-level closure re-check of the remaining 6 files
confirms they are dependency-closed (the only other flagged identifiers — `Origin`, `Phase`
in `OpenBurnBarMissionControlMissionsContracts.swift` — are comment-text, not type refs).

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — ONLY if the Core build (V2) reveals one of these
  files was in `openBurnBarCoreExcludes` (none are, verified at S0). If a compile error
  says a moved type is now missing off-Apple, STOP and report — do NOT invent excludes.
- Enumerated `public` keywords below (if any).

## Shim
None. Core re-exports Kernel via `KernelReexport.swift`. Do NOT edit it.

## Forbidden actions
Standard (no reformat, no renames, no project.yml/pbxproj/LINT_RATIONALE/budgets,
tests stay put, no unrelated fixes, no `git worktree remove`).

## Enumerated semantic edits
Allowed: EDIT-CLASS 1 (`import <Dep>` on moved files) and EDIT-CLASS 2 (`@testable import
OpenBurnBarKernel` on failing OpenBurnBarCoreTests) per the standard block below. All 6
moved files are `import Foundation`-only and their type references are closed against Kernel
+ the moving set, so NO `import` addition is expected; add one only if V1 demands a declared
Kernel dependency.

TO-VERIFY at execution: run V1 (`swift build --target OpenBurnBarKernel`); if the Kernel
build fails because a type these files reference is `internal` in another Core file NOT in
this packet, STOP — the move is not dependency-closed and the architect must re-slice. Do
NOT chase it by moving extra files. (Expected: closed after the SearchContracts re-slice.)

## Pre-flight checks
1. Path-pin grep (verified empty at S0): each of the 7 basenames over
   `.github scripts tools packages .swiftlint.yml project.yml` → expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: none in `openBurnBarCoreExcludes` (verified). No Package.swift edit.
4. Canon membership: mv list ∩ `Sources/OpenBurnBarKernel/Contracts/*` is EMPTY (these
   files move INTO `OpenBurnBarKernel/` root, not `Contracts/`). The canon generator
   reads ONLY `OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift` +
   `BurnBarRPCIPCCanon.generated.swift` (verified at S0) — these root contracts are
   NOT canon sources. So `node tools/ipc/generate-burnbarrpc-canon.mjs --check` must
   stay green with NO regen. If it goes red, a sibling PR raced you — BLOCKED(canon-drift).

## Local validation
V1 `swift build --target OpenBurnBarKernel` · V2 `swift build --target OpenBurnBarCore` ·
V3 PURE on Kernel new files · V4 `swift test` (EDIT-CLASS 2: pre-flight grep found
candidate `OpenBurnBarMissionControlContractsTests.swift` + `ClientTelemetrySanitizerTests.swift`
— add `@testable import OpenBurnBarKernel` to whichever V4 shows reaching an `internal`
symbol; public-only consumers need no edit) · V5 daemon build · V6–V9b ratchets
(membership = shrink; Kernel stays under its planned ceiling) · V10 `node
tools/ipc/generate-burnbarrpc-canon.mjs --check` (must be green, NO diff) · V11 scope check
(6 R100 + at most 1 M Package.swift + any EDIT-CLASS 2 test files).

## PR body / Acceptance
Per template. Title: "P-03: move root mission contracts into OpenBurnBarKernel (6 files;
SearchContracts re-sliced to P-14)". Invariants: byte-identical wire canon (no contract
files in scope), zero call-site changes, daemon still builds. A1–A6.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` at the top of MOVED files ONLY, where `<Dep>` is a module the destination
target's manifest already declares as a dependency, exactly as the compiler demands.
Enumerate every added line in the PR body. `import OpenBurnBarCore` on a moved file is
FORBIDDEN (inverts layering). P-03 expectation: NONE (the 6 files are Foundation-only and
closed against Kernel).

### EDIT-CLASS 2 — `@testable import OpenBurnBarKernel` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE because they reach `internal` members of
MOVED files (public symbols resolve via `@_exported`; `@testable`/internal does NOT cross
the module boundary), add `@testable import OpenBurnBarKernel` beneath `@testable import
OpenBurnBarCore`. Do NOT modify test logic/assertions or move test files. Enumerate touched
files in the PR body. Pre-flight candidates: `OpenBurnBarMissionControlContractsTests.swift`,
`ClientTelemetrySanitizerTests.swift` — edit ONLY those V4 proves reach an internal symbol.
