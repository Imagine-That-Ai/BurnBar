# Packet K1: extract OpenBurnBarKernelPlatform (the leaf)
STATE: DRAFT (scaffold landed in K0; run after K0 merges)
LANE: Kernel-diet  DEPENDS-ON: K0 (scaffold: target + product + marker + umbrella)
BASELINE-TOUCHING: none (membership shrink of Kernel is non-fatal; integrator ratchets)
BASE: origin/main (after K0 merges)

Moves the 12 leaf host/runtime primitives from `OpenBurnBarKernel` into
`OpenBurnBarKernelPlatform` and deletes that target's `ModuleMarker.swift` in the
same commit. Platform is the LEAF (deps: Foundation + swiftCryptoNonAppleDependency
only) — a K0 reference scan proved ZERO Platform-file references to Models/Crypto/
Contracts types, so no AE-IMPORT of a sibling sub-target is expected (all resolve to
Foundation or Platform-internal symbols). The 3 files the task's Platform list
originally named but that reference Models types (`CLILaunchAdapter`,
`CLITerminalSessionSupervisor`, `LinuxSubstrateSupport` → SwitcherProfile/RGBA/
SubstrateFamily) were REASSIGNED to Models (K2) to keep Platform a true leaf — see
K2-models.md.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarDistributedNotifications.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/OpenBurnBarDistributedNotifications.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarIdentifiers.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/OpenBurnBarIdentifiers.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarJSONValue.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/OpenBurnBarJSONValue.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/CLILaunchRedactor.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/Platform/CLILaunchRedactor.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/LinuxLocalPeerDiscovery.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/Platform/LinuxLocalPeerDiscovery.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/OpenBurnBarIdentity.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/Platform/OpenBurnBarIdentity.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/OpenBurnBarLinuxPaths.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/Platform/OpenBurnBarLinuxPaths.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/PlatformSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/Platform/PlatformSupport.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SendableFileSystem.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/SendableFileSystem.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/Formatting.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/SharedModels/Formatting.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/String+Extensions.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/String+Extensions.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/ThreadSafeISO8601DateFormatter.swift OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/ThreadSafeISO8601DateFormatter.swift
git rm OpenBurnBarCore/Sources/OpenBurnBarKernelPlatform/ModuleMarker.swift
```
(15 files listed in K0 mapping minus the 3 reassigned to Models = 12 mv + 1 marker rm.)

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected. Platform's deps
  (`[swiftCryptoNonAppleDependency]`) already declared at K0; no exclude edits
  (nothing is in `openBurnBarKernelPlatformExcludes` — the arrays are empty and
  Platform compiles whole off-Apple).
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): EXPECTED NONE.
  Platform is the leaf; K0 scan found no Platform→sibling refs. If the compiler
  demands `import Foundation`/`import Security` it is already present. If it demands
  an import of Models/Crypto/Contracts → STOP (`BLOCKED(closure)`): a file that
  needs an upstream sibling is misassigned and belongs in that sibling, not Platform.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarKernelPlatform`
  beneath `@testable import OpenBurnBarKernel` in any Core test reaching an INTERNAL
  symbol of a moved file. Anticipated (grep Tests/ for moved type names):
  `CLILaunchRedactorTests`, `PlatformSupportTests` / `PlatformCryptoTests`,
  `LinuxLocalPeerDiscoveryTests`, `OpenBurnBarIdentityTests`, `LinuxPathsTests`,
  `ThreadSafeISO8601DateFormatterTests`, `OpenBurnBarJSONValueTests`. Add ONLY where
  compile fails; enumerate in the PR body.

## Pre-flight path-pin greps (RUN before mv; enumerate hits in PR body)
Run over `.github .swiftlint.yml project.yml CODEOWNERS scripts tools` for every moved
path. K0 enumeration found:
- `.github/CODEOWNERS` — NO Platform-file pins (the only Kernel CODEOWNERS pin is
  CloudVaultCrypto.swift, which is K3). Confirm none of the 12 moved paths appear.
- `tools/`, `scripts/`, `.swiftlint.yml`, `project.yml` — NO pins on the 12 Platform
  paths (canon pins BurnBarRPC* only → K4; bundle pins Resources/ → K2). Re-run to
  confirm zero hits before moving.

## Shim
None. OpenBurnBarKernel's `KernelUmbrella.swift` already `@_exported import`s
OpenBurnBarKernelPlatform (landed K0). Do NOT edit KernelUmbrella.swift.

## Forbidden actions
- No `git reset --hard` / `git checkout --` (reverse-mv + `git stash push -u`).
- No manifest dependency-edge additions (Platform's deps are fixed at K0).
- No file-content edits beyond AE-IMPORT/AE-TESTABLE.
- Never `git worktree remove` with a live Vendor symlink.

## Validation (V-list — all must pass; never PR from a red tree)
```
cd OpenBurnBarCore && swift build
cd OpenBurnBarCore && swift build --target OpenBurnBarKernelPlatform
cd OpenBurnBarCore && swift build --target OpenBurnBarKernel
cd OpenBurnBarCore && swift build --target OpenBurnBarEngine
cd OpenBurnBarCore && swift test
cd OpenBurnBarCore && OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build
cd OpenBurnBarDaemon && swift build
bash scripts/debt/check-core-ui-purity-budget.sh
bash scripts/debt/check-core-target-membership-budget.sh
bash scripts/debt/check-core-umbrella-imports-budget.sh
bash scripts/ci/check-no-suppressions.sh
node tools/ipc/generate-burnbarrpc-canon.mjs --check
```
Plus: scope-diff vs base (only the 12 mv + marker rm + any AE lines).

## Expected size after K1
OpenBurnBarKernelPlatform: 12 files / ~2430 LOC (ceiling 14 / 2900).
