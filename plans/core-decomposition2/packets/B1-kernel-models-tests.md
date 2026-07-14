# Packet B1: move KernelModels-owned tests → OpenBurnBarKernelModelsTests (39 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0 (scaffold on core-decomp2/b0)
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarKernelModelsTests/` (target deps at B0:
OpenBurnBarKernelModels, OpenBurnBarKernelPlatform). Delete `PlaceholderTests.swift` here.

## git mv list (from OpenBurnBarCore/Tests/OpenBurnBarCoreTests/ → .../OpenBurnBarKernelModelsTests/)
All 39, flat (no subdirs):
AgentTerminalMirrorRequestTests.swift, BudgetGateContractVectorTests.swift,
BudgetGateCoreTests.swift, BurnBarProviderAuthRegistryTests.swift,
BurnBarWidgetSnapshotDiffTests.swift, CLIRuntimeModelCatalogTests.swift,
CLITerminalSessionSupervisorTests.swift, CastleStatusTests.swift,
ChatTilePreferencesTests.swift, ChunkReassemblyValidatorTests.swift,
DeveloperIDReleaseEntitlementsSmokeTests.swift, EntitlementArbitrationTests.swift,
HermesAttachmentEncoderTests.swift, HermesOpenAICompatibleStreamParserTests.swift,
HermesRealtimeRelayTypesCharacterizationTests.swift, HermesRealtimeRelayTypesTests.swift,
HermesRelayContractTests.swift, HermesSquarePhaseATests.swift, HermesSquarePhaseBTests.swift,
HermesSquareProviderBridgeTests.swift, HermesSquareRemediationTests.swift,
HermesStreamEventTests.swift, MemorySecretPIIGateTests.swift, OMPProviderTests.swift,
OpenBurnBarCatalogTests.swift, OpenBurnBarErrorTests.swift, OpenClaudeProviderTests.swift,
PixelClockConfigTests.swift, Plan2SharedModelsTests.swift, ProviderAccountContractTests.swift,
ProviderQuotaBucketResetTests.swift, ProviderQuotaPacingTests.swift,
ProviderRouteEndpointResolverTests.swift, ProviderRoutingStateBuilderTests.swift,
ProviderRuntimeFailoverTypesTests.swift, QuotaRefreshPolicyTests.swift,
SmartDisplayRepairStatusTests.swift, ThreadSafeISO8601DateFormatterStaticParseTests.swift,
WandModelRouterTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarKernelModels`.
Deviations (from the B0 hit evidence):
- ThreadSafeISO8601DateFormatterStaticParseTests: → `@testable import OpenBurnBarKernelPlatform`
  (Platform-owned type; folds here because Platform mapped <4 files).
- MemorySecretPIIGateTests: already has `@testable import OpenBurnBarKernelModels` — just drop
  the Core/Kernel umbrella imports.
- Cross-sub Kernel hits (HermesRelayContractTests: Crypto 4 + Contracts 3; HermesSquarePhaseA/B,
  HermesSquareRemediationTests: Contracts; Plan2SharedModelsTests, OMPProviderTests,
  OpenClaudeProviderTests: Crypto): add PLAIN `import OpenBurnBarKernelCrypto` /
  `import OpenBurnBarKernelContracts` where the symbols are public, and AE-add those sub-targets
  to the OpenBurnBarKernelModelsTests dependency list in Package.swift (acyclic — test target).
- Weak UI/Insights hits (BudgetGateCoreTests UI(1), CLIRuntimeModelCatalogTests UI+Insights(1),
  HermesRealtimeRelayTypesCharacterizationTests UI(1), SmartDisplayRepairStatusTests UI(1),
  HermesSquarePhaseATests UI(2)+Insights(1), HermesAttachmentEncoderTests Insights(1),
  ProviderAccountContractTests 5×1-hit siblings): likely string-literal false positives — this
  target is CROSS-PLATFORM and must NOT depend on UI/Insights; use the reassignment valve if real.

## Fixture co-moves (target gains `resources: [.process("Fixtures")]`)
- `Fixtures/quota-refresh-policy-fixtures.json` → QuotaRefreshPolicyTests.
- `Fixtures/HermesStreamEventVector.json` → HermesStreamEventTests.
- `Fixtures/budget-enforcement-vectors.json` → BudgetGateContractVectorTests. **REQUIRED same-PR
  edits**: `scripts/ci/check-budget-enforcement-fixture.mjs` (+ its test) and
  `.github/workflows/budget-enforcement-contract.yml` pin the CoreTests fixture path — update to
  the new path.
- `Fixtures/entitlement-vectors.json`: consumed ONLY by the CI scripts above (no Swift reader) —
  LEAVE it in CoreTests/Fixtures untouched.
- MemorySecretPIIGateTests is the resource-wiring CANARY: it asserts the PII corpus loads via
  the production module's own resource bundle (KernelModels owns Resources/ since K2) — no test
  fixture co-move needed, but it MUST still pass from the new target (it proves bundle
  resolution outside the umbrella).

## Package.swift seam edits
- CLITerminalSessionSupervisorTests is in `openBurnBarCoreTestExcludes` (off-Apple exclusion):
  remove it there and add a new `openBurnBarKernelModelsTestsExcludes` seam (off-Apple: the file;
  Apple: []) wired as `exclude:` on the target — mirror the existing exclude-seam idiom.

## Workflow edits (enumerated at B0)
- `openburnbar-pr-harness.yml` Hermes lane filter `OPENBURNBAR_CORE_SWIFT_FILTER=OpenBurnBarCoreTests/Hermes`:
  this packet moves Hermes-named classes out of CoreTests — relax the filter to `Hermes`
  (target-agnostic) in the same PR (unless B3 landed first and already did).

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list.
