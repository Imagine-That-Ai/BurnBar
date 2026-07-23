# Packet B2: move KernelContracts-owned tests → OpenBurnBarKernelContractsTests (19 files)
STATE: EXECUTED (branch core-decomp2/b2-kernel-contracts-tests, base core-decomp2/b1-kernel-models-tests)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

## EXECUTION NOTES
- All 19 files moved (no reassignment valve fired). Pure `git mv` + import rewrites — no
  test logic changed (every renamed file's only content delta is the import block).
- Default rewrite applied to all 19: `@testable import OpenBurnBarCore` →
  `@testable import OpenBurnBarKernelContracts`.
- KernelPlatform plain-import deviations (the card's 4/10/8-hit files) — CONFIRMED real by the
  compiler and added as plain `import OpenBurnBarKernelPlatform` (the referenced symbols are
  PUBLIC value types, so plain import, not @testable):
  - `OpenBurnBarContractsToolBridgeTests`: BurnBar{Client,Session,Run}ID, BurnBarJSONValue.
  - `OpenBurnBarMissionControlContractsTests`: BurnBar{Client,Session,Run,Mission,MissionPacket,
    MissionResult,Question,Followup,SimulatorRun,ControllerEvent,ProjectionCheckpoint}ID.
  - `OpenBurnBarMissionControlMissionsContractsTests`: BurnBar{Run,Mission,MissionPacket,
    MissionResult,Question,Followup,SimulatorRun,ControllerEvent}ID.
  All eight ID families + BurnBarJSONValue are declared in `OpenBurnBarKernelPlatform`
  (Sources/OpenBurnBarKernelPlatform/OpenBurnBar{Identifiers,JSONValue}.swift), verified by
  defining-file grep. The KernelContractsTests target already declared the KernelPlatform dep at
  B0, so NO Package.swift dep edit was needed — the plain imports resolve on the existing
  (acyclic) edge.
- The card's "weak sibling hits" (OpenBurnBarMissionControlContractsTests: Insights 2 +
  TextExpansion 1; ProviderCredentialSlotRoutingPolicyTests: TextExpansion 1) proved to be
  string-literal false positives: the cross-platform KernelContractsTests target takes NO
  Apple-only Insights/TextExpansion dependency and every moved file compiles green without one.
- HermesSquare{Motion,PhaseC,PhaseD} (Hermes-NAMED, Contracts-owned) moved cleanly. The harness
  Hermes-lane filter was already relaxed `OpenBurnBarCoreTests/Hermes` → `Hermes` by B1
  (openburnbar-pr-harness.yml line ~844), so those classes are still matched from their new
  KernelContractsTests home — NO workflow edit needed in B2.
- No Package.swift target edit at all: the KernelContractsTests target's deps (KernelContracts,
  KernelModels, KernelCrypto, KernelPlatform), exclude (none — none of the 19 are file-excluded
  off-Apple and OpenBurnBarKernelContracts is a cross-platform module), and resources (none) were
  all correct as scaffolded at B0.
- `PlaceholderTests.swift` deleted (first real files landed).
- coretests-file baseline NOT ratcheted here. The card's close-out said
  `check-coretests-file-budget.sh --update`, but the WS-B integrator ratchets
  `budgets/coretests-file-baseline.json` ONCE after the whole B-chain lands (keeps the baseline
  stable for stacked B2..B8). The gate prints a non-fatal NOTICE (19 removed, 0 new) and passes.

## Fixtures
None. Verified: zero `Bundle.module` / `Bundle(for:` references across the 19 files at move
time; nothing co-moved.

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

## @testable rewrite per file (as executed)
Default: `@testable import OpenBurnBarKernelContracts` (all 19).
Plus plain `import OpenBurnBarKernelPlatform` on the 3 mission-control/tool-bridge files
enumerated in EXECUTION NOTES.

## Close-out
Deleted PlaceholderTests.swift; baseline NOT `--update`d (integrator ratchets — see notes);
full V-list green (see PR body). Test count preserved: 160 test-method decls across the 19 files,
identical before (in OpenBurnBarCoreTests) and after (in OpenBurnBarKernelContractsTests).
