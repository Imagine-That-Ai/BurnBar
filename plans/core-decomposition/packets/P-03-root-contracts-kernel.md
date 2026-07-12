# Packet P-03: move root mission/search contracts → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none
CANON: not required (verified — see pre-flight 4)

The daemon's dominant Core usage is these root mission/search contracts; moving them
into the UI-free Kernel is the biggest single security-surface reduction before the
S17 daemon repoint.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionControlContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionControlMissionsContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionControlMissionsContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarMissionNextActionPlanner.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarMissionNextActionPlanner.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarSearchContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarSearchContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarDistributedNotifications.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarDistributedNotifications.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/TraceContext.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/TraceContext.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/ClientTelemetrySanitizer.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/ClientTelemetrySanitizer.swift
```

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
TO-VERIFY at execution: run V1 (`swift build --target OpenBurnBarKernel`); if the
Kernel build fails because a type these files reference is `internal` in another Core
file NOT in this packet, STOP — that means the move is not dependency-closed and the
architect must re-slice. Do NOT chase it by moving extra files. (Expected: closed.
These contracts are consumed by the daemon, so their public API is already `public`.)

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
V3 PURE on Kernel new files · V4 `swift test` · V5 daemon build · V6–V9b ratchets
(membership = shrink) · V10 `node tools/ipc/generate-burnbarrpc-canon.mjs --check`
(must be green, NO diff) · V11 scope check (7 R100 + at most 1 M Package.swift).

## PR body / Acceptance
Per template. Title: "P-03: move root mission/search contracts into OpenBurnBarKernel".
Invariants: byte-identical wire canon (no contract files in scope), zero call-site
changes, daemon still builds. A1–A6.
