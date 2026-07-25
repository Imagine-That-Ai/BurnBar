# Packet P-04a: move pure SharedModels (incl. CloudVaultCrypto) → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0, P-02 (BurnBarCatalogLoader → Kernel; see mv list note)
BASELINE-TOUCHING: none

First of the two dependency-closed S4 halves. These are Foundation-only SharedModels
that are NOT in `openBurnBarCoreExcludes` today (they already compile off-Apple), so
this packet edits ZERO Package.swift exclude lines. CloudVaultCrypto is included here
(it is pure Foundation crypto and the P-04b crypto chain depends on it — moving it
first lets P-04b reference it from Kernel).

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root — 10 files; 2 RELOCATED OUT, see below)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderRuntimeFailoverTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/ProviderRuntimeFailoverTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/WandModelRouter.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/UIMode.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/UIMode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesSquareFeatureFlags.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesSquareFeatureFlags.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxCardEnvelope.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxCardEnvelope.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxSubstrateSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxSubstrateSupport.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AskAssistantIntent.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AskAssistantIntent.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AssistantPendingPrompt.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AssistantPendingPrompt.swift
```

**RE-SLICE (S0-repair, wave-1 learning — closure re-check):** two files were REMOVED from
the original 12 because they forward-reference UI-bound types that STAY in Core through S4
(they end in `OpenBurnBarUI` at S14, which Kernel cannot see):
  - `SubstrateFamily.swift` → uses `RGBA` (12 constructor calls) from `SharedModels/RGBA.swift`
    (RGBA → OpenBurnBarUI per the end-state map). Moving `SubstrateFamily` to Kernel while
    `RGBA` stays in Core breaks the Kernel build. **Relocated to P-16 (UI)** alongside RGBA.
  - `SubscriptionTopic.swift` → its stored `card: CardEnvelope?` binds the Apple
    `Views/Cards/CardEnvelope.swift` (295-line full enum, Core-staying → UI), not the 21-line
    off-Apple `LinuxCardEnvelope` stub. On Apple, Kernel cannot see it. The daemon does NOT
    consume `SubscriptionTopic` (verified), so Kernel-residency is not required. **Relocated
    to P-16 (UI)** with `Views/Cards/CardEnvelope.swift`.
The other 10 files are dependency-closed against Kernel + the moving set. One cross-packet
ordering NOTE (not a blocker): `CLIRuntimeModelCatalog.swift` calls
`BurnBarCatalogLoader.bundledCatalog`; `BurnBarCatalogLoader` moves to Kernel in **P-02**,
so P-02 must MERGE before this packet (both target Kernel; the reference then resolves in
Kernel). Lane D holds P-04a until P-02 is merged.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (none of these 12 files is in
  `openBurnBarCoreExcludes`; verified at S0). If V2 reveals otherwise, STOP.

## Shim
None. Core re-exports Kernel. Do NOT edit `KernelReexport.swift`.

## Forbidden actions
Standard. In particular: do NOT touch `openBurnBarCoreExcludes` (nothing here is in it).

## Enumerated semantic edits
None expected. (These are SharedModels the app and daemon both use → already `public`.)

## Pre-flight checks
1. Path-pin grep of each basename over `.github scripts tools packages .swiftlint.yml project.yml` → expected NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: confirm NONE of the 12 appear in `openBurnBarCoreExcludes`
   (grep Package.swift). If any does → it belongs in P-04b, STOP.
4. Not a CANON packet.

## Local validation
V1 Kernel build · V2 Core build · V3 PURE · V4 test (EDIT-CLASS 2 candidates from pre-flight:
`CLIRuntimeModelCatalogTests.swift`, `CloudVaultCryptoTests.swift`, `WandModelRouterTests.swift`,
`ProviderRuntimeFailoverTypesTests.swift`, `HermesSquarePhaseATests.swift` — add `@testable
import OpenBurnBarKernel` to whichever V4 shows reaching an `internal` symbol) · V5 daemon
build · V6–V9b ratchets (membership shrink; Kernel stays under its planned ceiling) · V11
scope (10 R100, 0 or 1 M, plus any EDIT-CLASS 2 test files).

## PR body / Acceptance
Title: "P-04a: move pure SharedModels into OpenBurnBarKernel (10 files; SubstrateFamily +
SubscriptionTopic re-sliced to P-16)". Invariants: zero call-site changes, no exclude-list
edits, no contract files. A1–A6.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` at the top of MOVED files ONLY, where `<Dep>` is a module the destination
target's manifest already declares as a dependency, exactly as the compiler demands.
Enumerate every added line in the PR body. `import OpenBurnBarCore` on a moved file is
FORBIDDEN (inverts layering). P-04a expectation: NONE (Foundation/Crypto SharedModels closed
against Kernel + the moving set, once P-02 has landed BurnBarCatalogLoader in Kernel).

### EDIT-CLASS 2 — `@testable import OpenBurnBarKernel` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE reaching `internal` members of MOVED
files (public symbols resolve via `@_exported`; `@testable`/internal does NOT cross module
boundaries), add `@testable import OpenBurnBarKernel` beneath `@testable import
OpenBurnBarCore`. Do NOT modify test logic/assertions or move test files. Enumerate touched
files in the PR body. Pre-flight candidates listed in V4 above — edit ONLY those V4 proves
reach an internal symbol.
