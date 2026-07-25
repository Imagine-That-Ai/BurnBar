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
| P-16e | `Views/Cards/` (2) + `Views/Square/` (1) | 3 | 1,097 |
| P-16f | UI SharedModels + renderers | ~13 | ~2k |

P-16f (UI SharedModels): `UIModeTheme.swift`, `AgentInsights/AgentInsightsViewModel.swift`,
`Services/Insights/Share/InsightShareCardRenderer.swift`, `SharedModels/{ThemePrimitives,
RGBA,SwarmColorDriver,DesignSystemTokens,AgentProvider+LogoBackdrop,PixelClockSettingsModel,
SmartHubDisplaySettingsModel,AgentWatchLiveActivityAttributes,AgentWatchLiveActivityIntents,
BurnBarLiveActivityAttributes,SubstrateFamily,SubscriptionTopic}.swift`,
`PixelClockQuotaRenderer.swift`, `PixelClockProviderLogoAssets.generated.swift`.

**RELOCATED INTO P-16f (S0-repair, wave-1 learning — from P-04a):** `SubstrateFamily.swift`
and `SubscriptionTopic.swift` moved here because they forward-reference UI-bound types that
land in THIS target: `SubstrateFamily` uses `RGBA` (12 calls) and `SubscriptionTopic` binds
`Views/Cards/CardEnvelope.swift` (`card: CardEnvelope?`). They cannot precede those types into
Kernel (a leaf that cannot see Core). Landing them with RGBA (P-16f) and Views/Cards/CardEnvelope
(P-16e) closes the dependency. Sub-packet ordering NOTE: P-16f must land AFTER P-16e (or move
`Views/Cards/CardEnvelope.swift` into P-16f) so both `RGBA` and `CardEnvelope` are visible to
`SubscriptionTopic` in this target. NOTE: neither file is in `openBurnBarCoreExcludes` today
(they compile cross-platform in Core main), so relocating them to Apple-only OpenBurnBarUI
drops them from the off-Apple graph. Verified SAFE at S0-repair: no off-Apple code CONSUMES
either type — `SubstrateFamily` refs off-Apple are `LinuxSubstrateSupport`/`SubstrateCatalog`
(which use the cross-platform `SubstrateCatalog`, not `SubstrateFamily`); every
`SubscriptionTopic` reference in Kernel/off-Apple Core (`AgentTier.swift`, `LinuxCardEnvelope.swift`,
`CloudVaultCrypto.swift`) is comment-text only; all real consumers are Apple (AgentLens,
OpenBurnBarMobile). RE-CONFIRM at the S14 wave; if a new off-Apple consumer appeared, the
integrator adds a cross-platform stub — enumerate at wave.

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
