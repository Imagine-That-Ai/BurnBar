# Packet P-16a…f: move Views/ + UI SharedModels → OpenBurnBarUI (K4)
STATE: P-16a MERGED (base); P-16b PR #1650; P-16c PR #1656 (Views/MissionControl); P-16d PR #1666 (Cards/Square + straggler cluster); P-16b2/e/f QUEUED
LANE: A (serial-within-lane; owns core-ui-purity-baseline.json)
DEPENDS-ON: S0, S-H (headless-app-build CI job green), P-04a/b, P-11, P-13, P-05, P-06, P-08/09/10
BASELINE-TOUCHING: core-ui-purity (this is where the baseline ratchets toward zero)

The K4 payload (~32k LOC). OpenBurnBarUI is Apple-only. Split into dependency-closed
sub-packets by Views subdirectory so each stays under the 6k LOC cap. This card is the
SHARED template; each sub-packet gets its own PR in lane A, in order.

## Sub-packet split — ENUMERATED from the live tree (P-16a, 2026-07-13)
Ordering is **compile-closure**: leaf-most Views subdirectories first, the `Views/`
root LAST (root files — `SwarmCanvasView+*`, the `Unified*` design-system, loaders —
are the widest consumers and reference the subdir views + the theme/color cluster).
Re-lettered from the earlier draft so **P-16a = `Views/Substrate/`** (the leaf-most,
Kernel-only subtree; it depends on NOTHING else under `Views/`, so it goes first and is
now DONE). Every intermediate state builds; each sub-packet is its own lane-A PR in order.

| Sub | Scope | files | LOC | STATE |
|---|---|---|---|---|
| **P-16a** | **`Views/Substrate/`** (incl. Aurora/Constellation/Families/Flow/Mesh/Moire/Volumetric) **+ pulled-forward `SharedModels/RGBA.swift`** (see convergence note) | 35 + 1 | 9,377 (+69) | MERGED (base) |
| **P-16b** | **`Views/Insights/` root (32)** **+ pulled-forward design-system closure (8)**: `Views/{UnifiedDesignSystem,UnifiedGlassCard,UnifiedProviderLogoView}.swift`, `SharedModels/{ThemePrimitives,DesignSystemTokens,AgentProvider+LogoBackdrop}.swift`, `UIModeTheme.swift`, `AgentInsights/AgentInsightsViewModel.swift` (see P-16b convergence note). **`Views/Insights/Verdict/` DEFERRED → P-16b2.** | 40 | 6,381 | **THIS PR** |
| P-16b2 | `Views/Insights/Verdict/` (6) — trailing sub-packet (the card-prescribed 6k relief valve; Verdict is bidirectionally decoupled from Insights-root views, uses only the now-in-UI `UnifiedDesignSystem`) | 6 | 926 | QUEUED |
| P-16c | `Views/MissionControl/` (11; `MissionConsoleTypes` already moved in P-11; `UnifiedDesignSystem`/`UIModeTheme`/color cluster already in UI via P-16b — no design-system pull-forward needed) | 11 | 3,694 | **PR #1656** (base p-16b; see P-16c convergence note) |
| P-16d | `Views/Cards/CardEnvelopeView.swift` + `Views/Square/UnifiedSearchIndex.swift` **+ the still-in-Core UI-straggler cluster from P-16e** (`SharedModels/{SwarmColorDriver,PixelClockSettingsModel,SmartHubDisplaySettingsModel,AgentWatchLiveActivityAttributes,AgentWatchLiveActivityIntents,BurnBarLiveActivityAttributes}.swift`, `PixelClockQuotaRenderer.swift`, `PixelClockProviderLogoAssets.generated.swift`) — merged per the P-16d executor directive + live-tree verification (see P-16d convergence note). | 10 | 3,610 | **PR #1666** (base p-16c) |
| P-16e | `Services/Insights/Share/InsightShareCardRenderer.swift` (1) — the ONLY UI-straggler left after P-16d; the SharedModels/renderers cluster shipped in P-16d, `UIModeTheme.swift` + `AgentInsights/AgentInsightsViewModel.swift` in P-16b. Rides the `"Services/Insights/Share"` exclude (drop that entry). | 1 | ~0.2k | QUEUED |
| P-16f | `Views/` **root** (26 — `UnifiedDesignSystem`/`UnifiedGlassCard`/`UnifiedProviderLogoView` already moved by P-16b) — the LAST sub-packet; deletes `"Views"` from `openBurnBarCoreExcludes` entirely + every remaining SharedModels UI exclude | 26 | ~9.4k | QUEUED |

> P-16b may exceed the 6k cap once compile-closure adds imports; if so, split
> `Views/Insights/Verdict/` (6 files, 926 LOC) into its own trailing sub-packet.
> **EXECUTED (2026-07-13):** P-16b hit 6,381 LOC after the compile-closure design-system
> pull-forward, so `Views/Insights/Verdict/` was split OUT into P-16b2 (Verdict is fully
> decoupled from Insights-root views in both directions — verified by grep). The 6,381 is
> ~6% over the advisory 6k sizing guideline (no hard CI gate); the overage is the
> irreducible design-system closure (8 pulled-forward files) that ALL Insights-root views
> depend on — splitting it from its consumers would create more broken intermediate states.
> P-16f exceeds the 6k LOC cap (9,845) and MUST be split ≥2 ways at execution
> (e.g. the `SwarmCanvasView+*` cluster vs the `Unified*` design-system cluster vs
> the logo/loader views); the mover enumerates the cut by compile-closure.

**P-16e (UI-straggler remainder), enumerated (still in Core as of P-16d):**
`Services/Insights/Share/InsightShareCardRenderer.swift` — the SINGLE remaining
UI-straggler (AppKit/UIKit share-card renderer under the `"Services/Insights/Share"`
exclude). Everything else this list previously carried has already landed:
> `SharedModels/RGBA.swift` — P-16a pulled it forward. `UIModeTheme.swift`,
> `AgentInsights/AgentInsightsViewModel.swift`, `SharedModels/{ThemePrimitives,
> DesignSystemTokens,AgentProvider+LogoBackdrop}.swift` — P-16b pulled them forward.
> **`SharedModels/{SwarmColorDriver,PixelClockSettingsModel,SmartHubDisplaySettingsModel,
> AgentWatchLiveActivityAttributes,AgentWatchLiveActivityIntents,BurnBarLiveActivityAttributes}.swift`
> + `PixelClockQuotaRenderer.swift` + `PixelClockProviderLogoAssets.generated.swift` —
> P-16d shipped them (PR #1666)** with `Views/Cards`+`Views/Square` (P-16d convergence
> note below). `SwarmColorDriver` landed in P-16d (its `DesignSystemColors`/RGBA-color-math
> refs resolve same-module in UI; its still-in-Core `SwarmCanvasView*` consumers reach it
> cross-module via the re-export). `Views/Cards/CardEnvelope.swift` + the pure `RGBA` struct
> were already moved to the Kernel by P-04a. Note the `Kernel` off-Apple `SubstrateCatalog` stub
> (`LinuxSubstrateSupport.swift`) shadows the real UI `SubstrateCatalog` on Apple once
> the real one is re-exported — any P-16b–f consumer that references `SubstrateCatalog`
> unqualified on Apple must module-qualify it (`OpenBurnBarUI.SubstrateCatalog`), exactly
> as P-16a did for the two Substrate test files.

### P-16a convergence note (executed 2026-07-13) — RGBA color-math hub pulled forward
Compile-closure (`swift build --target OpenBurnBarUI`, learning 9) proved `Views/Substrate/`
is NOT dependency-closed against OpenBurnBarUI on `SharedModels/RGBA.swift` alone: Substrate
uses `RGBA.color` (×185), `.mix` (×72), `.bucketKey` (×5), `.darkened` (×4) — extension
members that live in Core's `SharedModels/RGBA.swift` (the P-04a-planned P-16f file), NOT in
the Kernel's `RGBA` struct. The fix (minimal-file-forward, documented):
- `git mv SharedModels/RGBA.swift` Core→`OpenBurnBarUI/SharedModels/RGBA.swift` (this PR;
  removed from P-16e's list above). It compiles in UI (`import OpenBurnBarKernel` for the
  `RGBA` struct + its existing `#if canImport(SwiftUI)` `SwiftUI`).
- Its `mix`/`lightened`/`darkened` + `Double.clamped` were module-`internal` (fine in Core,
  same module); bumped to `public` so Core consumers that STAY above UI (`SharedModels/
  SwarmColorDriver.swift`, `Views/SwarmCanvasView+*`) reach them cross-module via Core's
  `@_exported import OpenBurnBarUI`. Access widening only — zero behavior change; single
  definition graph-wide (no ambiguity). `bucketKey`/`color` were already `public`.
- OFF-APPLE SAFE: all three color-math consumers (`SwarmColorDriver`, `SwarmCanvasView+Color`,
  `SwarmCanvasView+Substrate`) are ALREADY off-Apple-excluded (`SwarmColorDriver` explicit;
  the two `SwarmCanvasView+*` under `"Views"`), so no off-Apple-live Core file needs the moved
  extensions; UI is pruned whole off-Apple. `SharedModels/RGBA.swift` had ZERO functional
  path-pins (`.github`/`scripts`/CODEOWNERS/project.yml/swiftlint all clean).

> **P-04a convergence note (2026-07-12).** P-04a already moved two files this card
> previously listed: (1) `Views/Cards/CardEnvelope.swift` — the full Foundation-only
> `CardEnvelope` enum — moved to `OpenBurnBarKernel/SharedModels/CardEnvelope.swift`
> (it is a pure wire model; only its renderer `CardEnvelopeView.swift` remains under
> `Views/Cards/`, so P-16e is now 1 Cards file, not 2). (2) The Foundation-pure `RGBA`
> value type was extracted into `OpenBurnBarKernel/SharedModels/RGBA.swift`; Core's
> `SharedModels/RGBA.swift` now holds ONLY the `#if canImport(SwiftUI)` `.color` bridge
> + color-math extensions, so P-16f still moves `SharedModels/RGBA.swift` (bridge-only
> now) but must NOT move the `RGBA` struct definition (already in the Kernel).

P-16f (`Views/` root, 26 files after P-16b): the `SwarmCanvasView+*` cluster, the remaining
`Unified*` views (`UnifiedMiniStat`/`UnifiedProviderTheme`/`UnifiedQuotaSignalView`/
`UnifiedSkeletonView`/`UnifiedCacheHitRateBadge`/`UnifiedToolCallAccordion`/…), the logo/loader
views, `BurnBarLogoFormationView`, `EmberSurfaceBackground`, `NestHubMiniPreview`,
`PixelClockPreviewView`, etc. `UnifiedDesignSystem`/`UnifiedGlassCard`/`UnifiedProviderLogoView`
+ the `UIModeTheme`/`ThemePrimitives`/`DesignSystemTokens`/`AgentProvider+LogoBackdrop` cluster
already moved with P-16b, so P-16f no longer carries them. (`SharedModels/RGBA` already in UI
via P-16a; the `RGBA` struct + `CardEnvelope` already in Kernel via P-04a.) P-16f still MUST be
split ≥2 ways (LOC cap) and deletes `"Views"` from `openBurnBarCoreExcludes` entirely.

### P-16b convergence note (executed 2026-07-13) — Insights-root split + design-system pull-forward
Compile-closure (`swift build --target OpenBurnBarUI`, learnings 9/10) proved `Views/Insights/`
is NOT dependency-closed against OpenBurnBarUI on its own. The closure required pulling forward
the whole design-system foundation the Insights views consume, and splitting off `Verdict/`:
- **Moved 32 `Views/Insights/*.swift` root views** Core→UI. **Deferred `Views/Insights/Verdict/`
  (6 files, 926 LOC) → P-16b2** (the card's prescribed 6k relief valve). Verdict is
  bidirectionally decoupled from Insights-root views (grep-verified both directions), so the
  split builds cleanly; Verdict rides a later PR and reaches the now-in-UI `UnifiedDesignSystem`.
- **Pulled forward 8 design-system-closure files** (minimal-file-forward, each grep-proven a hub
  with no further root-type deps): `Views/{UnifiedDesignSystem,UnifiedGlassCard,
  UnifiedProviderLogoView}.swift` (used by all/1/3 Insights views resp.), the color cluster
  `SharedModels/{ThemePrimitives,DesignSystemTokens}.swift` (`UnifiedDesignSystem.Colors` uses
  `ThemePrimitives`'s `Color(editorial:light:dark:)` init + `DesignSystemTokens` hex strings),
  `SharedModels/AgentProvider+LogoBackdrop.swift` (the `AgentProvider` logo-backdrop extension
  hub `UnifiedProviderLogoView` calls), `UIModeTheme.swift` (`UnifiedGlassCard` constructs it),
  and `AgentInsights/AgentInsightsViewModel.swift` (`AgentInsightsView` binds it). All removed
  from the P-16e/P-16f lists above.
- **AE-IMPORT (compiler-driven):** `import OpenBurnBarInsights` ×33 (Insights view files +
  `AgentInsightsViewModel` + `AgentInsightsHeaderView` — for `InsightWidgetData`/`InsightWidget`/
  `InsightCitation`/`AgentInsights*` model types) and `import OpenBurnBarKernel` ×9 (the 3
  `Unified*` + `UIModeTheme` + `ThemePrimitives` + `DesignSystemTokens` +
  `AgentProvider+LogoBackdrop` + `IntelligenceBriefView` + `AgentInsightsRosterView` — for
  `AgentProvider`/`RGBA`/`UIMode`). Every moved file otherwise byte-identical (pure `git mv` +
  import lines; zero logic edits). **AE-TESTABLE: NONE** — the one test hit
  (`InsightAnalysisTests` → `IntelligenceBriefFormatting`) resolves via Core's
  `@_exported import OpenBurnBarUI` because the enum + its methods are `public` (test-target
  build + full suite green, 6072 tests, 0 failures).
- **NO access-widening needed** (unlike P-16a's RGBA): the 23 staying-in-Core consumers of
  `UnifiedDesignSystem`/`DesignSystemColors`/`UIModeTheme` reach the moved symbols cross-module
  via the re-export, and every moved symbol was already `public`. **NO `SubstrateCatalog`
  qualification needed** (Insights views don't reference it). **OFF-APPLE SAFE:** every consumer
  of a moved symbol is off-Apple-excluded (all under `"Views"`, or `SwarmColorDriver` explicit),
  grep-verified no off-Apple-live Core file dangles; `Package.swift` drops the 3 now-stale
  excludes (`AgentInsightsViewModel`, `AgentProvider+LogoBackdrop`, `ThemePrimitives`;
  `DesignSystemTokens`/`UIModeTheme` were never excluded — Foundation-only / `#if canImport`),
  and `"Views"` still resolves (Verdict + MissionControl/Cards/Square + Views-root remain).
  Zero functional path-pins for any moved file (`.github`/`scripts`/CODEOWNERS/project.yml/
  swiftlint all clean).

### P-16c convergence note (executed 2026-07-13, PR #1656) — MissionControl is Kernel-closed
Compile-closure (`swift build --target OpenBurnBarUI`, learnings 9/10) proved `Views/MissionControl/`
IS dependency-closed against OpenBurnBarUI with a single declared dep — the Kernel — and needs
**no** design-system pull-forward (its `Unified*`/theme/color deps already landed in UI via
P-16a/P-16b; `MissionConsoleTypes` in the Kernel via P-11):
- **Moved 11 `Views/MissionControl/*.swift`** Core→`OpenBurnBarUI/Views/MissionControl/`. Nothing
  deferred; 3,694 LOC is well under the 6k valve.
- **AE-IMPORT (compiler-driven):** `import OpenBurnBarKernel` ×10 — the Kernel-resident
  `MissionConsole*` types (`MissionConsoleRuntime`/`Kind`/`Depth`/`ApprovalMode`/`Forecast`/
  `Formatting`/`Host`/`Snapshot`/`SystemHealth`/`ActiveTile`/`ApprovalAsk`/`TickerEntry`/
  `DispatchRequest`/`DispatchOutcome`, moved by P-11) + `MissionGroupDocument` (Kernel
  `MissionGroupContracts`). `MissionGlassSurface.swift` needs **NO** import (100% rename — its
  only non-SwiftUI refs, `UnifiedDesignSystem`/`LiquidGlassEffectIfAvailable`, are same-module
  UI). No `Quota`/`Insights`/`Hermes`/`Pretext`/`LogParsers` import demanded (every `Hermes`/
  `Pretext`/`AgentLens` occurrence is a string literal, not a type ref). Zero logic edits.
- **AE-TESTABLE: NONE.** The only test touching moved symbols
  (`OpenBurnBarCoreTests/MissionConsoleTests.swift` → `MissionFABGauge.Configuration` +
  `MissionConsoleRuntime`/`MissionConsoleForecastComputer`) is **already** in
  `openBurnBarCoreTestExcludes`; no non-excluded test references the moved types, so the SPM test
  target compiles unchanged (test-target build + full suite green, exit 0).
- **NO access-widening needed** (unlike P-16a's RGBA) and **NO `SubstrateCatalog` qualification**
  (MissionControl doesn't reference it): grep-verified **zero** remaining Core Views files (and
  zero non-Views Core files) reference any moved MissionControl public type — it is a
  self-contained leaf subtree. **OFF-APPLE SAFE:** MissionControl rode the wholesale `"Views"`
  exclude (never a distinct entry), which still resolves (Insights/Verdict + Cards/Square +
  Views-root remain); UI is pruned whole off-Apple, so `Package.swift` changes are a doc comment
  only — **no exclude line edits, no new excludes**. Daemon build graph verified to contain **0**
  `OpenBurnBarUI` module references (daemon still does not link UI). Zero functional path-pins;
  no `Bundle.module` resource-bundle hit. `budgets/core-ui-purity-baseline.json` `--update`: 41→30.

### P-16d convergence note (executed 2026-07-13, PR #1666) — Cards/Square + straggler cluster, one access-widening hub
The P-16d executor directive scoped this packet as `Views/Cards` + `Views/Square` **plus** the
still-in-Core UI-straggler SharedModels/renderers (the card's P-16e cluster), verified file-by-file
against the live p-16c tree + the P-04a RGBA split. Result: **10 files, 3,610 LOC** moved
Core→UI (`UIModeTheme.swift` + the 3 theme SharedModels were already in UI via P-16a/b, so they
were excluded; `InsightShareCardRenderer.swift` stays for P-16e). Compile-closure
(`swift build --target OpenBurnBarUI`, learnings 9/10):
- **AE-IMPORT (compiler-driven):** `import OpenBurnBarKernel` ×6 — `SwarmColorDriver.swift`
  (`AgentProvider`/`RGBA`), `CardEnvelopeView.swift` (`CardEnvelope`/`CardApproval` P-04a,
  `MissionConsoleSnapshot` P-11), `UnifiedSearchIndex.swift` (`CardEnvelope`/`MissionConsoleActiveTile`),
  `PixelClockSettingsModel.swift` + `SmartHubDisplaySettingsModel.swift` (`AgentProvider`),
  `PixelClockQuotaRenderer.swift` (`PixelClock{Config,Palette,DrawInstruction,QuotaItem,RenderedPage,
  AgentStatus,SpinnerStyle}` — Kernel `SharedModels/PixelClockConfig.swift`). The other 4 need NO
  import (self-contained: `PixelClockProviderLogoAssets.generated.swift` → `PixelClockProviderLogo`
  same-module; the 3 LiveActivity files → ActivityKit/AppIntents + self). No `import OpenBurnBarCore`;
  only Kernel demanded.
- **Access-widening hub (learning 10):** still-in-Core `Views/PixelClockPreviewView.swift` (P-16f)
  calls `PixelClockQuotaRenderer.providerLogo(for:)` and reads the returned `PixelClockProviderLogo`'s
  `.pixels`/`.colorHex(row:column:)` cross-module via the re-export → bumped `PixelClockProviderLogo`
  (type) + `pixels` + `colorHex` + `providerLogo` module-`internal`→`public`. Making the type public
  dropped its implicit-internal `Sendable` (global-static instances in `PixelClockProviderLogoAssets`),
  so added explicit `Sendable` (members `String`+`[[String?]]`, already Sendable — zero behavior
  change). `SwarmColorDriver` needed **NO** widening (already fully `public`; its `SwarmCanvasView*`
  Core consumers reach it via the re-export).
- **AE-TESTABLE ×1:** `@testable import OpenBurnBarUI` in `OpenBurnBarCoreTests/PixelClockQuotaRendererTests.swift`
  (reads internal `PixelClockProviderLogo.sourceName/rows` + `providerLogoPattern`).
  `SwarmColorDriverTests` + `HermesSquarePhaseATests` compile via the umbrella (public-only, no
  `@testable`). `SmartHubDisplaySettingsModelTests` already in `openBurnBarCoreTestExcludes`.
- **Package.swift:** removed the **5** stale off-Apple excludes for moved files
  (`AgentWatchLiveActivityAttributes`, `BurnBarLiveActivityAttributes`, `PixelClockSettingsModel`,
  `SmartHubDisplaySettingsModel`, `SwarmColorDriver`); the other 5 were never excluded (Foundation-
  only / `#if os(iOS)`; Cards/Square rode `"Views"`). **NO new UI exclude** (UI pruned whole
  off-Apple). **OFF-APPLE SAFE:** the ONLY still-in-Core consumers of every moved symbol are 3 files
  (`PixelClockPreviewView`, `SwarmCanvasView`, `SwarmCanvasView+Color`), ALL under `"Views"`; boundary
  manifest parses clean (`swift package dump-package`, `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1`).
  V1 UI / V2 Core / Engine / daemon builds ✔; full `swift test` ✔ exit 0; ui-purity `--update` 30→29.

## Per-sub-packet rules
- Deps: `OpenBurnBarUI` already depends on Kernel/Quota/Insights/Hermes/Pretext/LogParsers
  (S0). Add nothing; if the compiler demands a dep S0 didn't declare, STOP — that is a
  manifest change reserved for the integrator.
- Allowed Package.swift edits: DELETE the moved paths from `openBurnBarCoreExcludes`
  (`"Views"` is excluded wholesale — narrow it to the still-in-Core subset as each
  sub-packet lands, exactly like P-09 narrows Services/Insights; the LAST UI sub-packet
  deletes `"Views"` entirely and every remaining SharedModels UI exclude).
- `budgets/core-ui-purity-baseline.json` — `--update` in EACH sub-packet (each drops a
  batch of SwiftUI/AppKit files from Core; the baseline ratchets toward zero).
- V3 is WAIVED for OpenBurnBarUI (it is the UI target, not in pureTargets).

## Precondition
S-H headless-app-build CI job MUST be green first (out-of-tree worktree + main's
`.spm-cache` + `-disableAutomaticPackageResolution`). project.yml keeps
`product: OpenBurnBarCore` (XcodeGen untouched). Snapshot/ViewInspector tests in
OpenBurnBarTests stay green. `SwarmSubstrate*` tests in `openBurnBarCoreTestExcludes`
→ new OpenBurnBarUITests SPM test target OR stay filtered (integrator decides).

## Validation (per sub-packet)
V1 `swift build --target OpenBurnBarUI` · V2 Core build · V4 test · V5 daemon build
(daemon must STILL not link UI) · ui-purity `--update` + check · V-linux boundary (UI
absent off-Apple) · headless app build (S-H, in CI) · V11 scope. A1–A6 per sub-packet;
BASELINE-TOUCHING core-ui-purity; A4 waived.
