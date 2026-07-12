# Packet P-10: move Insights + AgentInsights models → OpenBurnBarInsights
STATE: QUEUED
LANE: C          DEPENDS-ON: S0
BASELINE-TOUCHING: none

FIRST of the three S12 packets to land (the models the engine references). Moves
`SharedModels/Insights/` (33 files) + `SharedModels/InsightVerdictWidgetSnapshot.swift`
+ TWO AgentInsights MODEL files (Bundle/Scope — NOT `AgentInsightsBundleAssembler.swift`,
re-sliced to P-08 by the S0-repair FIX-6, and NOT `AgentInsightsViewModel.swift`, which is
SwiftUI and goes to UI at S14). The `Demo/InsightVerdictDemoFixture.swift` fixture is NO
LONGER here either — re-sliced to P-09 by the S0-repair FIX-8 (it calls
`RuleBasedVerdictEngine.hash(of:)` at line ~225, and `RuleBasedVerdictEngine` lives in
`Services/Insights/Verdict/`, which P-09 owns; a fixture rides its engine's packet). This
packet removes `OpenBurnBarInsights/ModuleMarker.swift`.

**S0-repair FIX-6 (dependency-inversion re-slice, 2026-07-12).** Two files in the original
P-10 mv list referenced symbols DEFINED in `Services/Insights/` (the engine P-08 moves
LATER), so P-10 could not build standalone:
1. `AgentInsights/AgentInsightsBundleAssembler.swift` → references `InsightDataSnapshot`,
   `InsightUsageRow`, `InsightSessionRow` (all defined in
   `Services/Insights/InsightDataSource.swift`, P-08's set). **RESOLUTION: moved OUT of
   P-10 INTO P-08** (proven closed: nothing remaining in P-10 references the assembler —
   only `AgentInsightsViewModel.swift`, which STAYS in Core, does — and the assembler's
   remaining refs `AgentInsightsBundle`/`AgentInsightsScope` land in P-10 FIRST).
2. `SharedModels/Insights/InsightAnalysis.swift` → its `InsightPlatformCapabilityReport`
   struct references the `InsightProviderFamily` enum (defined in
   `Services/Insights/InsightProviderFamilyCatalog.swift`, P-08's set). This file CANNOT
   move to P-08 (its `InsightConfidence`/`InsightAnalysisResult`/`InsightMissionCandidate`/
   `InsightAnalysisAuditEntry` types are referenced by Verdict/Bundle files that STAY in
   P-10, so it must land FIRST). **RESOLUTION: this packet's executor ALSO extracts the
   pure `InsightProviderFamily` enum (`InsightProviderFamilyCatalog.swift` lines ~50–120,
   Foundation-only, no engine deps) AND the `InsightProviderFamilyEntry` struct (lines
   ~8–46, refs only the P-10 model `InsightEgressTier`) into a NEW P-10 model file
   `SharedModels/Insights/InsightProviderFamily.swift`, leaving the `InsightProviderFamilyCatalog`
   catalog logic (which needs `InsightCatalogModel`/`InsightModelCatalog` — engine) in
   `Services/Insights/InsightProviderFamilyCatalog.swift` for P-08. See "Enumerated semantic
   edits" — this is the ONE small source edit this packet is authorized to make, and it
   closes the last inversion.** (Neither the flip P-08→P-10 nor a whole-file move works:
   P-08's engine references ~30 distinct P-10 model types — `InsightDigest`×94,
   `InsightWidgetData`×58, `InsightCitation`, `InsightCanvas`, `InsightFilter`,
   `InsightTaxonomy`, … — so P-08 hard-depends on P-10 and P-10 must land first.)

**S0-repair FIX-8 (dependency-inversion re-slice, 2026-07-12).** A THIRD original-P-10 file
leaked an engine ref: `Demo/InsightVerdictDemoFixture.swift` calls
`RuleBasedVerdictEngine.hash(of: verdict)` (line ~225). `RuleBasedVerdictEngine` is defined
in `Services/Insights/Verdict/RuleBasedVerdictEngine.swift` — a subdirectory owned by **P-09**
(NOT P-08, whose scope is only the 23 ROOT `Services/Insights/*.swift` files). So the fixture
must ride P-09, not P-08: at P-08 execution time the Verdict engine is still in Core (it moves
in P-09, which lands AFTER P-08), so parking the fixture in P-08 would leave it referencing a
Core symbol and break P-08's standalone build. **RESOLUTION: moved OUT of P-10 INTO P-09.**
Proven closed: (a) the fixture's model refs `InsightCitation`/`InsightModelTag`/`InsightVerdict`
all land in P-10 (this packet, merges FIRST); (b) its engine ref `RuleBasedVerdictEngine` lands
in P-09 (same packet as the fixture); (c) its ONLY consumer, `Services/Insights/Verdict/VerdictComposer.swift`
(`InsightVerdictDemoFixture.sample(...)`), is ALSO in P-09's `Verdict/` subdirectory, so
fixture + sole consumer move together. Nothing remaining in P-10 references the fixture.

## Scope — the ONLY files you may touch

### git mv list
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/Insights OpenBurnBarCore/Sources/OpenBurnBarInsights/SharedModels
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/InsightVerdictWidgetSnapshot.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/SharedModels/InsightVerdictWidgetSnapshot.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsBundle.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsBundle.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsScope.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsScope.swift
```
Then `git rm OpenBurnBarCore/Sources/OpenBurnBarInsights/ModuleMarker.swift`.
`AgentInsights/AgentInsightsViewModel.swift` STAYS in Core (SwiftUI → S14/UI).
`AgentInsights/AgentInsightsBundleAssembler.swift` is NO LONGER in this mv list — it moved
to P-08 (FIX-6). `Demo/InsightVerdictDemoFixture.swift` is NO LONGER in this mv list either
— it moved to P-09 (FIX-8), because it calls `RuleBasedVerdictEngine.hash(of:)` and that
engine rides P-09's `Verdict/` subdirectory. After the `git mv` list, perform the ONE
authorized source edit
(`InsightProviderFamily`/`InsightProviderFamilyEntry` extraction, see "Enumerated semantic
edits"): the extracted types land as
`OpenBurnBarInsights/SharedModels/Insights/InsightProviderFamily.swift`.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE from `openBurnBarCoreExcludes`:
  `"SharedModels/Insights"`, `"SharedModels/InsightVerdictWidgetSnapshot.swift"`.
  Do NOT touch `"Demo/InsightVerdictDemoFixture.swift"` here — the Demo fixture moved to
  P-09 (FIX-8), so P-09 owns removing that exclude line. For `"AgentInsights"`: that entry
  excludes the WHOLE dir, but `AgentInsightsViewModel.swift` remains in Core, so REPLACE
  `"AgentInsights"` with `"AgentInsights/AgentInsightsViewModel.swift"` (the one file
  still in Core — it is SwiftUI, stays excluded off-Apple until S14). Since Insights is
  Apple-pruned, the moved files need NO new off-Apple exclude.

## Shim
None. Do NOT edit `OpenBurnBarInsightsReexport.swift`.

## Standard Allowed-edit classes (docs/CORE_DECOMPOSITION_PROGRAM.md)
- **AE-IMPORT**: add `import OpenBurnBarKernel` to any moved model file the Insights
  build (V1) flags for a Kernel symbol (`AgentInsightsBundle`/`Scope` or a
  `SharedModels/Insights` model may reference Kernel types). `<Dep>` must be a
  module `OpenBurnBarInsights` declares; never `import OpenBurnBarCore`. Enumerate each.
- **AE-TESTABLE**: add `@testable import OpenBurnBarInsights` beneath the existing
  `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL symbol of a
  moved model. Anticipated: `Insights/AgentInsightsScopeTests.swift`,
  `Insights/Widget/InsightVerdictWidgetSnapshotTests.swift`,
  `InsightVerdictWidgetSnapshotDiffTests.swift`. NOTE `AgentInsightsBundleAssemblerTests.swift`
  is NO LONGER anticipated here — the assembler moved to P-08 (FIX-6), so that test's
  `@testable import OpenBurnBarInsights` is a P-08 AE-TESTABLE. Likewise
  `Insights/Verdict/InsightVerdictDemoFixtureTests.swift` is NO LONGER anticipated here —
  the Demo fixture moved to P-09 (FIX-8), so that test's `@testable import OpenBurnBarInsights`
  is a P-09 AE-TESTABLE. `AgentInsightsViewModelTests.swift`
  stays paired with `AgentInsightsViewModel.swift` (which STAYS in Core → S14), so it
  keeps only `@testable import OpenBurnBarCore`. Add `@testable import OpenBurnBarInsights`
  ONLY where compile fails; enumerate each in the PR body.

## Enumerated semantic edits
ONE source edit (FIX-6 closure): extract the pure `InsightProviderFamily` enum + the
`InsightProviderFamilyEntry` struct out of
`OpenBurnBarInsights/Services/Insights/InsightProviderFamilyCatalog.swift` (they arrive
there via P-08, but P-08 lands AFTER P-10; since `InsightAnalysis.swift` — in P-10 — needs
the enum, P-10 must own it). Create
`OpenBurnBarInsights/SharedModels/Insights/InsightProviderFamily.swift` holding the enum
(`InsightProviderFamilyCatalog.swift` lines ~50–120, Foundation-only) and the
`InsightProviderFamilyEntry` struct (lines ~8–46, refs only P-10's `InsightEgressTier`).
Leave the `InsightProviderFamilyCatalog` catalog enum (lines ~131+, needs engine
`InsightCatalogModel`/`InsightModelCatalog`) in place for P-08. This is a pure move of two
`public` type decls (no logic change); enumerate the exact line ranges in the PR body.
NOTE: the file being edited (`InsightProviderFamilyCatalog.swift`) is a P-08 file — but at
P-10 execution time it still lives in Core (`Services/Insights/` not yet moved), so P-10's
executor extracts FROM the Core copy INTO the new P-10 target file; P-08's card then moves
the trimmed catalog file. Cap: this is the 1 allowed semantic edit (well under the 3 cap).

## Forbidden actions
Standard. Do NOT move `AgentInsightsViewModel.swift`.

## Pre-flight checks
1. Path-pin grep of the moved paths over the automation roots → expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `"SharedModels/Insights"`, `"SharedModels/InsightVerdictWidgetSnapshot.swift"`,
   `"AgentInsights"` are all in `openBurnBarCoreExcludes` — edit per Allowed edits.
   `"Demo/InsightVerdictDemoFixture.swift"` is ALSO present but stays untouched here (P-09
   owns it after FIX-8). Any mismatch → STOP.
4. Not a CANON packet.
5. **Symbol-closure re-check (FIX-6 + FIX-8, re-run after the re-slices — machine-derived
   2026-07-12).** Grep every P-10-remaining file's non-Foundation type refs against
   `Services/Insights/` (engine) symbols: after removing `AgentInsightsBundleAssembler.swift`
   (FIX-6) AND `Demo/InsightVerdictDemoFixture.swift` (FIX-8) AND extracting
   `InsightProviderFamily`/`InsightProviderFamilyEntry` into P-10, there are ZERO residual
   engine refs — P-10 is dependency-closed. (Before the fixes, exactly three files leaked:
   `InsightAnalysis.swift`→`InsightProviderFamily`,
   `AgentInsightsBundleAssembler.swift`→`InsightDataSnapshot`/`InsightUsageRow`/
   `InsightSessionRow`, and `Demo/InsightVerdictDemoFixture.swift`→`RuleBasedVerdictEngine`.)
   If any P-10 file still references an engine type → STOP.

## Local validation
V1 `swift build --target OpenBurnBarInsights` · V2 Core build (AgentInsightsViewModel
still compiles in Core via umbrella re-exporting the moved models) · V3 PURE (models
are Foundation-only; if one imports SwiftUI it belongs in S14, STOP) · V4 test · V5
daemon build · V-linux boundary build · V6–V9b ratchets · V11 scope.

## PR body / Acceptance
Title: "P-10: move Insights + AgentInsights models into OpenBurnBarInsights".
Invariants: models UI-free in an Apple-only target, AgentInsightsViewModel stays in
Core (via umbrella) with ZERO edits, `AgentInsightsBundleAssembler.swift` deferred to P-08
(FIX-6), `Demo/InsightVerdictDemoFixture.swift` deferred to P-09 (FIX-8 — rides its
`RuleBasedVerdictEngine` dependency in the `Verdict/` subdir), the
`InsightProviderFamily`/`Entry` extraction closes the last inversion, off-Apple excludes
narrowed. A1–A6; A3 exception: the enumerated `openBurnBarCoreExcludes` edits + the ONE
`InsightProviderFamily` extraction (Enumerated semantic edits) are IN scope. Enumerate the
extraction line ranges + the FIX-6/FIX-8 closure grep in the PR body.
