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

## Standard Allowed-edit classes (docs/CORE_DECOMPOSITION_PROGRAM.md)
- **AE-IMPORT / AE-TESTABLE** as in P-08: add `import OpenBurnBarKernel` to any moved
  Adapters/Cadence/Trace/Verdict file the Insights build flags for a Kernel symbol
  (never `import OpenBurnBarCore`); add `@testable import OpenBurnBarInsights` beneath
  the existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  moved symbol (anticipated: any `Insights/Adapters|Cadence|Trace|Verdict` test that
  fails to compile). Enumerate every added line in the PR body.

## Forbidden actions
Standard. Do NOT move `Share/`.

## Pre-flight / validation / PR / Acceptance
As P-08. Extra: after the move, `find Services/Insights` shows ONLY `Share/`. V-linux
boundary build confirms the narrowed exclude keeps the off-Apple graph valid.
Title: "P-09: move Services/Insights remainder into OpenBurnBarInsights". A1–A6; A3
exception: the `openBurnBarCoreExcludes` narrowing edit is IN scope.
