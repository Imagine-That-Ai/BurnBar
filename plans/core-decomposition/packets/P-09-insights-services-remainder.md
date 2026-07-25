# Packet P-09: move Services/Insights remainder (Adapters/Cadence/Trace/Verdict) → OpenBurnBarInsights
STATE: QUEUED
LANE: C          DEPENDS-ON: S0, P-10, P-08
BASELINE-TOUCHING: none

Second Services half: the four Insights subdirectories. `Share/` (1 file,
InsightShareCardRenderer) STAYS in Core until S14. After this packet lands,
`Services/Insights/` contains ONLY `Share/`, so this is the packet that finally
DELETES `"Services/Insights"` from `openBurnBarCoreExcludes` and re-adds `Share/`
narrowly if the off-Apple build still needs it excluded.

## Scope — the ONLY files you may touch

### git mv list
Move the whole `Adapters/ Cadence/ Trace/ Verdict/` subdirectories:
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/Adapters OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/Adapters
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/Cadence OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/Cadence
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/Trace OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/Trace
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/Verdict OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/Verdict
```
TO-ENUMERATE-AT-WAVE: verify these are the only remaining subdirs besides `Share/`
(re-run `find Services/Insights -type d`). `Share/InsightShareCardRenderer.swift` MUST
remain in Core.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — now that only `Share/` remains under
  `Services/Insights/`, replace the `"Services/Insights"` exclude entry with
  `"Services/Insights/Share"` (Share is AppKit → still excluded off-Apple until S14).
  Line-level: change the one string. If SwiftPM rejects an exclude on a path that has
  only one file, keep it as `"Services/Insights/Share/InsightShareCardRenderer.swift"`
  instead — choose whichever the build accepts; document which in the PR.

## Shim
None. Do NOT edit `OpenBurnBarInsightsReexport.swift`.

## Forbidden actions
Standard. Do NOT move `Share/`.

## Pre-flight / validation / PR / Acceptance
As P-08 — including the two standard wave-1 allowed-edit classes below. Extra: after the
move, `find Services/Insights` shows ONLY `Share/`. V-linux boundary build confirms the
narrowed exclude keeps the off-Apple graph valid. Title: "P-09: move Services/Insights
remainder into OpenBurnBarInsights". A1–A6; A3 exception: the `openBurnBarCoreExcludes`
narrowing edit + EDIT-CLASS 1 `import OpenBurnBarKernel` additions on moved files + any
EDIT-CLASS 2 test edits are IN scope. Membership: Insights under its planned ceiling
(100 files/20000 lines).

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import OpenBurnBarKernel` at the top of MOVED Adapters/Cadence/Trace/Verdict files that
reference Kernel PUBLIC types, exactly as `swift build --target OpenBurnBarInsights` demands;
iterate until green. Enumerate every added line in the PR body. `import OpenBurnBarCore` on a
moved file is FORBIDDEN (inverts layering).

### EDIT-CLASS 2 — `@testable import OpenBurnBarInsights` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE reaching `internal` members of MOVED
files (public symbols resolve via `@_exported`; `@testable`/internal does NOT cross module
boundaries), add `@testable import OpenBurnBarInsights` beneath `@testable import
OpenBurnBarCore`. Do NOT modify test logic/assertions or move test files. Enumerate touched
files in the PR body. Pre-flight candidates: `CadenceRendererTests.swift`, adapter/verdict
test files under OpenBurnBarCoreTests — edit ONLY those V4 proves reach an internal symbol.
