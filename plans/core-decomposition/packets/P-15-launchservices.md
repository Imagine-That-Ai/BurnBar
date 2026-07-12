# Packet P-15 (DRAFT): move launch/discovery services → OpenBurnBarLaunchServices
STATE: QUEUED
LANE: A          DEPENDS-ON: S0, P-04a/P-04b (SharedModels in Kernel)
BASELINE-TOUCHING: core-ui-purity (AppKit files leave Core)

Apple-only target. Candidate files: `SwitcherCLILAunchService.swift`,
`SwitcherBrowserLaunchService.swift`, `SwitcherProfile.swift`, `BrowserLaunchAdapter.swift`,
`ChromeProfileDiscovery.swift`, `CLIAuthDiscovery.swift`, `CLITerminalSessionSupervisor.swift`,
`AppCheckDebugTokenEnvironment.swift`.

## DAEMON PRE-FLIGHT (VERIFIED AT S0 — divert these two)
`git grep -nl "SwitcherProfile\|CLIAuthDiscovery" OpenBurnBarDaemon/Sources` HITS:
  - `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/OpenBurnBarSwitcherShellLinux.swift`
  - `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift`
  - `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift`
The daemon (cross-platform, links the Engine — NOT UI) consumes `SwitcherProfile` and
`CLIAuthDiscovery`. LaunchServices is Apple-only, so the daemon cannot link it on Linux.
THEREFORE: `SwitcherProfile.swift` and `CLIAuthDiscovery.swift` DIVERT to
`OpenBurnBarKernel` (cross-platform) instead of LaunchServices. The remaining 6 files
(the actual Apple launchers/adapters) go to OpenBurnBarLaunchServices. Re-verify the
daemon does NOT also need `SwitcherCLILAunchService`/`BrowserLaunchAdapter` etc. at
execution — if it does, those divert to Kernel too. This is recorded in the S0
deviations.

## Scope (TO-ENUMERATE-AT-WAVE)
### git mv list
- To Kernel: `SwitcherProfile.swift`, `CLIAuthDiscovery.swift`.
- To LaunchServices: `SwitcherCLILAunchService.swift`, `SwitcherBrowserLaunchService.swift`,
  `BrowserLaunchAdapter.swift`, `ChromeProfileDiscovery.swift`,
  `CLITerminalSessionSupervisor.swift`, `AppCheckDebugTokenEnvironment.swift`.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE from `openBurnBarCoreExcludes`:
  `"CLITerminalSessionSupervisor.swift"`, `"BrowserLaunchAdapter.swift"`,
  `"ChromeProfileDiscovery.swift"`, `"AppCheckDebugTokenEnvironment.swift"`,
  `"SwitcherBrowserLaunchService.swift"` (the LaunchServices target is Apple-pruned).
  `SwitcherProfile`/`CLIAuthDiscovery` go to Kernel and must compile off-Apple (they
  are not in excludes today — confirm).
- `budgets/core-ui-purity-baseline.json` — `--update` (any AppKit launcher leaving Core).

## Validation
V1–V11; ui-purity `--update`; V-linux boundary (daemon must still see SwitcherProfile/
CLIAuthDiscovery from Kernel). Daemon build (V5) is load-bearing here. Not a CANON
packet. Title: "P-15: move launch/discovery services into OpenBurnBarLaunchServices
(SwitcherProfile+CLIAuthDiscovery diverted to Kernel for the daemon)". A1–A6;
BASELINE-TOUCHING core-ui-purity.
