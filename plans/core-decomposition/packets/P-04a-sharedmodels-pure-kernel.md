# Packet P-04a: move pure SharedModels (incl. CloudVaultCrypto) → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none

First of the two dependency-closed S4 halves. These are Foundation-only SharedModels
that are NOT in `openBurnBarCoreExcludes` today (they already compile off-Apple), so
this packet edits ZERO Package.swift exclude lines. CloudVaultCrypto is included here
(it is pure Foundation crypto and the P-04b crypto chain depends on it — moving it
first lets P-04b reference it from Kernel).

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderRuntimeFailoverTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/ProviderRuntimeFailoverTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubscriptionTopic.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubscriptionTopic.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/WandModelRouter.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/UIMode.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/UIMode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesSquareFeatureFlags.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesSquareFeatureFlags.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxCardEnvelope.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxCardEnvelope.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxSubstrateSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxSubstrateSupport.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubstrateFamily.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubstrateFamily.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AskAssistantIntent.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AskAssistantIntent.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AssistantPendingPrompt.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AssistantPendingPrompt.swift
```

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (none of these 12 files is in
  `openBurnBarCoreExcludes`; verified at S0). If V2 reveals otherwise, STOP.
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): if the Kernel build
  demands `import <Dep>` in a moved file, add it (`<Dep>` a Kernel-declared dep only).
  Note the S0-repair FIX-4 closure check: these 12 are Foundation/CryptoKit/Security/
  AppIntents(guarded)/Observation-based with NO VectorKit-bound refs (CloudVaultCrypto's
  `Pensieve` mentions are doc comments only), so no cross-target `import` is expected;
  `AskAssistantIntent.swift` is whole-file `#if canImport(AppIntents)`-guarded (compiles
  off-Apple as empty). Never `import OpenBurnBarCore`.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarKernel` beneath the
  existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  symbol of a moved file. Anticipated: `CLIRuntimeModelCatalogTests.swift`,
  `CloudVaultCryptoTests.swift`, `CloudVaultAADParityTests.swift`,
  `CloudVaultSignalEnvelopeTests.swift`, `ProviderRuntimeFailoverTypesTests.swift`,
  `WandModelRouterTests.swift`, `HermesSquarePhaseATests.swift`,
  `SwarmSubstrateContractTests.swift`, `CLIAgentSessionCodecTests.swift`,
  `PensieveKnowledgeChunkerTests.swift`. Add ONLY where compile fails (public models
  need none); enumerate in the PR body.

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
V1 Kernel build · V2 Core build · V3 PURE · V4 test · V5 daemon build · V6–V9b
ratchets (membership shrink) · V11 scope (12 R100, 0 or 1 M).

## PR body / Acceptance
Title: "P-04a: move pure SharedModels into OpenBurnBarKernel". Invariants: zero
call-site changes, no exclude-list edits, no contract files. A1–A6.
