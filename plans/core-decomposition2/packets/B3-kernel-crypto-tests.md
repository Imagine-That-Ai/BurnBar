# Packet B3: move KernelCrypto-owned tests → OpenBurnBarKernelCryptoTests (12 files)
STATE: EXECUTED (branch core-decomp2/b3-kernel-crypto-tests, base core-decomp2/b2-kernel-contracts-tests)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

EXECUTED RESULT: 12 files git-mv'd CoreTests → KernelCryptoTests + 2 fixtures co-moved;
PlaceholderTests.swift deleted. ONE VALVE fired (CloudVaultAADParityTests → VectorKit AE-dep,
see below). Whole-package `swift test`: `OpenBurnBarKernelCryptoTests.xctest` Executed 106
tests, 0 failures — identical to the 106 `func test*` methods across the 12 files before the
move (no test dropped). No workflow edit required (B1 already relaxed the harness Hermes
filter; change-detect regex still matches the new paths). coretests baseline NOT ratcheted
here (integrator ratchets budgets/coretests-file-baseline.json once after the whole B-chain;
the gate prints a non-fatal NOTICE and passes).

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
- CloudVaultAADParityTests: VectorKit(1) hit — **VALVE FIRED, the hit was REAL.** The whole
  suite exercises the PUBLIC `PensieveKnowledgeChunker` (`public enum` in
  Sources/OpenBurnBarVectorKit/SharedModels/PensieveKnowledgeChunker.swift:
  `.chunkAADContext`/`.prepareBatch`/`.openChunkText`/`.openChunkMetadata`). Applied the
  card-authorized AE-dep: added plain `import OpenBurnBarVectorKit` to the file + added
  `"OpenBurnBarVectorKit"` to the KernelCryptoTests target deps in Package.swift. VectorKit is
  cross-platform (firstPartyTargetsBase) and depends only on the OpenBurnBarKernel umbrella, so
  a TEST-target dep on it introduces no product cycle; public API only ⇒ plain import.
- CLIAgentSessionCodecTests: Insights(1) hit — confirmed a false positive (no `Insights`
  reference in the file; it needs KernelModels `CLIAgentRelayChatRequest`, handled above).
  No valve; the cross-platform target takes no Apple-only dep.

## Fixture co-moves (target gains `resources: [.process("Fixtures")]`) — DONE
- `Fixtures/SignalBindingAADVectors.json` → SignalEnvelopeAADTests.
- `Fixtures/SignalTransportBindingAADVectors.json` → SignalEnvelopeTransportAADParityTests.
Both tests load via `#file`-relative URLs (mirroring BurnBarHpkeV3CrossPlatformVectorTests),
NOT `Bundle.module`. Even so, SwiftPM fails ("unhandled files") on any file inside a target
dir that is neither a source nor a declared resource, so `resources: [.process("Fixtures")]`
was added to the KernelCryptoTests target (matches how OpenBurnBarCoreTests declared these same
fixtures before the move).

## Workflow edits (enumerated at B0) — NONE NEEDED
- Harness Hermes lane filter: B1 already relaxed it to target-agnostic `Hermes`
  (openburnbar-pr-harness.yml:844) — verified on this branch; the moved
  HermesRatchetCryptoTests / HermesRelay*Tests classes are still matched from their new home.
  No edit.
- Harness change-detect regex `^OpenBurnBarCore/.*Hermes(Relay|Ratchet)`
  (openburnbar-pr-harness.yml:732) still matches the new
  `OpenBurnBarCore/Tests/OpenBurnBarKernelCryptoTests/...` paths (prefix `OpenBurnBarCore/`
  preserved). The stay-pinned `Tests/OpenBurnBarCoreTests/(BurnBarHpkeV3|HermesRelayHPKEv3)`
  paths remain valid (those files STAY). No edit.

## Close-out — DONE
PlaceholderTests.swift deleted. `check-coretests-file-budget.sh` run WITHOUT `--update`
(integrator ratchets the baseline once after the whole B-chain lands — the gate prints a
non-fatal NOTICE and exits 0). Full V-list run; results in the PR body (whole-package build +
`swift test` green with 106/106 KernelCryptoTests; daemon build green; all debt gates pass;
no-suppressions + canon green; the LINUX_BOUNDARY `CSQLite` and `check-baseline-monotonic`
results are pre-existing/inherited and unaffected by this test-move — see PR body).
