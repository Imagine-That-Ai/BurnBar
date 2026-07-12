# Packet P-09: move Services/Insights remainder (Adapters/Cadence/Trace/Verdict) → OpenBurnBarInsights
STATE: QUEUED
LANE: C          DEPENDS-ON: S0, P-10, P-08
BASELINE-TOUCHING: none

Second Services half: the four Insights subdirectories. `Share/` (1 file,
InsightShareCardRenderer) STAYS in Core until S14. After this packet lands,
`Services/Insights/` contains ONLY `Share/`, so this is the packet that finally
DELETES `"Services/Insights"` from `openBurnBarCoreExcludes` and re-adds `Share/`
narrowly if the off-Apple build still needs it excluded.

**S0-repair FIX-8 (dependency-inversion re-slice, 2026-07-12).** This packet ALSO absorbs
`Demo/InsightVerdictDemoFixture.swift`, moved OUT of P-10 because it calls
`RuleBasedVerdictEngine.hash(of: verdict)` (line ~225) and `RuleBasedVerdictEngine` is
defined in `Services/Insights/Verdict/RuleBasedVerdictEngine.swift` — one of the `Verdict/`
files THIS packet moves. (The fixture could NOT ride P-08: P-08's scope is only the 23 ROOT
`Services/Insights/*.swift` files, and the Verdict engine is a subdirectory that lands here,
AFTER P-08 — so a fixture parked in P-08 would reference a still-in-Core engine and break
P-08's standalone build.) The fixture's model refs (`InsightCitation`/`InsightModelTag`/
`InsightVerdict`) land in P-10 (merges FIRST); its engine ref (`RuleBasedVerdictEngine`)
lands in THIS packet; and its ONLY consumer, `Verdict/VerdictComposer.swift`
(`InsightVerdictDemoFixture.sample(...)`), is ALSO in this packet's `Verdict/` — so fixture
+ engine + sole consumer all move together, dependency-closed. It lands under `Demo/` in the
target: `OpenBurnBarInsights/Demo/InsightVerdictDemoFixture.swift`.

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

PLUS one Demo file re-sliced from P-10 (FIX-8 — it rides its `RuleBasedVerdictEngine`
dependency, which is in the `Verdict/` subtree this packet moves):
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Demo/InsightVerdictDemoFixture.swift OpenBurnBarCore/Sources/OpenBurnBarInsights/Demo/InsightVerdictDemoFixture.swift
```

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — now that only `Share/` remains under
  `Services/Insights/`, replace the `"Services/Insights"` exclude entry with
  `"Services/Insights/Share"` (Share is AppKit → still excluded off-Apple until S14).
  Line-level: change the one string. If SwiftPM rejects an exclude on a path that has
  only one file, keep it as `"Services/Insights/Share/InsightShareCardRenderer.swift"`
  instead — choose whichever the build accepts; document which in the PR.
  ALSO (FIX-8): DELETE the `"Demo/InsightVerdictDemoFixture.swift"` entry from
  `openBurnBarCoreExcludes` — the fixture leaves Core in THIS packet (P-10 no longer moves
  it, so P-10 leaves that exclude in place). Since `OpenBurnBarInsights` is Apple-pruned,
  the moved fixture needs NO new off-Apple exclude.

## Shim
None. Do NOT edit `OpenBurnBarInsightsReexport.swift`.

## Standard Allowed-edit classes (docs/CORE_DECOMPOSITION_PROGRAM.md)
- **AE-IMPORT / AE-TESTABLE** as in P-08: add `import OpenBurnBarKernel` to any moved
  Adapters/Cadence/Trace/Verdict file the Insights build flags for a Kernel symbol
  (never `import OpenBurnBarCore`); add `@testable import OpenBurnBarInsights` beneath
  the existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  moved symbol (anticipated: any `Insights/Adapters|Cadence|Trace|Verdict` test that
  fails to compile, and (FIX-8) `Insights/Verdict/InsightVerdictDemoFixtureTests.swift` —
  it reaches the moved `InsightVerdictDemoFixture`). Enumerate every added line in the PR body.

## Forbidden actions
Standard. Do NOT move `Share/`.

## Pre-flight / validation / PR / Acceptance
As P-08. Extra: after the move, `find Services/Insights` shows ONLY `Share/`. V-linux
boundary build confirms the narrowed exclude keeps the off-Apple graph valid.
**Symbol-closure re-check (FIX-8, machine-derived 2026-07-12):** with P-10 + P-08 merged
first, every ref in `Demo/InsightVerdictDemoFixture.swift` resolves —
`RuleBasedVerdictEngine` → this packet's `Verdict/RuleBasedVerdictEngine.swift`;
`InsightCitation`/`InsightModelTag`/`InsightVerdict` → P-10; and the fixture's sole consumer
`Verdict/VerdictComposer.swift` moves in this same packet. If any ref is unresolved → STOP.
Title: "P-09: move Services/Insights remainder into OpenBurnBarInsights". A1–A6; A3
exception: the `openBurnBarCoreExcludes` narrowing edit + the FIX-8 Demo-exclude deletion
are IN scope. Enumerate the FIX-8 closure grep + the Demo fixture move in the PR body.
