# Packet P-04b: move crypto-chain SharedModels → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0, P-04a (needs CloudVaultCrypto in Kernel first)
BASELINE-TOUCHING: none

Second dependency-closed S4 half: the crypto chains. All 7 files are in
`openBurnBarCoreExcludes` today, so this packet DELETES their entries from
`openBurnBarCoreExcludes` (the off-Apple surface win — they become part of the Kernel
which already compiles off-Apple with swift-crypto). Two chains must move together and
are already in this one packet:
  - `PiConnectionTypes.swift` DEFINES `PiAgentRelayCrypto` (self-contained; verified).
  - `CLIAgentSessionRecord.swift` → uses `CloudVaultCrypto` (moved in P-04a).
  - `CLIAgentResumePresentation.swift` → uses `CLIAgentSessionRecord` (in this packet).
  - `CloudVaultDeviceKeypair.swift` → uses `CloudVaultCrypto` (moved in P-04a).

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

## Local validation
V1 Kernel build · V2 Core build · V3 PURE · V4 test · V5 daemon build ·
V-linux: `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build` (these files now
compile off-Apple in Kernel — this is the key check; if docker/Linux unavailable,
declare "CI-covered by linux-pr-gate" and note the risk) · V6–V9b ratchets ·
V11 scope (7 R100 + 1 M Package.swift).

## PR body / Acceptance
Title: "P-04b: move crypto-chain SharedModels into OpenBurnBarKernel (off-Apple surface win)".
Invariants: off-Apple exclude seam updated (7 entries removed, byte-equivalent Linux
graph), crypto chains kept together, zero call-site changes. A1–A6; A3 exception:
Package.swift exclude-line deletions are IN scope.
