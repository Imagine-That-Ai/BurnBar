# Packet K3: extract OpenBurnBarKernelCrypto (key material + sealed envelopes)
STATE: DRAFT  LANE: Kernel-diet  DEPENDS-ON: K0, K1, K2 (Platform + Models must exist)
BASELINE-TOUCHING: none (Kernel shrink non-fatal)
BASE: origin/main (after K2 merges)

Moves the 12 crypto-tier files into `OpenBurnBarKernelCrypto` and deletes its
`ModuleMarker.swift`. Deps: `OpenBurnBarKernelPlatform`, `OpenBurnBarKernelModels`.
Includes `CLIAgentSessionRecord.swift` (a CloudVaultCrypto CONSUMER — calls
`.sealPayload/.openPayload`, proven by grep at K0). `CLIAgentResumePresentation.swift`
was REASSIGNED to Contracts (K4) — it needs Crypto AND a Contracts type
(`BurnBarRunResumeResponse`), and only Contracts can depend on both.

## git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIAgentSessionRecord.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CLIAgentSessionRecord.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultDeviceKeypair.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultDeviceKeypair.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultSignalEnvelopeModels.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultSignalEnvelopeModels.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/EscrowDeviceSafetyCode.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/EscrowDeviceSafetyCode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/EscrowModels.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/EscrowModels.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRatchetCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRatchetCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRelayAuthenticatedRequest.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRelayAuthenticatedRequest.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesRelayCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/HermesRelayCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/PiConnectionTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/PiConnectionTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/RoamingProfilePayload.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/RoamingProfilePayload.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SignalEnvelopeAAD.swift OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/SignalEnvelopeAAD.swift
git rm OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/ModuleMarker.swift
```

## Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (Crypto deps
  `[Platform, Models, swiftCryptoNonAppleDependency]` declared at K0; no exclude edits
  — Crypto compiles whole off-Apple via swiftCryptoNonAppleDependency, exactly as the
  phase-1 P-04b crypto chain did).
- **AE-IMPORT** (EXPECTED): `import OpenBurnBarKernelPlatform` in the ~5 files that use
  PlatformCrypto/PlatformLogger/SendableFileSystem (CloudVaultCrypto,
  CloudVaultDeviceKeypair, EscrowDeviceSafetyCode, HermesRelayCrypto,
  HermesRatchetCrypto); `import OpenBurnBarKernelModels` in the ~5 files that reference
  Models types (EscrowDeviceSafetyCode, HermesRelayCrypto, HermesRelayAuthenticatedRequest,
  RoamingProfilePayload, CLIAgentSessionRecord — e.g. SwitcherProfile/AgentProvider/
  TokenUsage). `import Foundation`/`import Security` already present. NEVER `import
  OpenBurnBarKernelContracts` (Crypto sits BELOW Contracts) or `OpenBurnBarCore`. If a
  Crypto file demands a Contracts type → STOP (`BLOCKED(closure)`): it belongs in
  Contracts (as CLIAgentResumePresentation did).
- **AE-TESTABLE**: `@testable import OpenBurnBarKernelCrypto` in Core tests reaching
  moved internals. Anticipated: `CloudVaultCryptoTests`, `CloudVaultRotation*Tests`,
  `EscrowDeviceSafetyCodeTests`, `EscrowModelsTests`, `HermesRatchetCryptoTests`,
  `HermesRelayCryptoTests` / `HermesRelayAuthenticatedRequestOpenerTests`,
  `PiAgentRelayContractTests`, `CLIAgentSessionCodecTests`, `SignalEnvelopeAADTests`.
  Add ONLY where compile fails.

## Pre-flight path-pin greps (RUN; enumerate hits)
- **`.github/CODEOWNERS:54`** — `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift @Ajnunezg @emilio3435`.
  UPDATE this pin path to
  `OpenBurnBarCore/Sources/OpenBurnBarKernelCrypto/SharedModels/CloudVaultCrypto.swift`
  in the SAME PR (K0 enumerated this — it is the ONLY CODEOWNERS Kernel pin). This is
  an allowed K3 edit (enumerate in PR body). Confirm no OTHER moved crypto path is pinned.
- Canon pins — none on crypto paths (BurnBarRPC* → K4).
- gitleaks scans EVERY commit: these are source crypto files with NO embedded secrets
  (key material is generated/loaded at runtime). If a moved file trips gitleaks it is a
  pre-existing false positive on main — do NOT rewrite; note in PR body.

## Shim
None. KernelUmbrella.swift already re-exports OpenBurnBarKernelCrypto (K0).

## Forbidden actions
Same as K1. No Package.swift dependency-edge additions (Crypto's deps fixed at K0).

## Validation (V-list)
Same 12-command V-list as K1 (whole build; --target KernelCrypto + Kernel + Engine;
swift test; Linux-boundary build; daemon build; 3 debt gates; no-suppressions; canon
--check). Crypto-specific: the CloudVault/Escrow/Signal interop KAT tests
(CryptoKitAtRestInterop / rotation-handoff / OBBSignal*) must stay green — they prove
wire/at-rest byte-compat survived the module split.

## Expected size after K3
OpenBurnBarKernelCrypto: 12 files / ~5172 LOC (ceiling 14 / 5900).
