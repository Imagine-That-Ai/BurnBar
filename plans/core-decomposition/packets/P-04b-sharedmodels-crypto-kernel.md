# Packet P-04b: move crypto-chain SharedModels → OpenBurnBarKernel
STATE: CONVERGED (PR open, stacks on P-04a) — see "Convergence update" below.
LANE: D          DEPENDS-ON: S0, P-04a (needs CloudVaultCrypto in Kernel first)
BASELINE-TOUCHING: none

Second dependency-closed S4 half: the crypto chains. All 7 files are in
`openBurnBarCoreExcludes` today, so this packet DELETES their entries from
`openBurnBarCoreExcludes` (the off-Apple surface win — they become part of the Kernel
which already compiles off-Apple with swift-crypto). Dependency edges (all resolve to
already-Kernel symbols after P-04a):
  - `PiConnectionTypes.swift` → uses `PiAgentRelayCrypto`, which is DEFINED in
    `HermesRelayCrypto.swift` — **already in `OpenBurnBarKernel/SharedModels/`** (card
    previously said PiConnectionTypes "defines" it; the compiler-verified truth is it
    USES it and the definer is already Kernel-resident). Closure holds either way.
  - `CLIAgentSessionRecord.swift` → uses `CloudVaultCrypto` (moved in P-04a).
  - `CLIAgentResumePresentation.swift` → uses `CLIAgentSessionRecord` (in this packet).
  - `CloudVaultDeviceKeypair.swift` → uses `CloudVaultCrypto` (moved in P-04a).
  - `HermesRelayAuthenticatedRequest.swift` → uses `HermesRelayCrypto` (already Kernel).

> **Convergence update (integrator, compile-based closure, 2026-07-12).** The Kernel
> build reports ZERO missing symbols for all 7 files — no AE-IMPORT, no AE-TESTABLE
> needed (public crypto-chain types resolve via the `@_exported` umbrella; no test
> reached a moved internal). The card's file/exclude list was exactly right; the only
> correction is the PiAgentRelayCrypto/HermesRelayCrypto note above. The stale exclude
> comment "PiAgentRelayCrypto defined in the excluded HermesRelayCrypto" was dropped
> (HermesRelayCrypto is no longer excluded — it is Kernel-resident).

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultDeviceKeypair.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultDeviceKeypair.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/EscrowDeviceSafetyCode.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/EscrowDeviceSafetyCode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRatchetCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayAuthenticatedRequest.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRelayAuthenticatedRequest.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PiConnectionTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/PiConnectionTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentSessionRecord.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIAgentSessionRecord.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIAgentResumePresentation.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIAgentResumePresentation.swift
```

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — line-level ONLY:
  - DELETE these 7 entries from `openBurnBarCoreExcludes` (they no longer live in the
    Core target):
    `"SharedModels/CLIAgentSessionRecord.swift"`, `"SharedModels/CLIAgentResumePresentation.swift"`,
    `"SharedModels/PiConnectionTypes.swift"`, `"SharedModels/CloudVaultDeviceKeypair.swift"`,
    `"SharedModels/EscrowDeviceSafetyCode.swift"`, `"SharedModels/HermesRatchetCrypto.swift"`,
    `"SharedModels/HermesRelayAuthenticatedRequest.swift"` (and their explanatory
    comment lines — delete the comment that belongs ONLY to a deleted entry).
  - These files were excluded off-Apple ONLY as Core files. In Kernel they compile
    off-Apple (Kernel links `swiftCryptoNonAppleDependency`), so they need NO
    corresponding entry in a Kernel exclude array. If the Linux-boundary build (V-linux)
    fails for one of them, STOP — do NOT invent a Kernel exclude without architect
    sign-off (would silently drop a type from the off-Apple graph).
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): S0-repair FIX-4 closure
  check confirmed these 7 have NO VectorKit-bound refs and depend only on Foundation +
  guarded Security + CloudVaultCrypto (moved in P-04a, so it is already a Kernel symbol
  by the time this packet lands). If the Kernel build demands an `import <Dep>`, add it
  only for a Kernel-declared dep; never `import OpenBurnBarCore`. Enumerate in the PR body.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarKernel` beneath the
  existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  symbol of a moved file. Anticipated: `EscrowDeviceSafetyCodeTests.swift`,
  `HermesRatchetCryptoTests.swift`, `HermesRelayAuthenticatedRequestOpenerTests.swift`,
  `HermesRelayContractTests.swift`, `PiAgentRelayContractTests.swift`,
  `CLIAgentSessionCodecTests.swift`. Add ONLY where compile fails; enumerate in the PR body.

## Shim
None. Core re-exports Kernel. Do NOT edit `KernelReexport.swift`.

## Forbidden actions
Standard. Delete ONLY the 7 enumerated exclude entries; do not reorder the rest.

## Enumerated semantic edits
None expected.

## Pre-flight checks
1. Path-pin grep of each basename over the automation roots → expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: EACH of the 7 basenames MUST currently appear in
   `openBurnBarCoreExcludes` and be deleted in the Package.swift edit above. Any
   mismatch (a file NOT in excludes, or an exclude you can't find) → STOP.
4. Not a CANON packet.

## Local validation (CONVERGED — all run 2026-07-12, Swift 6.4 / macOS)
V1 Kernel build OK · V2 Core build OK · V3 PURE OK (Kernel clean; Core baseline
115=115) · V4 60 tests / 0 failures (EscrowDeviceSafetyCode 18, HermesRatchetCrypto 7,
HermesRelayAuthenticatedRequestOpener 7, HermesRelayContract 12, PiAgentRelayContract 4,
CLIAgentSessionCodec 12) · V5 daemon build OK · V6 membership OK (shrink) · V7 umbrella
OK · **V-linux: could NOT run locally** — `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1
swift build` fails at `unable to resolve module dependency: 'CSQLite'` (the boundary
flag's SQLite module-map does not resolve on this macOS host; NONE of the 7 moved crypto
files are implicated — the failure is upstream of them). Declared **CI-covered by
linux-pr-gate**; risk noted. · V11 scope: 7 R100 + 1 M (Package.swift: 7 exclude entries
+ 4 comment lines removed, no reorder).

## PR body / Acceptance
Title: "P-04b: move crypto-chain SharedModels into OpenBurnBarKernel (off-Apple surface win)".
Invariants: off-Apple exclude seam updated (7 entries removed, byte-equivalent Linux
graph), crypto chains kept together, zero call-site changes. A1–A6; A3 exception:
Package.swift exclude-line deletions are IN scope.
