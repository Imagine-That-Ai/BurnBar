# Packet P-18: repoint OpenBurnBarDaemon/CLI → OpenBurnBarEngine (S17)
STATE: BLOCKED (named blocker: CLI-launch machinery trapped in Apple-only OpenBurnBarLaunchServices)
LANE: Integrator          DEPENDS-ON: S0, P-17 (Engine complete — DONE), **NEW: CLI-launch extraction packet**
BASELINE-TOUCHING: core-umbrella-imports (ratchets OpenBurnBarDaemon/ to zero)

The security payoff: the daemon/CLI stop linking the OpenBurnBarCore umbrella (and its
transitive UI) and link the UI-free `OpenBurnBarEngine` instead.

## BLOCKER (compile-closure, 2026-07-13)
The mechanical repoint is trivial and was fully performed on a WIP branch
(preserved: `git stash` "P-18 WIP" on core-decomp/p-18-w3):
- `OpenBurnBarDaemon/Package.swift`: `OpenBurnBarCore` product dep → `OpenBurnBarEngine`
  (daemon target + LinuxGateway test target; ComputerUseCore/IrohRelay/Media/
  LinuxSecurity kept as-is).
- `s/^import OpenBurnBarCore$/import OpenBurnBarEngine/` across **202** daemon
  Sources+Tests files (clean, zero residue).
- The one `@testable import OpenBurnBarCore` (BurnBarIndexedSearchServiceMinimalTests)
  → `@testable import OpenBurnBarVectorKit` (its only reached symbol
  `BurnBarSemanticSearchConfig` is public in VectorKit, an Engine leaf).

Two Core-only symbols were resolved in-slice by layer-appropriate moves (both
Foundation-pure, both verified by rebuild):
1. `XAISuperGrokPacingLog` (used by `OpenBurnBarHTTPGatewayServer+UsageLogging.swift`)
   → `git mv` into **OpenBurnBarHermes**. Core still sees it (Core re-exports Hermes
   via OpenBurnBarHermesReexport.swift); daemon gets it via Engine.
2. `SwitcherProfileStoreAdapter` + `InMemorySwitcherProfileStoreAdapter` (the pure
   profile-store protocol, trapped inside the AppKit-importing
   `LaunchServices/SwitcherBrowserLaunchService.swift`) → new
   **OpenBurnBarKernel/SwitcherProfileStoreAdapter.swift**. Only uses Kernel types
   (`SwitcherProfileRecord`, `ProviderID`, `Locked`).

### The hard blocker: the CLI-launch cluster
The daemon's supervised-CLI shell (`OpenBurnBarSwitcherShell.swift` + its test — **2
daemon files only**) needs **4 symbols** that live ONLY in the Apple-only, AppKit-
importing `OpenBurnBarLaunchServices` target, which `OpenBurnBarEngine` does NOT (and
must not) re-export:

| Symbol | Owning file (LaunchServices) | Purity |
|---|---|---|
| `CLITerminalSessionSupervisor` | `CLITerminalSessionSupervisor.swift` (339 LOC) | pure (Foundation + Kernel, **no AppKit**) |
| `CLIQuotaExhaustionClassifier` | `CLITerminalSessionSupervisor.swift` | pure |
| `CLILaunchAdapter` | `SwitcherCLILAunchService.swift` (1803 LOC) | pure logic; file has a **dead** `import AppKit` (0 AppKit symbols used) but is `#if os(macOS)`-gated |
| `CLILaunchRedactor` | `SwitcherCLILAunchService.swift` | pure |

Complete inventory proof: a robust public-symbol map of {Core-main + LaunchServices +
TextExpansion + Insights} (500 non-Engine public symbols) intersected word-boundary
against the whole daemon Sources+Tests blob yields EXACTLY these 4 real hits (plus 4
false positives — `Result`/`Verdict`/`classify`/`probe`, which are generic identifiers
/ nested members of the daemon-unreferenced `AnthropicCredentialProbe`; the daemon
never references `AnthropicCredentialProbe`). Zero TextExpansion, zero Insights, and —
contrary to the card's original guess — **`InsightMissionApprovalPolicy` is NOT
referenced by the daemon at all**, so no Apple-only Insights daemon dependency is
needed.

### Why this is a STOP, not a force-through
- Linking `OpenBurnBarLaunchServices` as an Apple-only daemon dependency (the escape
  hatch the card suggested for Insights) is **wrong here**: LaunchServices imports
  AppKit in 4 files (`SwitcherBrowserLaunchService`, `BrowserLaunchAdapter`,
  `ChromeProfileDiscovery`, and the dead one). That pulls AppKit into the most-
  privileged binary on macOS — **destroying P-18's "no path to UI" goal**.
- Relocating the cluster to Kernel/an Engine leaf is the correct permanent fix, but it
  is a **substantial code move** (2 files, ~2142 LOC; `SwitcherCLILAunchService.swift`
  must be split to respect Kernel's per-file/size budget) that also **reverses P-15's
  explicit documented decision** (P-15 card "resolution-machinery STOP": it deliberately
  homed this security-sensitive PATH-resolution machinery in LaunchServices, assuming
  the daemon keeps linking Core's `@_exported` re-exports). P-15's divert-proof only
  works while the daemon links Core — the exact thing P-18 removes.
- Prior corroboration: an earlier P-13 attempt hit the identical edge (preserved stash:
  "CLILaunchAdapter/SwitcherCLIProfileType(Core) ... cross-layer edges").

### UNBLOCK PLAN (new predecessor packet, ~P-15b/P-19)
Extract the pure CLI-launch machinery into an engine-layer target so the daemon reaches
it UI-free:
1. Create `OpenBurnBarCLILaunch` (or fold into Hermes/a new leaf), depending only on
   OpenBurnBarKernel; add it to the Engine umbrella (`@_exported import`) + as an Engine
   manifest dependency.
2. `git mv CLITerminalSessionSupervisor.swift` there wholesale (already pure).
3. Split `SwitcherCLILAunchService.swift`: move `CLILaunchAdapter`, `CLILaunchRedactor`
   (and their pure collaborators `CLILaunchError`/`CLILaunchInvoker`/`CLILaunchCoordinator`
   /`CLIFallback*`/`CLILaunchServiceEvent`/`CLILaunchOutcome` as the closure requires)
   into the new target; drop the dead `import AppKit`; keep the AppKit browser-launch
   pieces (`SwitcherBrowserLaunchService`, `BrowserLaunchAdapter`, `ChromeProfileDiscovery`)
   in LaunchServices, which then depends on the new leaf for the shared CLI types.
4. Update `budgets/core-target-membership-baseline.json` (files leave LaunchServices;
   new sibling ceiling) and `budgets/core-ui-purity-baseline.json` if a baselined file
   moves.
5. Verify off-Apple Core build has no dangling reference (LaunchServices is pruned whole
   off-Apple; the new leaf must be cross-platform-clean).

Then P-18 becomes purely mechanical (repoint + sed + the 2 already-proven pure moves +
the umbrella-imports ratchet flip). The WIP stash on core-decomp/p-18-w3 holds the
mechanical repoint and both pure moves ready to rebase onto the unblock packet.

## Scope (unchanged, for the eventual mechanical PR)
- `OpenBurnBarDaemon/Package.swift` — Core→Engine product dep (daemon + test targets).
- `s/^import OpenBurnBarCore$/import OpenBurnBarEngine/` daemon Sources+Tests.
- `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarVectorKit` (1 file).
- `budgets/core-umbrella-imports-baseline.json` `--update` (OpenBurnBarDaemon/ → zero).

## Validation (to run once unblocked)
- Full daemon `swift build` + `swift test`.
- Linux cross-compile (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1`) + daemon Linux build.
- Link-graph proof: OpenBurnBarUI/AppKit NOT in the daemon's transitive link closure.
- `check-core-umbrella-imports-budget.sh` shows OpenBurnBarDaemon/ = 0.
