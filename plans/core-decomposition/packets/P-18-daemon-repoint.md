# Packet P-18: repoint OpenBurnBarDaemon/CLI → OpenBurnBarEngine (S17)
STATE: PR_OPEN #1664 (base core-decomp/p-13-final; EXECUTED)
LANE: Integrator          DEPENDS-ON: S0, P-13 (Quota populated), P-15b (CLILaunchAdapter Kernel-resident)
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarDaemon/ to ZERO — flipped in #1664)

The security payoff: the daemon/CLI stop linking the OpenBurnBarCore umbrella (and its
transitive UI) and link the UI-free `OpenBurnBarEngine` instead.

## EXECUTED (PR #1664, base core-decomp/p-13-final)
Shipped: Package.swift Core→Engine (daemon target + LinuxGatewayTests); sed of 202 daemon
Sources+Tests `import OpenBurnBarCore`→`import OpenBurnBarEngine`; `@testable import
OpenBurnBarCore`→`@testable import OpenBurnBarVectorKit` (×1); `OpenBurnBarCore.Locked`→
`OpenBurnBarEngine.Locked` (×1, module-qualified, compiler-caught). Compile-closure found
EXACTLY 4 residual Core-only breakers, all pure, all in LaunchServices, all referenced only
by the macOS-only OpenBurnBarSwitcherShell.swift — moved DOWN into Kernel:
CLITerminalSessionSupervisor.swift (git mv, `#if canImport(Darwin)`), CLILaunchRedactor
(new Kernel/Platform/CLILaunchRedactor.swift, `#if os(macOS)`), SwitcherProfileStoreAdapter+
InMemorySwitcherProfileStoreAdapter (new Kernel/SwitcherProfileStoreAdapter.swift,
`#if os(macOS)`). InsightMissionApprovalPolicy confirmed NOT daemon-referenced. No
XAISuperGrokPacingLog→Hermes move needed (P-13 already homed it in OpenBurnBarQuota, an
Engine leaf) — this base is cleaner than the prior wave3-base attempt. Ratchet flipped:
umbrella baseline OpenBurnBarDaemon 203→0. LINK-GRAPH PROOF: Engine closure = 9 targets,
zero SwiftUI/AppKit, no UI target reachable. Daemon build+CLI green; canon --check clean;
membership/UI-purity gates OK. (The prior "BLOCKED — CLI-launch cluster" note is resolved
by P-15b + this packet's 3 Kernel moves.)

## Scope
- `OpenBurnBarDaemon/Package.swift` — change the daemon's + CLI's product dependency
  from `OpenBurnBarCore` to `OpenBurnBarEngine`. (Keep ComputerUseCore, IrohRelay,
  Media, LinuxSecurity as-is.) On macOS, add `OpenBurnBarInsights` ONLY if M5 needs it —
  else omit.
- Mechanical sed across daemon sources: `s/^import OpenBurnBarCore$/import OpenBurnBarEngine/`
  (203+59 files per the plan). The compiler drives per-file additions (a file that
  needs an Apple-only symbol Engine doesn't re-export must switch to an explicit narrow
  import, or reveals it was UI-coupled — surface it).
- `budgets/core-umbrella-imports-baseline.json` — `--update` (OpenBurnBarDaemon/ ratchets
  to zero). This packet OWNS that ratchet flip.

## Pre-flight
- `git grep -nl "import OpenBurnBarCore" OpenBurnBarDaemon/Sources` → the sed target set.
- Confirm NO daemon file needs a UI/TextExpansion/LaunchServices symbol (those aren't in
  Engine). If one does, it is UI-coupled and must be resolved (STOP/report — likely the
  SwitcherProfile/CLIAuthDiscovery divert from P-15 covers it).

## Validation
- Full daemon test suite.
- Linux cross-compile (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1`) + daemon Linux build.
- Link-graph proof in the PR body: OpenBurnBarUI is NOT in the daemon's transitive link
  closure ("no path to UI").
- `check-core-umbrella-imports-budget.sh` shows OpenBurnBarDaemon/ = 0 after the ratchet.
Title: "P-18: repoint daemon/CLI onto OpenBurnBarEngine (no path to UI)". A1–A6;
BASELINE-TOUCHING core-umbrella-imports.
