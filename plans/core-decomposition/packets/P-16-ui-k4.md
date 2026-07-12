# Packet P-16a…f (DRAFT): move Views/ + UI SharedModels → OpenBurnBarUI (K4)
STATE: QUEUED
LANE: A (serial-within-lane; owns core-ui-purity-baseline.json)
DEPENDS-ON: S0, S-H (headless-app-build CI job green), P-04a/b, P-11, P-13, P-05, P-06, P-08/09/10
BASELINE-TOUCHING: core-ui-purity (this is where the baseline ratchets toward zero)

The K4 payload (~32k LOC). OpenBurnBarUI is Apple-only. Split into dependency-closed
sub-packets by Views subdirectory so each stays under the 6k LOC cap. This card is the
SHARED template; each sub-packet gets its own PR in lane A, in order.

## Sub-packet split (by Views subdirectory; TO-ENUMERATE-AT-WAVE per sub-packet)
| Sub | Scope | ~files | ~LOC |
|---|---|---|---|
| P-16a | `Views/` root (29 files) | 29 | ~10k → may need a 2-way split at cap |
| P-16b | `Views/Substrate/` (35) | 35 | 9,377 |
| P-16c | `Views/Insights/` (38) | 38 | 6,002 |
| P-16d | `Views/MissionControl/` (12, minus MissionConsoleTypes already moved in P-11) | 11 | ~4k |
| P-16e | `Views/Cards/` (1) + `Views/Square/` (1) | 2 | ~0.8k |
| P-16f | UI SharedModels + renderers | ~13 | ~2k |

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
