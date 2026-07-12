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

## Standard Allowed-edit classes (docs/CORE_DECOMPOSITION_PROGRAM.md)
- **AE-IMPORT**: add `import OpenBurnBarKernel` to any moved model file the Insights
  build (V1) flags for a Kernel symbol (`AgentInsightsBundle`/`Scope`/`BundleAssembler`
  or a `SharedModels/Insights` model may reference Kernel types). `<Dep>` must be a
  module `OpenBurnBarInsights` declares; never `import OpenBurnBarCore`. Enumerate each.
- **AE-TESTABLE**: add `@testable import OpenBurnBarInsights` beneath the existing
  `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL symbol of a
  moved model. Anticipated: `Insights/AgentInsightsBundleAssemblerTests.swift`,
  `Insights/AgentInsightsScopeTests.swift`,
  `Insights/Verdict/InsightVerdictDemoFixtureTests.swift`,
  `Insights/Widget/InsightVerdictWidgetSnapshotTests.swift`,
  `InsightVerdictWidgetSnapshotDiffTests.swift`. NOTE `AgentInsightsViewModelTests.swift`
  stays paired with `AgentInsightsViewModel.swift` (which STAYS in Core → S14), so it
  keeps only `@testable import OpenBurnBarCore`. Add `@testable import OpenBurnBarInsights`
  ONLY where compile fails; enumerate each in the PR body.

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
V1 `swift build --target OpenBurnBarInsights` · V2 Core build (AgentInsightsViewModel
still compiles in Core via umbrella re-exporting the moved models) · V3 PURE (models
are Foundation-only; if one imports SwiftUI it belongs in S14, STOP) · V4 test · V5
daemon build · V-linux boundary build · V6–V9b ratchets · V11 scope.

## PR body / Acceptance
Title: "P-10: move Insights + AgentInsights models into OpenBurnBarInsights".
Invariants: models UI-free in an Apple-only target, AgentInsightsViewModel stays in
Core (via umbrella) with ZERO edits, off-Apple excludes narrowed. A1–A6; A3 exception:
the enumerated `openBurnBarCoreExcludes` edits are IN scope.
