# Packet P-11 (DONE): MissionGroupContracts + MissionConsoleTypes inversion → Kernel
STATE: DONE
LANE: A          DEPENDS-ON: S0, P-04a/P-04b (CloudVaultCrypto in Kernel)
BASELINE-TOUCHING: core-ui-purity

The one real inversion in the program. `MissionConsoleTypes.swift` (in
`Views/MissionControl/`) had a VESTIGIAL `import SwiftUI` (uses ZERO SwiftUI symbols —
all `Sendable` data; verified: 0 hits for Color/Font/Image/Gradient/View outside
comments). The file moved to Kernel whole; then `MissionGroupContracts.swift` (which
needs `MissionConsoleForecast` from it + `CloudVaultCrypto`, both now in Kernel) also
moved to Kernel and its Linux exclusion dropped.

CONVERGENCE NOTE (execution reality): the file was NOT split. The `import SwiftUI` was
truly vestigial for *SwiftUI render* symbols, but the file's `MissionConsoleHost`
protocol requires `Observable` (from the `Observation` framework, NOT SwiftUI) and is
`@MainActor`. `Observation` is already imported UNGUARDED by two existing Kernel files
(`AssistantPendingPrompt.swift`, `HermesSquareFeatureFlags.swift`, both `@MainActor
@Observable`), so it compiles off-Apple in Kernel today. The correct minimal edit was
therefore `import SwiftUI` → `import Observation` (a 1-line swap, file moves 99%), NOT
the data/view split fallback — splitting would have created a NEW Core file, which the
core-target-membership deny-gate ("no NEW .swift file in Core") forbids. Keeping the
host protocol in Kernel is pure-target-safe: the ui-purity gate matches only
`SwiftUI|AppKit` imports, so `import Observation` does not taint Kernel.

## Scope (TO-ENUMERATE-AT-WAVE — re-verify vestigial import at execution)
### git mv list
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Views/MissionControl/MissionConsoleTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/MissionConsoleTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/MissionGroupContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/MissionGroupContracts.swift
```

### Enumerated semantic edits (as executed)
- `MissionConsoleTypes.swift` (in its NEW Kernel location): swapped `import SwiftUI` →
  `import Observation`. RE-VERIFIED at execution: zero `Color/Font/Image/Gradient/View`
  outside comments (the only `View` hit was a doc-comment mentioning
  `MissionControlConsoleView`). The `Observation` import is required by the
  `MissionConsoleHost` protocol's `Observable` conformance (already an unguarded Kernel
  import elsewhere — off-Apple-safe). No split needed; whole file moved.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE `"Contracts/MissionGroupContracts.swift"`
  from `openBurnBarCoreExcludes` (its off-Apple exclusion existed because it referenced
  `MissionConsoleForecast` in Views; that dependency is now inside Kernel, so it
  compiles off-Apple). Delete the associated comment lines.
- `budgets/core-ui-purity-baseline.json` — `--update` (MissionConsoleTypes leaves the
  UI-import set; note it must NOT be in the baseline AFTER its import is deleted).
- **AE-IMPORT / AE-TESTABLE**: NONE required. Both moved files' external deps
  (`CloudVaultCrypto`, `HermesSkillRunID`, `SkillRunDeliveryMode`, `AgentProvider`,
  `MissionConsoleForecast`) already live in the same `OpenBurnBarKernel` target, so no
  cross-target import was needed. `MissionConsoleForecastTests`/`MissionConsoleKindTests`
  (in `OpenBurnBarCoreTests`) reach the moved symbols through Core's `@_exported import
  OpenBurnBarKernel` under their existing `@testable import OpenBurnBarCore` — all moved
  symbols are `public`, so no `@testable import OpenBurnBarKernel` was necessary; the
  test target built (1607 modules, "Build complete!") and the suites pass on macOS.

## CANON CAUTION
`MissionGroupContracts.swift` moves INTO `OpenBurnBarKernel/Contracts/`. The canon
generator reads ONLY `Contracts/BurnBarRPCContracts.swift` +
`BurnBarRPCIPCCanon.generated.swift` — NOT MissionGroupContracts (verified at S0). So
this is NOT a canon packet, but run `node tools/ipc/generate-burnbarrpc-canon.mjs --check`
as V10 to prove zero drift (it must stay green with no regen).

## Validation (as executed — all green)
- V1 Kernel build: `swift build --target OpenBurnBarKernel` — complete.
- V2 Core build: `swift build --target OpenBurnBarCore` — complete.
- V5 daemon/engine: `swift build --target OpenBurnBarEngine` (UI-free umbrella the
  daemon links) — complete. (The daemon executable lives in the separate
  `OpenBurnBarDaemon/` package dir, not a target of this package.)
- V4 test: `swift test --filter MissionConsole` — 17 passed / 0 failures
  (MissionConsoleForecastTests, MissionConsoleKindTests, MissionConsoleFormattingTests,
  MissionConsoleSnapshotTests — all exercise symbols now in Kernel via Core re-export).
  Test target built fully (1607 modules) proving `@testable import OpenBurnBarCore` reach
  survives the move. NOTE: the XCTest classes are `MissionConsole*Tests`, NOT
  `MissionConsoleTests` (a `--filter MissionConsoleTests` matches nothing).
- V6 ui-purity: `--update` (114→113, MissionConsoleTypes removed) then `--check` OK.
- V7 membership gate: OK (non-fatal shrink, no NEW Core file).
- V8 umbrella-imports gate: OK. · V9 mission-splitbrain: OK (11/11, no growth).
- V-filesize gate: OK. · V10 canon `--check`: exit 0, zero drift, no regen (generator
  reads only BurnBarRPCContracts.swift — confirmed at lines 10/13 of the generator).
- V-linux boundary: CI-covered (Kernel already imports `Observation` unguarded and
  builds off-Apple; the file's only deps are Foundation + Observation + Kernel types).
- V11 scope: exactly 4 files — Package.swift, 2 renames, purity baseline. No creep.
