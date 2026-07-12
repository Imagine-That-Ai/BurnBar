# Packet P-11 (DRAFT): MissionGroupContracts + MissionConsoleTypes inversion → Kernel
STATE: QUEUED
LANE: A          DEPENDS-ON: S0, P-04a/P-04b (CloudVaultCrypto in Kernel)
BASELINE-TOUCHING: core-ui-purity

The one real inversion in the program. `MissionConsoleTypes.swift` (in
`Views/MissionControl/`) has a VESTIGIAL `import SwiftUI` (uses ZERO SwiftUI symbols —
all `Sendable` data; verified: 0 hits for Color/Font/Image/Gradient). Delete that one
import and move the file to Kernel; then `MissionGroupContracts.swift` (which needs
`MissionConsoleForecast` from it) also moves to Kernel and its Linux exclusion drops.

## Scope (TO-ENUMERATE-AT-WAVE — re-verify vestigial import at execution)
### git mv list
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Views/MissionControl/MissionConsoleTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/MissionConsoleTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/MissionGroupContracts.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/MissionGroupContracts.swift
```

### Enumerated semantic edits
- `MissionConsoleTypes.swift` (in its NEW Kernel location): DELETE the single
  `import SwiftUI` line. RE-VERIFY at execution: `grep -nE 'Color|Font|Image|Gradient|View\b' MissionConsoleTypes.swift` must be EMPTY before deleting the import. If it uses ANY SwiftUI symbol, STOP — split the file at the data/view boundary (fallback in the plan) and report.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE `"Contracts/MissionGroupContracts.swift"`
  from `openBurnBarCoreExcludes` (its off-Apple exclusion existed because it referenced
  `MissionConsoleForecast` in Views; that dependency is now inside Kernel, so it
  compiles off-Apple). Delete the associated comment lines.
- `budgets/core-ui-purity-baseline.json` — `--update` (MissionConsoleTypes leaves the
  UI-import set; note it must NOT be in the baseline AFTER its import is deleted).
- **AE-IMPORT / AE-TESTABLE** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): add
  `import OpenBurnBarKernel` (or another Kernel-declared dep) to a moved file only if
  the Kernel build (V1) demands it; never `import OpenBurnBarCore`. Add `@testable
  import OpenBurnBarKernel` beneath the existing `@testable import OpenBurnBarCore` in
  any Core test reaching an INTERNAL moved symbol (anticipated: MissionGroupContracts /
  MissionConsoleTypes tests). Enumerate every added line/file in the PR body.

## CANON CAUTION
`MissionGroupContracts.swift` moves INTO `OpenBurnBarKernel/Contracts/`. The canon
generator reads ONLY `Contracts/BurnBarRPCContracts.swift` +
`BurnBarRPCIPCCanon.generated.swift` — NOT MissionGroupContracts (verified at S0). So
this is NOT a canon packet, but run `node tools/ipc/generate-burnbarrpc-canon.mjs --check`
as V10 to prove zero drift (it must stay green with no regen).

## Validation
V1 Kernel build · V2 Core build · V3 (omit — mixed lane; MissionConsoleTypes is pure
after the import delete, MissionGroupContracts is Foundation) · V4 test · V5 daemon ·
V6 ui-purity `--update` then check · V10 canon `--check` (green) · V-linux boundary ·
V11 scope. A1–A6; BASELINE-TOUCHING core-ui-purity.
