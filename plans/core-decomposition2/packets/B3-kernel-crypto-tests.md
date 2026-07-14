# Packet B3: move KernelCrypto-owned tests → OpenBurnBarKernelCryptoTests (12 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarKernelCryptoTests/` (target deps at B0:
OpenBurnBarKernelCrypto, OpenBurnBarKernelModels, OpenBurnBarKernelPlatform). Delete
`PlaceholderTests.swift` here.

NOT in this packet (STAY — see B0-mapping.md): HermesRelayHPKEv3VectorTests.swift and
HermesRelayCrossPlatformVectorTests.swift. Both are pinned by the openburnbar-pr-harness.yml
change-detect regex (`Tests/OpenBurnBarCoreTests/(BurnBarHpkeV3|HermesRelayHPKEv3)` +
`Fixtures/BurnBarHpkeV3Vector.json`) and share fixtures (BurnBarHpkeV3Vector.json,
HermesGatewayWireVector.json) with the staying BurnBarHpkeV3CrossPlatformVectorTests —
moving them would fork fixture copies or break the harness pins.

## git mv list (flat)
CLIAgentSessionCodecTests.swift, CloudVaultAADParityTests.swift, CloudVaultCryptoTests.swift,
CloudVaultSignalEnvelopeTests.swift, EscrowCredentialMetadataBindingTests.swift,
EscrowDeviceSafetyCodeTests.swift, HermesRatchetCryptoTests.swift,
HermesRelayAuthenticatedRequestOpenerTests.swift, HermesRelayCryptoSealKeyAADTests.swift,
PiAgentRelayContractTests.swift, SignalEnvelopeAADTests.swift,
SignalEnvelopeTransportAADParityTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarKernelCrypto`.
Deviations:
- CloudVaultCryptoTests: already has `@testable import OpenBurnBarKernelCrypto` — drop the
  Core/Kernel umbrella imports.
- KernelModels hits (CLIAgentSessionCodecTests 1, CloudVaultCryptoTests 1,
  HermesRelayAuthenticatedRequestOpenerTests 2, PiAgentRelayContractTests 2): plain
  `import OpenBurnBarKernelModels` (dep already declared).
- CloudVaultAADParityTests: VectorKit(1) hit — likely a false positive; valve if real
  (VectorKit is cross-platform, so an AE-dep on OpenBurnBarVectorKit is also acceptable).
- CLIAgentSessionCodecTests: Insights(1) hit — Apple-only module, cross-platform target;
  almost certainly a string literal; valve if real.

## Fixture co-moves (target gains `resources: [.process("Fixtures")]`)
- `Fixtures/SignalBindingAADVectors.json` → SignalEnvelopeAADTests.
- `Fixtures/SignalTransportBindingAADVectors.json` → SignalEnvelopeTransportAADParityTests.

## Workflow edits (enumerated at B0)
- Harness Hermes lane filter (`OPENBURNBAR_CORE_SWIFT_FILTER=OpenBurnBarCoreTests/Hermes`):
  this packet moves HermesRatchetCryptoTests / HermesRelay*Tests classes out of CoreTests —
  relax the filter to target-agnostic `Hermes` in the same PR (unless B1 landed first).
- Harness change-detect regex `^OpenBurnBarCore/.*Hermes(Relay|Ratchet)` still matches the new
  `Tests/OpenBurnBarKernelCryptoTests/...` paths (prefix is `OpenBurnBarCore/`): no edit needed.

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list.
