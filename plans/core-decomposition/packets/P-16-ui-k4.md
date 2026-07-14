# Packet P-16a…f: move Views/ + UI SharedModels → OpenBurnBarUI (K4)
STATE: P-16a PR_OPEN (Views/Substrate + RGBA.swift); P-16b…f QUEUED
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
| **P-16a** | **`Views/Substrate/`** (incl. Aurora/Constellation/Families/Flow/Mesh/Moire/Volumetric) **+ pulled-forward `SharedModels/RGBA.swift`** (see convergence note) | 35 + 1 | 9,377 (+69) | **THIS PR** |
| P-16b | `Views/Insights/` + `Views/Insights/Verdict/` | 38 | 6,002 | QUEUED |
| P-16c | `Views/MissionControl/` (11; `MissionConsoleTypes` already moved in P-11) | 11 | 3,694 | QUEUED |
| P-16d | `Views/Cards/CardEnvelopeView.swift` (1) + `Views/Square/UnifiedSearchIndex.swift` (1) | 2 | 802 | QUEUED |
| P-16e | UI `SharedModels` + renderers + `UIModeTheme.swift` + `AgentInsights/AgentInsightsViewModel.swift` + `Services/Insights/Share/InsightShareCardRenderer.swift` (see P-16e list below) | 14 | ~3k | QUEUED |
| P-16f | `Views/` **root** (29) — the LAST sub-packet; deletes `"Views"` from `openBurnBarCoreExcludes` entirely + every remaining SharedModels UI exclude | 29 | 9,845 | QUEUED |

> P-16b may exceed the 6k cap once compile-closure adds imports; if so, split
> `Views/Insights/Verdict/` (6 files, 926 LOC) into its own trailing sub-packet.
> P-16f exceeds the 6k LOC cap (9,845) and MUST be split ≥2 ways at execution
> (e.g. the `SwarmCanvasView+*` cluster vs the `Unified*` design-system cluster vs
> the logo/loader views); the mover enumerates the cut by compile-closure.

**P-16e (UI SharedModels + renderers), enumerated (still in Core as of P-16a):**
`UIModeTheme.swift`, `AgentInsights/AgentInsightsViewModel.swift`,
`Services/Insights/Share/InsightShareCardRenderer.swift`,
`SharedModels/{ThemePrimitives,SwarmColorDriver,DesignSystemTokens,AgentProvider+LogoBackdrop,
PixelClockSettingsModel,SmartHubDisplaySettingsModel,AgentWatchLiveActivityAttributes,
AgentWatchLiveActivityIntents,BurnBarLiveActivityAttributes}.swift`,
`PixelClockQuotaRenderer.swift`, `PixelClockProviderLogoAssets.generated.swift`.
> `SharedModels/RGBA.swift` was REMOVED from this list — P-16a pulled it forward
> (convergence note below). `Views/Cards/CardEnvelope.swift` + the pure `RGBA` struct
> were already moved to the Kernel by P-04a. `SwarmColorDriver`/`DesignSystemTokens`/
> `ThemePrimitives` form a color cluster consumed by the `Views/` root; keep them with
> or ahead of P-16f (they reach the now-in-UI `RGBA` color-math via Kernel + the
> re-export). Note the `Kernel` off-Apple `SubstrateCatalog` stub
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

P-16f (UI SharedModels): `UIModeTheme.swift`, `AgentInsights/AgentInsightsViewModel.swift`,
`Services/Insights/Share/InsightShareCardRenderer.swift`, `SharedModels/{ThemePrimitives,
RGBA,SwarmColorDriver,DesignSystemTokens,AgentProvider+LogoBackdrop,PixelClockSettingsModel,
SmartHubDisplaySettingsModel,AgentWatchLiveActivityAttributes,AgentWatchLiveActivityIntents,
BurnBarLiveActivityAttributes}.swift`, `PixelClockQuotaRenderer.swift`,
`PixelClockProviderLogoAssets.generated.swift`.

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
