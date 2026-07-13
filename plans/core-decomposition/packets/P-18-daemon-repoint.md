# Packet P-18: repoint OpenBurnBarDaemon/CLI → OpenBurnBarEngine (S17)
STATE: EXECUTED (PR_OPEN — base core-decomp/p-13-final)
LANE: Integrator          DEPENDS-ON: S0, P-13 (Quota populated), P-15b (CLILaunchAdapter Kernel-resident)
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarDaemon/ to ZERO — flipped in this PR)

THE SECURITY PAYOFF: the daemon + CLI stop linking the SwiftUI/AppKit `OpenBurnBarCore`
umbrella and link the UI-free `OpenBurnBarEngine` umbrella instead, so the most-privileged
binaries gain NO transitive path to the presentation layer. Proven: Engine transitive
closure = 9 targets, zero SwiftUI/AppKit, no UI target reachable.

## Executed on base core-decomp/p-13-final (better than the prior wave3-base attempt)
The prior attempt's ONLY hard blocker (the CLI-launch cluster) is resolved on this base:
P-15b homed `CLILaunchAdapter`/`CLILaunchError` in `OpenBurnBarKernel/Platform/`, and the
P-13 Quota move already homed `XAISuperGrokPacingLog` in `OpenBurnBarQuota` (an Engine leaf),
so — unlike the wave3-base attempt — NO `XAISuperGrokPacingLog→Hermes` move was needed here.

### Mechanical repoint (compile-verified)
- `OpenBurnBarDaemon/Package.swift`: `OpenBurnBarCore` product dep → `OpenBurnBarEngine`
  on the **daemon target** AND the **OpenBurnBarDaemonLinuxGatewayTests** test target.
  ComputerUseCore / IrohRelay / Media / LinuxSecurity kept as-is (K2 privileged closure);
  RemoteAccessAgentCore keeps its explicit `OpenBurnBarKernel` dep (K2, untouched).
- `s/^import OpenBurnBarCore$/import OpenBurnBarEngine/` across **202** daemon Sources+Tests
  files (134 Sources + 68 Tests). Zero residual `import OpenBurnBarCore` in any attribute form.
- `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarVectorKit` in
  `BurnBarIndexedSearchServiceMinimalTests` (its only reached Core symbol,
  `BurnBarSemanticSearchConfig`, is public in VectorKit — an Engine leaf).
- `OpenBurnBarCore.Locked(0)` → `OpenBurnBarEngine.Locked(0)` in
  `ComputerUseCapabilityStateIntegrationTests.swift:378` (the one module-QUALIFIED Core
  reference the sed missed; `Locked` is a Kernel type re-exported by Engine — compiler-caught).

### Residual Core-only symbols resolved by layer-appropriate moves (compile-closure)
A robust public-TYPE map of the 5 non-Engine, non-daemon-linked targets {Core-main, UI,
Insights, LaunchServices, TextExpansion} intersected against the daemon Sources+Tests blob
yields EXACTLY 4 real top-level breakers (all in `OpenBurnBarLaunchServices`, all pure,
all referenced ONLY by the macOS-only `OpenBurnBarSwitcherShell.swift` + its test); the
~20 other name-collisions are nested types (`InsightWidgetData.Row`, `NestHubMiniPreview.Provider`, …).
`InsightMissionApprovalPolicy` is confirmed NOT daemon-referenced. The 4:

| Symbol | Was in (LaunchServices) | Moved DOWN to (Kernel) | Gate |
|---|---|---|---|
| `CLITerminalSessionSupervisor` + `CLIQuotaExhaustionClassifier` + `CLITerminalSessionOutputSource`/`Event`/`PipeObserver` | `CLITerminalSessionSupervisor.swift` (whole file) | `Kernel/Platform/CLITerminalSessionSupervisor.swift` (`git mv`) | `#if canImport(Darwin)` (was ungated in whole-off-Apple-pruned LaunchServices → compiled on all Apple platforms; guard preserves that exact surface) |
| `CLILaunchRedactor` | `SwitcherCLILAunchService.swift` | `Kernel/Platform/CLILaunchRedactor.swift` (new) | `#if os(macOS)` (source was wholly `#if os(macOS)`) |
| `SwitcherProfileStoreAdapter` + `InMemorySwitcherProfileStoreAdapter` | `SwitcherBrowserLaunchService.swift` | `Kernel/SwitcherProfileStoreAdapter.swift` (new) | `#if os(macOS)` (source was wholly `#if os(macOS)`) |

All three moves are pure code motion (only Kernel types `SwitcherCLIProfileType`/`ProviderID`/
`Locked`/`SwitcherProfileRecord` + Foundation), zero behavior change. Core still sees them via
`@_exported import OpenBurnBarKernel`; the daemon reaches them via Engine→Kernel; LaunchServices
reaches them via its declared Kernel dep. The stale P-15b comment ("CLILaunchRedactor STAYS")
is corrected. `import OpenBurnBarKernel` dropped from the moved supervisor file (self-import).

### Ratchet flip (owned by this PR)
`budgets/core-umbrella-imports-baseline.json` `--update`: OpenBurnBarDaemon 203 → **0**;
total 1120 → 917. Also imports the P-17 `scripts/debt/check-engine-closure-ui-purity.sh`
(reused as the link-graph proof; Core doesn't compile Engine so the Windows-lane gate needs it).

## Validation (all local, this base)
- `swift build --target OpenBurnBarDaemon` + full `swift build` (daemon + CLI): **Build complete, exit 0.**
- Kernel / Engine / LaunchServices targets build green after the moves.
- Daemon `swift test`: both test bundles COMPILE (106MB + 92MB xctest built);
  `OpenBurnBarDaemonLinuxGatewayTests` + `OpenBurnBarRemoteAccessAgentCoreTests` PASS; the
  main `OpenBurnBarDaemonTests` non-DB tests PASS. The ONLY failures are SQLCipher-codec DB
  tests (`code=26 file is not a database` / `code=7 out of memory` in
  BurnBarIndexedSearchServiceTests / BurnBarProjectCodeMemoryStoreTests) — a **documented
  local-harness limitation** (docs/RUNBOOK.md:161: custom local builds substituting the
  ad-hoc `cp -R`'d SQLCipher.framework can't open the encrypted DB), reproduces in single-test
  isolation on a clean rebuild, and the SUT + test files have **import-only diffs** (zero DB
  logic change). CI daemon-pr-gate (macos-26) runs them green.
- LINK-GRAPH PROOF: `scripts/debt/check-engine-closure-ui-purity.sh` → "Engine closure = 9
  target(s), zero SwiftUI/AppKit, no UI target reachable." Daemon has zero `import OpenBurnBarCore`.
- `check-core-umbrella-imports-budget.sh` → daemon = 0. `check-core-target-membership-budget.sh`,
  `check-core-ui-purity-budget.sh` → OK (Kernel +3 files within ceiling, UI-free).
- canon `--check` (`node tools/ipc/generate-burnbarrpc-canon.mjs --check`) → clean (no wire-name change).
- Linux daemon build: CI-covered by linux-pr-gate.yml (triggers on OpenBurnBarDaemon/**);
  Linux-boundary manifest build (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1`) run on macOS host.
