# Packet B0: WS-B test-decomposition scaffold + mapping (this PR)
STATE: EXECUTED (branch core-decomp2/b0, base core-decomp2/k5)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: K5 (Kernel is 4 sub-targets under the umbrella)

## What B0 ships
1. **Mapping** of all 144 `.swift` files in `OpenBurnBarCore/Tests/OpenBurnBarCoreTests`
   to their primary tested module (this file + the per-destination lists in B1..B8).
2. **Scaffold**: 8 new SPM test targets in `OpenBurnBarCore/Package.swift`, each with one
   `PlaceholderTests.swift` (trivial always-pass XCTestCase):
   - Cross-platform (in `firstPartyTargetsBase`): `OpenBurnBarKernelModelsTests`,
     `OpenBurnBarKernelContractsTests`, `OpenBurnBarKernelCryptoTests`,
     `OpenBurnBarLogParsersTests`, `OpenBurnBarVectorKitTests`.
   - Apple-pruned (inside `applePrunedDecompositionTargets`, exactly like their modules):
     `OpenBurnBarInsightsTests`, `OpenBurnBarLaunchServicesTests`, `OpenBurnBarUIModuleTests`.
3. **Gate**: `scripts/debt/check-coretests-file-budget.sh` + `budgets/coretests-file-baseline.json`
   (deny-new / non-fatal-shrink / `--update`), registered in `docs/LINT_RATIONALE.md` and wired
   into the `debt-budgets` job of `.github/workflows/fast-feedback.yml` (full checkout — no
   sparse-checkout widening needed).

## Mapping method (evidence, not name-guessing)
`Sources/OpenBurnBarCore` is a pure `@_exported` re-export umbrella since the K-chain —
every type lives in a split module. So: index every top-level type declaration under
`OpenBurnBarCore/Sources/<Module>/`, tokenize each test file, count DISTINCT indexed types
hit per module (ambiguous multi-module names dropped). Primary module = most distinct hits;
overrides applied where `@testable import <module>` lines or defining-file greps beat weak
1-type signals (each override recorded in the destination card). Identifier-hit counts can
include false positives from string literals — every move card carries a REASSIGNMENT VALVE.

## Target decisions
- **Kernel**: per-sub test targets for Models (39), Contracts (19), Crypto (12) — all >=4.
  KernelPlatform mapped only 2 files (< 4) → **no OpenBurnBarKernelPlatformTests**; its files
  fold into `OpenBurnBarKernelModelsTests`, which declares the Platform dep.
- **>=4 rule outcomes**: Insights 29 ✓, UI 11 ✓, VectorKit 8 ✓, LaunchServices 7 ✓,
  LogParsers 4 ✓. Below threshold (files STAY in CoreTests): Hermes 3, Quota 2,
  FirestoreModels 1, TextExpansion 1, Pretext 0, Engine 0, SQLiteReader 0.
- **Media/ComputerUse/Signal/Analytics: ZERO CoreTests files map to them.** The audit's rough
  counts (Media 30, ComputerUse 18, Signal 9, Analytics 5) describe the files ALREADY moved to
  the existing `OpenBurnBar{Media,ComputerUseCore,SignalCore,SignalSessionTransport,Analytics}Tests`
  targets in phase one. No B packet targets them.
- **Name collision**: the SPM test target for module `OpenBurnBarUI` is `OpenBurnBarUIModuleTests`
  — the repo root already has an Xcode UI-testing bundle target named `OpenBurnBarUITests`
  (project.yml:73); reusing the name would collide in scheme/test-report namespaces.

## STAY list (15 files remain in OpenBurnBarCoreTests)
| File | Reason |
|---|---|
| LinuxEmptyTests.swift | off-Apple placeholder seam (`openBurnBarCorePlaceholderExcludes` / `legacyLinuxTestSources`) |
| LLMSafeWrapVectorTests.swift | member of `openBurnBarCoreOffAppleTestSources` seam in Package.swift |
| BurnBarHpkeV3CrossPlatformVectorTests.swift | zero package types (pure CryptoKit vectors); path + fixture pinned by `openburnbar-pr-harness.yml` change-detect regex |
| HermesRelayHPKEv3VectorTests.swift | path pinned by harness regex; shares `BurnBarHpkeV3Vector.json`/`HermesGatewayWireVector.json` with staying tests (splitting would fork fixtures) |
| HermesRelayCrossPlatformVectorTests.swift | shares `HermesGatewayWireVector.json` with the staying HPKEv3 test; cross-platform wire-contract vectors |
| MissionConsoleTests.swift | INTEGRATION: KernelModels(9)+Insights(2)+UI(1); in `openBurnBarCoreTestExcludes` |
| OBBCAbiUsageScanExportTests.swift | INTEGRATION: C-ABI export surface across CoreCAbi(6)+LogParsers(3)+SQLiteReader+Data |
| SQLiteSeamParityTests.swift | INTEGRATION: OpenBurnBarData vs OpenBurnBarSQLiteReader seam parity |
| HermesGatewayFirestoreModelsTests.swift | FirestoreModels maps 1 file (<4) |
| TextExpansionTests.swift | TextExpansion maps 1 file (<4) |
| ZAIQuotaAdapterTests.swift, ClaudeQuotaDomainCoreAdapterTests.swift | Quota maps 2 files (<4) |
| HermesAtomParserTests.swift, HermesInlineMarkdownTests.swift, HermesSourceLinkExtractorTests.swift | Hermes maps 3 files (<4) |

Move totals: B1 KernelModels 39, B2 KernelContracts 19, B3 KernelCrypto 12, B4 Insights 29,
B5 UI 11, B6 VectorKit 8, B7 LaunchServices 7, B8 LogParsers 4 = **129 moves + 15 stay = 144**.

## CI: how the new targets get run (packet item 3)
- `pr-native-fast.yml` → `scripts/test-openburnbar-swift.sh` → **whole-package `swift test`**
  on OpenBurnBarCore: every declared test target (including all 8 new ones) runs automatically.
  No workflow edit needed for target enumeration.
- `fast-feedback.yml` `debt-budgets` job: full `actions/checkout` (NOT sparse) — the new gate's
  read paths (`OpenBurnBarCore/Tests`, `budgets/`) are present without widening anything.
- `openburnbar-pr-harness.yml` has TWO CoreTests-coupled pins the MOVE packets must edit
  (enumerated in the cards, not changed at B0):
  1. line ~841: `OPENBURNBAR_CORE_SWIFT_FILTER=OpenBurnBarCoreTests/Hermes` — target-qualified
     filter. First packet that moves a `Hermes*` test class out of CoreTests (B1 or B3) must
     relax it to the target-agnostic `Hermes` (swift test --filter matches any target).
  2. line ~732 change-detect regex: `^OpenBurnBarCore/Tests/OpenBurnBarCoreTests/(BurnBarHpkeV3|HermesRelayHPKEv3)`
     and the `Fixtures/BurnBarHpkeV3Vector.json` path — kept valid by classifying those tests STAY.
- `budget-enforcement-contract.yml` + `scripts/ci/check-budget-enforcement-fixture.mjs` pin
  `Tests/OpenBurnBarCoreTests/Fixtures/{budget-enforcement-vectors,entitlement-vectors}.json`
  — B1 (which moves BudgetGate tests) must update those paths in the same PR (see B1 card).

## Shared conventions for B1..B8 (every card inherits these)
- Branch `core-decomp2/b<N>`, base = the previous landed WS-B branch (stacked); moves are
  pure `git mv` + minimal import rewrites (no logic edits).
- Per file: replace `@testable import OpenBurnBarCore` with `@testable import <owning module>`
  plus plain `import <sibling>` lines for cross-module PUBLIC symbols. The new targets do NOT
  depend on the OpenBurnBarCore umbrella — do not add it.
- REASSIGNMENT VALVE: if at move time a file demands symbols from a module the destination
  target cannot depend on (e.g. Apple-only OpenBurnBarUI/Insights from a cross-platform
  target), reassign that single file to OpenBurnBarCoreTests (INTEGRATION) or the matching
  Apple-pruned test target, note it in the PR body, and ratchet baselines accordingly.
- Delete the destination target's `PlaceholderTests.swift` in the packet that first moves
  real files in.
- Ratchet: run `scripts/debt/check-coretests-file-budget.sh --update` and commit the shrunk
  baseline in the same PR (shrink is non-fatal, but keep the budget honest).
- `mkdir -p` destination subdirs before nested `git mv` (K1 OP-NOTE).
- Full V-list: whole-package `swift build` + `swift test`; daemon build;
  `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1` build; all `scripts/debt/` gates;
  `scripts/ci/check-no-suppressions.sh`; canon `--check`; scope diff vs base.
