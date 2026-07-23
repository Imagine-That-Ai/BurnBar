# Packet B5: move UI-owned tests → OpenBurnBarUIModuleTests (11 files)
STATE: EXECUTED (branch core-decomp2/b5-ui-module-tests, base core-decomp2/b4-insights-tests)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarUIModuleTests/` — APPLE-PRUNED test target.
(Name deliberately ≠ `OpenBurnBarUITests`: that name is the app's Xcode UI-testing bundle,
project.yml:73.) Delete `PlaceholderTests.swift` here.

## git mv list (flat)
AgentProviderLogoBackdropTests.swift  (override: tests
  OpenBurnBarUI/SharedModels/AgentProvider+LogoBackdrop.swift `needsMonochromeLogoBackdrop`;
  the KernelModels(2) signal is the AgentProvider/AssistantRuntimeID enums it drives),
AppSkinEditorialPaletteTests.swift, DashboardLayoutContractTests.swift,
PixelClockQuotaRendererTests.swift  (override: already `@testable import OpenBurnBarUI`;
  KernelModels(10) hits are the PixelClock config models it feeds the renderer),
SmartHubDisplaySettingsModelTests.swift, SwarmColorDriverTests.swift,
SwarmLogoShapeTests.swift, SwarmSubstrateContractTests.swift,
SwarmSubstratePreviewRenderTests.swift, UnifiedQuotaSignalCurrencyTests.swift,
UnifiedToolCallAccordionTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarUI`.
- Already have `@testable import OpenBurnBarUI` (drop the Core import only): SwarmLogoShape,
  SwarmSubstrateContract, SwarmSubstratePreviewRender, UnifiedQuotaSignalCurrency,
  PixelClockQuotaRenderer.
- KernelModels hits (SwarmLogoShape 3, SwarmSubstrateContract 3, PixelClockQuotaRenderer 10,
  SmartHubDisplaySettingsModel 1, SwarmSubstratePreviewRender 1, UnifiedQuotaSignalCurrency 1):
  plain `import OpenBurnBarKernelModels` — public model types; the B0 target already depends on
  OpenBurnBarKernel, so the umbrella re-export also covers them; prefer the direct import.
- UnifiedToolCallAccordionTests uses swift-testing (`import Testing`) — the target declares
  `swiftTestingAppleDependencies`; nothing to do.

## Package.swift seam edits
`openBurnBarCoreTestExcludes`: REMOVE the 7 entries this packet carries out —
AgentProviderLogoBackdropTests.swift, SmartHubDisplaySettingsModelTests.swift,
SwarmLogoShapeTests.swift, SwarmSubstrateContractTests.swift,
SwarmSubstratePreviewRenderTests.swift, UnifiedQuotaSignalCurrencyTests.swift,
UnifiedToolCallAccordionTests.swift. (The P-16f comment block goes with the last two.)
Remaining in that list afterwards: CLITerminalSessionSupervisorTests (B1),
Insights/BurnBarHostedAdapterWireTests + Insights/InsightLiveProviderSmokeTests (B4),
MissionConsoleTests (STAY), SwitcherCLIPostLaunchFallbackTests (B7).

## Fixtures
None (SwarmSubstratePreviewRenderTests renders in-process via AppKit/SwiftUI — no bundle reads).

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list
(off-Apple builds must never see this target).

## Execution note (B5, compiler-decided)
- All 11 files `git mv`-d into `Tests/OpenBurnBarUIModuleTests/`; PlaceholderTests.swift
  deleted; `openBurnBarCoreTestExcludes` shrunk to the 2 non-B5 entries
  (MissionConsoleTests STAY + SwitcherCLIPostLaunchFallbackTests B7). No fixtures.
- `@testable import OpenBurnBarUI` does NOT re-export the module's Kernel deps, so
  KernelModels PUBLIC types needed a direct `import OpenBurnBarKernelModels`. Beyond the
  packet's original hit-list, the compiler required it on TWO more files whose only
  KernelModels signal was `AgentProvider`/`AssistantRuntimeID`:
  `AgentProviderLogoBackdropTests` and `SwarmColorDriverTests` (both build-broke with
  "cannot find 'AgentProvider' in scope" until the import was added). Final direct-import
  set: AgentProviderLogoBackdrop, SwarmColorDriver, PixelClockQuotaRenderer,
  SmartHubDisplaySettingsModel, SwarmLogoShape, SwarmSubstrateContract,
  SwarmSubstratePreviewRender, UnifiedQuotaSignalCurrency (8 files). AppSkinEditorialPalette,
  DashboardLayoutContract, UnifiedToolCallAccordion stayed UI-only (no KernelModels symbol).
- Whole-package `swift test` (Apple): 2075 tests, 0 failures (2044 XCTest + 31 swift-testing).
  The 147 moved test methods (116 XCTest + 31 `@Test`) are conserved 1:1 (git rename
  R79–R99, bodies unchanged); the only whole-package delta is the removed trivial B0
  placeholder (−1), same scaffold-teardown B1–B4 performed.
- Baseline NOT `--update`d (integrator ratchets `coretests-file-baseline.json` at the end);
  the shrink-only gate passes non-fatally (baselined=144 live=35).
