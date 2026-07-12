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

## Forbidden actions
Standard. Do NOT move `Share/InsightShareCardRenderer.swift`. Do NOT move the
subdirectories.

## Enumerated semantic edits
TO-ENUMERATE-AT-WAVE: compile-driven `public` additions if the engine exposed types to
Core that were `internal` (cap 3; if more, STOP — not dependency-closed).

## Pre-flight checks
1. Path-pin grep of `Services/Insights` over the automation roots → expected NONE (verified at S0).
2. Bundle.module grep over the 23 files → EMPTY (Insights engine does not use Bundle.module).
3. Platform-conditional: the `"Services/Insights"` exclude covers the subtree — see
   Allowed edits for the deletion-ordering rule.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarInsights` · V2 Core build · V3 PURE (engine is
UI-free; if a file imports SwiftUI/AppKit, it belongs in S14, STOP) · V4 test · V5
daemon build · V6–V9b ratchets · V-linux boundary build (Insights is pruned off-Apple —
confirm the boundary build still succeeds WITHOUT this target) · V11 scope.

## PR body / Acceptance
Title: "P-08: move Services/Insights core engine into OpenBurnBarInsights". Invariants:
Apple-only target, InsightShareCardRenderer stays in Core, zero call-site changes,
`InsightMissionApprovalPolicy` now UI-free (daemon-linkable for M4/M5). A1–A6.
