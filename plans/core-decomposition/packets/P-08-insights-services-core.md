# Packet P-08: move Services/Insights core engine → OpenBurnBarInsights
STATE: QUEUED
LANE: C          DEPENDS-ON: S0, P-10 (Insights models must be in the target first)
BASELINE-TOUCHING: none

Third of three dependency-closed S12 halves by build order, but the FIRST Services
half. `OpenBurnBarInsights` is Apple-only (pruned off-Apple like OpenBurnBarData). The
engine references `SharedModels/Insights` model types, so P-10 (models) lands FIRST;
this packet then adds the 23 root engine files. `Services/Insights/Share/InsightShareCardRenderer.swift`
STAYS in Core (it is AppKit/UIKit → goes to OpenBurnBarUI at S14). Verified zero
LogParser/Views/Quota refs (compile-confirmed).

**S0-repair FIX-6 (dependency-inversion re-slice, 2026-07-12).** This packet ALSO absorbs
`AgentInsights/AgentInsightsBundleAssembler.swift`, moved OUT of P-10 because it references
`InsightDataSnapshot`/`InsightUsageRow`/`InsightSessionRow` (defined in this packet's
`Services/Insights/InsightDataSource.swift`). Its other refs — `AgentInsightsBundle`,
`AgentInsightsScope` — land in P-10 (which merges FIRST), so the assembler is
dependency-closed here. Correspondingly, P-10's executor extracts the pure
`InsightProviderFamily` enum + `InsightProviderFamilyEntry` struct into a P-10 model file;
this packet moves the TRIMMED `InsightProviderFamilyCatalog.swift` (the catalog logic that
needs `InsightCatalogModel`/`InsightModelCatalog`), and its `InsightProviderFamily` /
`InsightProviderFamilyEntry` references now resolve to the P-10 model file (P-10 merged
first). Do NOT re-add those two extracted types here.

## Scope — the ONLY files you may touch

### git mv list
Move every `.swift` file directly under `Services/Insights/` (the 23 root files, NOT
the subdirectories `Adapters/ Cadence/ Trace/ Verdict/ Share/`) into
`OpenBurnBarInsights/Services/`. Enumerate with, then run each line:
```
for f in OpenBurnBarCore/Sources/OpenBurnBarCore/Services/Insights/*.swift; do
  echo "git mv \"$f\" \"OpenBurnBarCore/Sources/OpenBurnBarInsights/Services/$(basename "$f")\""
done
```
TO-ENUMERATE-AT-WAVE: paste the 23 concrete `git mv` lines the loop prints, verify
each source exists, then run them. Do NOT move the subdirectories here (P-09 owns
Adapters/Cadence/Trace/Verdict; Share stays in Core).
Remove `OpenBurnBarInsights/ModuleMarker.swift` only in P-10 (the first Insights packet
to land); if P-10 already removed it, skip.

PLUS one AgentInsights file re-sliced from P-10 (FIX-6):
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/AgentInsights/AgentInsightsBundleAssembler.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/AgentInsights/AgentInsightsBundleAssembler.swift
```
(24 files total: 23 Services/Insights root engine files + AgentInsightsBundleAssembler.swift.)
`InsightProviderFamilyCatalog.swift` is among the 23 root files it moves, but by the time
P-08 runs, P-10 has ALREADY extracted `InsightProviderFamily`/`InsightProviderFamilyEntry`
out of it into a P-10 model file — so move the trimmed file as-is; do NOT re-add those two
types.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — the `"Services/Insights"` entry in
  `openBurnBarCoreExcludes` covers the WHOLE subtree. It can only be DELETED once
  `Share/` (the last remaining piece) also leaves Core (S14). So P-08 does NOT delete
  `"Services/Insights"` yet — but with the root files gone, the off-Apple build still
  excludes the (now empty of root files) path, which is fine. If SwiftPM errors that an
  exclude path no longer matches any file, coordinate with P-09/S14: the entry is
  deleted only when `Services/Insights/` is fully empty except `Share/`. **At P-08:
  make NO Package.swift edit** unless the build demands it; if it does, STOP and report
  (ordering issue for the integrator).

## Shim
None. `@_exported import OpenBurnBarInsights` (Apple-guarded) exists in
`OpenBurnBarInsightsReexport.swift` (S0). Do NOT edit it.

## Standard Allowed-edit classes (docs/CORE_DECOMPOSITION_PROGRAM.md)
- **AE-IMPORT**: add `import <Dep>` to a MOVED file if the Insights build (V1) demands
  a symbol that used to resolve inside Core — `<Dep>` MUST be a module
  `OpenBurnBarInsights` declares (Kernel). The Insights engine references
  `SharedModels/Insights` model types (moved to this target in P-10, which lands FIRST)
  and Kernel types; add `import OpenBurnBarKernel` to any moved file the compiler flags.
  Never `import OpenBurnBarCore`. Enumerate every added line in the PR body.
- **AE-TESTABLE**: add `@testable import OpenBurnBarInsights` beneath the existing
  `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL symbol of a
  moved engine file. Anticipated: `Insights/InsightMissionApprovalPolicyTests.swift`,
  and (FIX-6) `Insights/AgentInsightsBundleAssemblerTests.swift` — it references
  `AgentInsightsBundleAssembler`, `InsightUsageRow`, `InsightDataSnapshot` (all in this
  packet now). Add ONLY where compile fails; enumerate each in the PR body.

## Forbidden actions
Standard. Do NOT move `Share/InsightShareCardRenderer.swift`. Do NOT move the
subdirectories.

## Enumerated semantic edits
TO-ENUMERATE-AT-WAVE: compile-driven `public` additions if the engine exposed types to
Core that were `internal` (cap 3; if more, STOP — not dependency-closed). Plus the
AE-IMPORT / AE-TESTABLE lines above (enumerate the concrete files at execution). NO
`InsightProviderFamily`/`InsightProviderFamilyEntry` decls are added here — P-10 owns them
now (FIX-6); this packet's `InsightProviderFamilyCatalog.swift` only KEEPS the catalog
enum + its `InsightCatalogModel`/`InsightModelCatalog` engine logic.

## Pre-flight checks
1. Path-pin grep of `Services/Insights` over the automation roots → expected NONE (verified at S0).
2. Bundle.module grep over the 24 files (23 engine + AgentInsightsBundleAssembler.swift) →
   EMPTY (neither the Insights engine nor the assembler uses Bundle.module).
3. Platform-conditional: the `"Services/Insights"` exclude covers the subtree — see
   Allowed edits for the deletion-ordering rule.
4. Not a CANON packet.
5. **Symbol-closure re-check (FIX-6, re-run after the re-slice — machine-derived
   2026-07-12).** With P-10 merged first, every ref in `AgentInsightsBundleAssembler.swift`
   (`InsightDataSnapshot`/`InsightUsageRow`/`InsightSessionRow` → this packet's
   `InsightDataSource.swift`; `AgentInsightsBundle`/`AgentInsightsScope`/`InsightAnalysisResult`/
   `InsightMissionCandidate`/`InsightAnalysisAuditEntry`/`InsightCanvas` → P-10) resolves;
   and the trimmed `InsightProviderFamilyCatalog.swift`'s `InsightProviderFamily`/
   `InsightProviderFamilyEntry` refs resolve to the P-10 model file. P-08 is
   dependency-closed. If any ref is unresolved after P-10 → STOP (P-10 didn't land the
   extraction).

## Local validation
V1 `swift build --target OpenBurnBarInsights` · V2 Core build · V3 PURE (engine is
UI-free; if a file imports SwiftUI/AppKit, it belongs in S14, STOP) · V4 test · V5
daemon build · V6–V9b ratchets · V-linux boundary build (Insights is pruned off-Apple —
confirm the boundary build still succeeds WITHOUT this target) · V11 scope.

## PR body / Acceptance
Title: "P-08: move Services/Insights core engine into OpenBurnBarInsights". Invariants:
Apple-only target, InsightShareCardRenderer stays in Core, zero call-site changes,
`InsightMissionApprovalPolicy` now UI-free (daemon-linkable for M4/M5),
`AgentInsightsBundleAssembler.swift` re-sliced in from P-10 (FIX-6),
`InsightProviderFamily`/`Entry` owned by P-10. A1–A6. Enumerate the FIX-6 closure grep +
the AgentInsightsBundleAssembler move in the PR body.
