# Packet P-15: move launch/discovery services → OpenBurnBarLaunchServices
STATE: PR-OPEN (core-decomp/p-15-w2, base core-decomp/p-11-w2)
LANE: A          DEPENDS-ON: S0, P-04a/P-04b (SharedModels in Kernel)
BASELINE-TOUCHING: core-ui-purity (AppKit files leave Core)

## WAVE DEVIATION (compile-closure, 2026-07-12)
Only `SwitcherProfile.swift` DIVERTS to `OpenBurnBarKernel/SharedModels/` — a
machine re-grep proved the daemon references `SwitcherProfileRecord`/
`SwitcherCLIProfileType` (SwitcherProfile.swift) in all three daemon files, but
NOWHERE references `CLIAuthDiscovery`/`CLIAuthInfo`/`CLIAuthState`
(`git grep -n "CLIAuthDiscovery\|CLIAuthInfo\|CLIAuthState" OpenBurnBarDaemon/Sources`
= empty). The card's original alternation-grep counted `CLIAuthDiscovery` as a
daemon dep by OR-matching lines that only contained `SwitcherProfile`.
Therefore `CLIAuthDiscovery.swift` goes to **OpenBurnBarLaunchServices**, NOT
Kernel: its macOS `#else` branch calls `CLILaunchAdapter.executablePath(for:)`
(a `#if os(macOS)` + AppKit-importing enum in `SwitcherCLILAunchService.swift`,
now in LaunchServices), so homing it in the cross-platform Kernel would invert
layering AND drag the security-sensitive PATH-resolution machinery into a pure
target (a resolution-machinery STOP). LaunchServices is Apple-pruned whole
off-Apple, so `CLIAuthDiscovery` simply does not exist off-Apple — fine, since no
off-Apple consumer (daemon) uses it. Divert-proof: the daemon builds on macOS
(CLITerminalSessionSupervisor + SwitcherProfileRecord resolve via Core's
`@_exported` re-exports of LaunchServices + Kernel); Linux boundary is CI-covered
(SwitcherProfile in Kernel is re-exported unconditionally by Core's
KernelReexport.swift, so `import OpenBurnBarCore` in the Linux daemon still sees
`SwitcherProfileRecord`).

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

## Scope (ENUMERATED + CONVERGED)
### git mv list
- To Kernel (`OpenBurnBarKernel/SharedModels/`): `SwitcherProfile.swift` (daemon-referenced).
- To LaunchServices: `SwitcherCLILAunchService.swift`, `SwitcherBrowserLaunchService.swift`,
  `BrowserLaunchAdapter.swift`, `ChromeProfileDiscovery.swift`,
  `CLITerminalSessionSupervisor.swift`, `AppCheckDebugTokenEnvironment.swift`,
  `CLIAuthDiscovery.swift` (re-diverted from Kernel — see WAVE DEVIATION).

### Allowed edit files (CONVERGED)
- `OpenBurnBarCore/Package.swift` — DELETED from `openBurnBarCoreExcludes`:
  `"CLITerminalSessionSupervisor.swift"`, `"BrowserLaunchAdapter.swift"`,
  `"ChromeProfileDiscovery.swift"`, `"AppCheckDebugTokenEnvironment.swift"`,
  `"SwitcherBrowserLaunchService.swift"` (the LaunchServices target is Apple-pruned
  whole off-Apple; a P-15 provenance comment replaced the block).
  `SwitcherProfile.swift`/`CLIAuthDiscovery.swift` were NOT in excludes (they compiled
  off-Apple in Core) — confirmed; no exclude-array edit for them. The per-sibling
  `openBurnBarLaunchServicesExcludes`/`openBurnBarKernelExcludes` arrays stay untouched
  (LaunchServices is pruned whole, not file-excluded; Kernel's SwitcherProfile is
  Foundation-only and compiles off-Apple).
- `budgets/core-ui-purity-baseline.json` — `--update`: dropped the 4 AppKit launchers
  (`BrowserLaunchAdapter`, `ChromeProfileDiscovery`, `SwitcherBrowserLaunchService`,
  `SwitcherCLILAunchService`); total 113 → 109. Kernel stays assert-zero (SwitcherProfile
  is Foundation-only).
- **PATH-PIN (learning 5)**: `scripts/ci/verify-migration-rollback-catalog.mjs` +
  `.test.mjs` hard-pin `SwitcherProfile.swift`'s exact path (v46_drain_target_per_provider
  `appExternalDependencies` reads `canonicalAgentProvider` by `readFileSync`). Repointed
  both from `.../OpenBurnBarCore/SwitcherProfile.swift` to
  `.../OpenBurnBarKernel/SharedModels/SwitcherProfile.swift` in the SAME PR; verifier +
  its 12 unit tests pass (fingerprint unchanged — content moved, not edited).
- **AE-IMPORT** (compile-driven): `import OpenBurnBarKernel` added to the 6
  LaunchServices files that reference Kernel symbols (`SwitcherProfileRecord`/
  `SwitcherCLIProfileType`/`SwitcherBrowserProfileType`/`BrowserServiceProvider`/
  `BrowserServiceIdentity`): `SwitcherCLILAunchService.swift`,
  `SwitcherBrowserLaunchService.swift`, `BrowserLaunchAdapter.swift`,
  `ChromeProfileDiscovery.swift`, `CLITerminalSessionSupervisor.swift`,
  `CLIAuthDiscovery.swift`. `AppCheckDebugTokenEnvironment.swift` is Foundation-only —
  NO import added. `SwitcherProfile.swift` (Kernel) is self-contained — NO import added.
  Never `import OpenBurnBarCore`.
- **AE-TESTABLE** (compile-driven): `@testable import OpenBurnBarLaunchServices` added
  beneath `@testable import OpenBurnBarCore` in the 5 Core tests reaching INTERNAL moved
  members: `CLIAuthDiscoveryTests.swift`, `ChromeProfileDiscoveryTests.swift`,
  `CLILaunchAdapterExecutableResolutionTests.swift`, `CLILaunchInvokerTests.swift`,
  `SwitcherCLIPostLaunchFallbackTests.swift`. NO Kernel `@testable` needed (tests touch
  only PUBLIC SwitcherProfile members, which flow via `@_exported`).
  `AppCheckDebugTokenEnvironmentTests.swift` + `CastleStatusTests.swift` compile
  unchanged (public-only access). These tests are Apple-only off-Apple via
  `openBurnBarCoreOffAppleTestSources` (nil on Apple = all; a 2-file allowlist off-Apple),
  matching the TextExpansionTests precedent — no `#if` guard on the import needed.

## Validation (RESULTS, macOS host — Swift 6.4 / Xcode 27 beta)
- swift build --target OpenBurnBarKernel → Build complete
- swift build --target OpenBurnBarLaunchServices → Build complete
- swift build --target OpenBurnBarCore → Build complete
- swift build --target OpenBurnBarEngine → Build complete
- swift build --target OpenBurnBarDaemon (separate pkg) → Build complete (DIVERT-PROOF:
  daemon links Core, resolves CLITerminalSessionSupervisor via LaunchServices re-export +
  SwitcherProfileRecord via Kernel re-export)
- swift build --build-tests + swift test → 316 XCTest + swift-testing suites, 0 failures
- core-ui-purity gate → OK (baselined=109 live=109 after --update; Kernel assert-zero clean)
- core-target-membership gate → OK (main shrink non-fatal; no sibling ceiling exceeded)
- core-umbrella-imports gate → OK (no new umbrella imports)
- mission-splitbrain gate → OK (no Planner drift)
- swift-file-size gate → OK
- verify-migration-rollback-catalog.mjs → OK; .test.mjs → 12/12 pass (path-pin repointed)
- V-linux boundary → CI-covered (no Linux SDK on host; SwitcherProfile in Kernel is
  re-exported unconditionally, daemon Linux leg compiles OpenBurnBarSwitcherShellLinux.swift)
Not a CANON packet. Title: "P-15: move launch/discovery services into
OpenBurnBarLaunchServices (SwitcherProfile diverted to Kernel for the daemon;
CLIAuthDiscovery homed in LaunchServices)". A1–A6; BASELINE-TOUCHING core-ui-purity.
