# Packet B2: move KernelContracts-owned tests → OpenBurnBarKernelContractsTests (19 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarKernelContractsTests/` (target deps at B0:
OpenBurnBarKernelContracts, OpenBurnBarKernelModels, OpenBurnBarKernelCrypto,
OpenBurnBarKernelPlatform — already covers every cross-sub hit below). Delete
`PlaceholderTests.swift` here.

## git mv list (flat)
BurnBarCustomModelTests.swift, BurnBarModelAliasContractTests.swift,
BurnBarModelDisplayOverrideContractTests.swift, BurnBarModelVariantContractTests.swift,
BurnBarProviderAdvertisementContractTests.swift, BurnBarRPCContractsTests.swift,
BurnBarRemoteMissionAuthorizationContractsTests.swift, BurnBarRunCreateMetadataTests.swift,
ClientTelemetrySanitizerTests.swift, FusionSessionSpendTests.swift,
HermesSquareMotionTests.swift, HermesSquarePhaseCTests.swift, HermesSquarePhaseDTests.swift,
OpenBurnBarContractsToolBridgeTests.swift, OpenBurnBarMissionControlContractsTests.swift,
OpenBurnBarMissionControlMissionsContractsTests.swift, OpenBurnBarProtocolVersionTests.swift,
OpenBurnBarRunStateMachineTests.swift, ProviderCredentialSlotRoutingPolicyTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarKernelContracts`.
Deviations:
- OpenBurnBarContractsToolBridgeTests / OpenBurnBarMissionControlContractsTests /
  OpenBurnBarMissionControlMissionsContractsTests: heavy KernelPlatform hits (4/10/8) — add
  `import OpenBurnBarKernelPlatform` (or @testable if internals are reached).
- Weak sibling hits (OpenBurnBarMissionControlContractsTests: Insights 2 + TextExpansion 1;
  ProviderCredentialSlotRoutingPolicyTests: TextExpansion 1): likely string-literal false
  positives — Insights/TextExpansion are Apple-only and this target is cross-platform; use the
  reassignment valve if the symbols are real.
- HermesSquare{Motion,PhaseC,PhaseD}: Hermes-NAMED but Contracts-owned types; moving them out of
  CoreTests shrinks the harness Hermes-lane filter match — covered by the B1/B3 filter relax
  (`OPENBURNBAR_CORE_SWIFT_FILTER` → `Hermes`); coordinate whichever lands first.

## Fixtures
None referenced by these 19 files (verify with a `Bundle.module` grep at move time).

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list.
