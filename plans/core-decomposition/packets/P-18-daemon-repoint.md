# Packet P-18 (DRAFT): repoint OpenBurnBarDaemon/CLI → OpenBurnBarEngine (S17)
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0, P-17 (Engine complete)
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarDaemon/ to zero)

The security payoff: the daemon/CLI stop linking the OpenBurnBarCore umbrella (and its
transitive UI) and link the UI-free `OpenBurnBarEngine` instead.

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
