# Packet P-10: move Insights + AgentInsights models → OpenBurnBarInsights
STATE: QUEUED
LANE: C          DEPENDS-ON: S0
BASELINE-TOUCHING: none

FIRST of the three S12 packets to land (the models the engine references). Moves
`SharedModels/Insights/` (33 files) + `SharedModels/InsightVerdictWidgetSnapshot.swift`
+ the three AgentInsights MODEL files (Bundle/BundleAssembler/Scope — NOT
`AgentInsightsViewModel.swift`, which is SwiftUI and goes to UI at S14) + the Demo
fixture. This packet removes `OpenBurnBarInsights/ModuleMarker.swift`.

## Scope — the ONLY files you may touch

### git mv list
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/Insights OpenBurnBarCore/Sources/OpenBurnBarInsights/SharedModels
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/InsightVerdictWidgetSnapshot.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/SharedModels/InsightVerdictWidgetSnapshot.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsBundle.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsBundle.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsBundleAssembler.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsBundleAssembler.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsScope.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsScope.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Demo/InsightVerdictDemoFixture.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/Demo/InsightVerdictDemoFixture.swift
```
Then `git rm OpenBurnBarCore/Sources/OpenBurnBarInsights/ModuleMarker.swift`.
`AgentInsights/AgentInsightsViewModel.swift` STAYS in Core (SwiftUI → S14/UI).

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE from `openBurnBarCoreExcludes`:
  `"SharedModels/Insights"`, `"SharedModels/InsightVerdictWidgetSnapshot.swift"`,
  `"Demo/InsightVerdictDemoFixture.swift"`. For `"AgentInsights"`: that entry excludes
  the WHOLE dir, but `AgentInsightsViewModel.swift` remains in Core, so REPLACE
  `"AgentInsights"` with `"AgentInsights/AgentInsightsViewModel.swift"` (the one file
  still in Core — it is SwiftUI, stays excluded off-Apple until S14). Since Insights is
  Apple-pruned, the moved files need NO new off-Apple exclude.

## Shim
None. Do NOT edit `OpenBurnBarInsightsReexport.swift`.

## Enumerated semantic edits
EDIT-CLASS 1 IS REQUIRED (see standard block). The moved Insights model files reference
Kernel-declared PUBLIC types but carry NO `import OpenBurnBarKernel` (they were same-module
in the monolith). Wave-1 executor P-10 correctly BLOCKED on this. `OpenBurnBarInsights`
declares `dependencies: [..., "OpenBurnBarKernel"]` (S0), so the import resolves. Add `import
OpenBurnBarKernel` to each moved file the build reports as missing a Kernel symbol; iterate
`swift build --target OpenBurnBarInsights` until green. The executor's static scan found at
least these 8 files need it — enumerate the FINAL set in the PR body:
  - `SharedModels/InsightVerdictWidgetSnapshot.swift` (BurnBarWidgetError)
  - `AgentInsights/AgentInsightsBundle.swift`, `AgentInsights/AgentInsightsScope.swift`,
    `SharedModels/Insights/InsightDigest.swift`, `SharedModels/Insights/InsightDataBinding.swift`,
    `SharedModels/Insights/InsightFilter.swift` (AgentProvider)
  - `SharedModels/Insights/InsightTokenUsage.swift` (BurnBarUsageEvent)
  - `SharedModels/Insights/InsightAnalysis.swift` (PlatformCrypto)
Add `import OpenBurnBarKernel` ONLY — never `import OpenBurnBarCore` (would invert layering).

## Forbidden actions
Standard. Do NOT move `AgentInsightsViewModel.swift`.

## Pre-flight checks
1. Path-pin grep of the moved paths over the automation roots → expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `"SharedModels/Insights"`, `"SharedModels/InsightVerdictWidgetSnapshot.swift"`,
   `"Demo/InsightVerdictDemoFixture.swift"`, `"AgentInsights"` are all in
   `openBurnBarCoreExcludes` — edit per Allowed edits. Any mismatch → STOP.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarInsights` (add EDIT-CLASS 1 `import OpenBurnBarKernel`
per the semantic-edits section; iterate until green) · V2 Core build (AgentInsightsViewModel
still compiles in Core via umbrella re-exporting the moved models) · V3 PURE (models are
UI-free; if one imports SwiftUI it belongs in S14, STOP) · V4 test (add EDIT-CLASS 2
`@testable import OpenBurnBarInsights` where V4 shows a test reaching an internal Insights
symbol) · V5 daemon build · V-linux boundary build · V6–V9b ratchets (Insights under planned
ceiling) · V11 scope (6 R100 + 1 D marker + 1 M Package.swift + N M moved-file imports + any
EDIT-CLASS 2 test files).

## PR body / Acceptance
Title: "P-10: move Insights + AgentInsights models into OpenBurnBarInsights".
Invariants: models UI-free in an Apple-only target, AgentInsightsViewModel stays in
Core (via umbrella) with ZERO edits, off-Apple excludes narrowed. A1–A6; A3 exception:
the enumerated `openBurnBarCoreExcludes` edits + EDIT-CLASS 1 `import OpenBurnBarKernel`
additions on moved files + any EDIT-CLASS 2 test edits are IN scope. Membership ratchet:
Insights stays UNDER its planned ceiling (100 files/20000 lines) as these ~38 model files
land.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import OpenBurnBarKernel` at the top of MOVED files that reference Kernel PUBLIC types
(the moved Insights models never needed the import in the monolith), exactly as `swift build
--target OpenBurnBarInsights` demands; iterate until green. Enumerate EVERY added line in the
PR body (the semantic-edit section above lists the 8 files the static scan found; the build
may surface a few more — add those too). `import OpenBurnBarCore` on a moved file is FORBIDDEN
(inverts layering).

### EDIT-CLASS 2 — `@testable import OpenBurnBarInsights` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE reaching `internal` members of MOVED
files (public symbols resolve via `@_exported`; `@testable`/internal does NOT cross module
boundaries), add `@testable import OpenBurnBarInsights` beneath `@testable import
OpenBurnBarCore`. Do NOT modify test logic/assertions or move test files. Enumerate touched
files in the PR body. Pre-flight candidates (grep of OpenBurnBarCoreTests): `AgentInsightsScopeTests.swift`,
`AgentInsightsBundleAssemblerTests.swift`, `InsightAnalysisTests.swift`, plus other Insight*
tests — edit ONLY those V4 proves reach an internal symbol.
