# Packet B7: move LaunchServices-owned tests → OpenBurnBarLaunchServicesTests (7 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarLaunchServicesTests/` — APPLE-PRUNED test target
(the OpenBurnBarLaunchServices module is Apple-only). Delete `PlaceholderTests.swift` here.

## git mv list (flat)
AppCheckDebugTokenEnvironmentTests.swift  (tests
  OpenBurnBarLaunchServices/AppCheckDebugTokenEnvironment.swift),
CLIAuthDiscoveryTests.swift, CLILaunchAdapterExecutableResolutionTests.swift,
CLILaunchCoordinatorAndRedactorTests.swift, CLILaunchInvokerTests.swift,
ChromeProfileDiscoveryTests.swift  (override: tests
  OpenBurnBarLaunchServices/ChromeProfileDiscovery.swift; the Insights(1) tie-hit is a false
  positive), SwitcherCLIPostLaunchFallbackTests.swift

## Expected @testable rewrite per file
Default: keep/promote to `@testable import OpenBurnBarLaunchServices` (already present in 6 of
7 — AppCheckDebugTokenEnvironmentTests gains it), drop `@testable import OpenBurnBarCore`.
- Kernel-family hits (CLIAuthDiscovery, CLILaunchAdapterExecutableResolution,
  CLILaunchCoordinatorAndRedactor already @testable-import OpenBurnBarKernel and/or
  OpenBurnBarKernelModels; SwitcherCLIPostLaunchFallback has KernelModels 4): keep those
  imports — the B0 target already depends on OpenBurnBarKernel; add a direct
  "OpenBurnBarKernelModels" dep if `@testable import OpenBurnBarKernelModels` is retained
  (a per-module @testable needs the module as a DIRECT target dependency).
- CLILaunchCoordinatorAndRedactorTests: KernelPlatform(1) (CLILaunchRedactor lives in
  Platform) — plain `import OpenBurnBarKernelPlatform` if the umbrella import is dropped.

## Package.swift seam edits
`openBurnBarCoreTestExcludes`: REMOVE `SwitcherCLIPostLaunchFallbackTests.swift` (the target
itself is Apple-pruned now).

## Fixtures
None referenced (verify with a `Bundle.module` grep at move time).

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list
(off-Apple builds must never see this target).
