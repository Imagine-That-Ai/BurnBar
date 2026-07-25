# Packet B7: move LaunchServices-owned tests → OpenBurnBarLaunchServicesTests (7 files)
STATE: DONE  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
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

## DONE receipt
All 7 files `git mv`'d into `OpenBurnBarCore/Tests/OpenBurnBarLaunchServicesTests/`
(git rename similarity 94–99%, bodies unchanged) and PlaceholderTests.swift deleted.
Import rewrites (compiler-decided via `swift build --build-tests`, Apple, 0 errors):
- `@testable import OpenBurnBarCore` dropped from all 7.
- AppCheckDebugTokenEnvironmentTests: gained `@testable import OpenBurnBarLaunchServices`
  (only touches `AppCheckDebugTokenEnvironment`, LaunchServices).
- CLILaunchInvokerTests / ChromeProfileDiscoveryTests: already `@testable`-imported
  LaunchServices — dropped the redundant Core import only.
- CLIAuthDiscoveryTests + CLILaunchAdapterExecutableResolutionTests: keep `@testable import
  OpenBurnBarKernel` + `@testable import OpenBurnBarKernelModels` (reach CLILaunchAdapter's
  INTERNAL seams environmentProvider/homeDirectoryProvider/etc.) + LaunchServices.
- CLILaunchCoordinatorAndRedactorTests: dropped the `@testable import OpenBurnBarKernel`
  umbrella for a plain `import OpenBurnBarKernelPlatform` (public CLILaunchRedactor.
  redactEnvironment lives there); kept `@testable import OpenBurnBarLaunchServices`
  (public actor CLILaunchCoordinator).
- SwitcherCLIPostLaunchFallbackTests: added plain `import OpenBurnBarKernelModels`
  (public SwitcherProfileRecord/SwitcherCLIProfileMetadata/SwitcherCLIProfileType +
  the public CLILaunchAdapter.executableResolver seam); kept `@testable import
  OpenBurnBarLaunchServices`.
Package.swift: OpenBurnBarLaunchServicesTests gained DIRECT deps `OpenBurnBarKernelModels`
+ `OpenBurnBarKernelPlatform` (per-module @testable/import needs the sub-target directly);
`openBurnBarCoreTestExcludes` no longer lists SwitcherCLIPostLaunchFallbackTests.swift
(carried out; the Apple-pruned test target is never compiled off-Apple, so no seam needed).
No fixtures (Bundle.module grep = none). Whole-package `swift test list` (Apple): 2048
cases after vs 2049 before — 31 methods conserved 1:1, delta exactly -1 (the removed B0
`testScaffoldTargetIsWired`). coretests-file baseline intentionally NOT --updated here
(integrator ratchets budgets/coretests-file-baseline.json once at chain end; the shrink-only
gate passes non-fatally).
