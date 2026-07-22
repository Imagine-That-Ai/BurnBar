# Packet P-21: move LinuxLocalPeerDiscovery → OpenBurnBarKernel/Platform
STATE: PR-OPEN (core-decomp/p-21, base core-decomp/wave4-base)
LANE: Integrator          DEPENDS-ON: wave4-base (whole-program integration; Kernel populated)
BASELINE-TOUCHING: core-target-membership (main-target shrink, non-fatal)

Post-program follow-up (a) from `docs/CORE_DECOMPOSITION_PROGRAM.md` § REMAINING WORK:
`LinuxLocalPeerDiscovery.swift` (632 LOC) is the one residual Core main-target file no
move packet claimed — Linux mDNS / Avahi local-peer discovery + IoT device adapters
(PixelClock, Cast, Home Assistant, SmartHub). It is a **Kernel candidate**:
Foundation-only, zero UI, and consumed only through the `import OpenBurnBarCore`
umbrella. This packet homes it in `OpenBurnBarKernel/Platform/` next to
`OpenBurnBarLinuxPaths.swift` / `PlatformSupport.swift`, dropping the Core main-target
residual from 16 → 15 files.

## RECON (verified in the wave4-base worktree, 2026-07-13)
- **Imports**: `LinuxLocalPeerDiscovery.swift` imports ONLY `Foundation` (verified
  `grep -c '^import'` = 1). It references ZERO OpenBurnBarCore-main / decomposition-target
  symbol — every type it uses (`Date`, `DateInterval`, `UUID`, `JSONSerialization`, string
  primitives) is Foundation. No `import OpenBurnBarCore`. Compile-closure-safe for Kernel
  (Kernel = Foundation + swift-crypto-off-Apple + FirestoreModels; this file needs none of
  the crypto/FirestoreModels surface).
- **UI purity**: zero `import SwiftUI` / `import AppKit` / `import UIKit` (verified). Kernel
  is assert-zero-UI; this file keeps it clean.
- **Symbol collision**: Kernel defines none of `BurnBarLocalPeerMetadata` /
  `BurnBarAvahi*` / `BurnBarPixelClockLinuxAdapter` / `BurnBarLinuxIoTAdapterSuite` /
  `BurnBarDiscoveredService` / `BurnBarLinuxParityStatus` (grep = NO COLLISION).
- **Consumers (repo-wide)**: the ONLY reference to these types outside the def file is the
  Core test `Tests/OpenBurnBarLinuxCoreFoundationTests/LinuxLocalPeerDiscoveryTests.swift`
  (`@testable import OpenBurnBarCore`). The daemon/AgentLens carry ZERO references today
  (`grep -rln … OpenBurnBarDaemon/Sources AgentLens` = empty), so the file is genuinely
  orphaned. All the moved types are `public`; after the move, `@testable import
  OpenBurnBarCore` still resolves them because `KernelReexport.swift` does `@_exported
  import OpenBurnBarKernel` — the umbrella re-export is automatic. NO test-target dep edit
  and NO new re-export shim needed (the existing KernelReexport covers it).

## Scope (ENUMERATED)
### git mv list
- `OpenBurnBarCore/Sources/OpenBurnBarCore/LinuxLocalPeerDiscovery.swift`
  → `OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/LinuxLocalPeerDiscovery.swift`

### Allowed edit files (CONVERGED)
- **AE-IMPORT**: none. The file is Foundation-only; it gains NO `import` (Kernel already
  links Foundation). It is NOT re-diverted and it never imports OpenBurnBarCore.
- **Package.swift**: none. `LinuxLocalPeerDiscovery.swift` was NOT in
  `openBurnBarCoreExcludes` (it compiled off-Apple in Core — Foundation-only), and Kernel
  is not file-pruned off-Apple, so no exclude-array edit is required on either side. The
  file compiles on every host inside Kernel exactly as it did inside Core.
- **AE-TESTABLE**: none. `LinuxLocalPeerDiscoveryTests.swift` touches only PUBLIC members
  of the moved types (all `public struct`/`public enum`), which flow through Core's
  `@_exported import OpenBurnBarKernel`. `@testable import OpenBurnBarCore` keeps resolving
  them — no `@testable import OpenBurnBarKernel` added, no test-target dependency edit.
- **budgets/core-target-membership-baseline.json**: NOT updated in this packet. The main-
  target shrink (16 → 15 files, −632 LOC) is a NON-FATAL "Improved:" shrink in the gate;
  ratcheting the floor down is reserved for the close-out (wave4-final, STEP 3). Leaving
  the baseline alone here keeps this packet a pure `git mv` and lets the close-out capture
  the final floor in one authoritative `--update`.

## Validation (RESULTS, macOS host — Apple Swift 6.4 / Xcode 27 beta, arch arm64)
Compile-closure — build Kernel, Core, Engine, daemon (the daemon build + umbrella
re-export is the consumption proof). Full Signal graph present (Vendor xcframeworks +
libsignal submodule materialized), so this is the CI-equivalent product build:
- `swift build --target OpenBurnBarKernel` → **Build complete! (11.71s)** — exit 0
- `swift build --target OpenBurnBarCore` → **Build complete! (10.51s)** — exit 0
- `swift build --target OpenBurnBarEngine` → **Build complete! (0.97s)** — exit 0
- `swift build --target OpenBurnBarCoreCAbi` → **Build complete! (1.05s)** — exit 0
- `cd ../OpenBurnBarDaemon && swift build` → **Build complete!** — exit 0 (daemon links the
  Engine + Core products; `LinuxLocalPeerDiscoveryTests` and any consumer resolve the moved
  public types via Core's `@_exported import OpenBurnBarKernel`)
- `scripts/debt/check-engine-closure-ui-purity.sh` → **OK: Engine closure = 9 targets, zero
  SwiftUI/AppKit, no UI target reachable** (Engine already depends on Kernel; adding a
  Foundation-only file to Kernel keeps the closure UI-free).
- `scripts/debt/check-core-target-membership-budget.sh` → **OK** — main shrink non-fatal
  (baselined 16 files/1610 lines → live 15 files/978 lines); no sibling over ceiling
  (Kernel PLANNED ceiling 185 files/46250 LOC has ample headroom for +1 file/+632 LOC).
- `node tools/ipc/generate-burnbarrpc-canon.mjs --check` → **exit 0** (no wire drift; the
  move touches no RPC canon).
Not a CANON packet. Title: "P-21: move LinuxLocalPeerDiscovery into OpenBurnBarKernel
(Foundation-only Linux mDNS/peer discovery; Core main-target residual 16 → 15 files)".
A1–A6; BASELINE-TOUCHING core-target-membership (shrink, non-fatal).
