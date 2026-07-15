# Packet B6: move VectorKit-owned tests → OpenBurnBarVectorKitTests (8 files)
STATE: EXECUTED (branch core-decomp2/b6-vectorkit-tests, base core-decomp2/b5-ui-module-tests)
LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
Shared conventions + reassignment valve: see B0-mapping.md.

Destination: `OpenBurnBarCore/Tests/OpenBurnBarVectorKitTests/` (cross-platform; target dep at
B0: OpenBurnBarVectorKit). Delete `PlaceholderTests.swift` here.

## git mv list (flat)
BurnBarHNSWVectorIndexTests.swift, BurnBarScalarQuantizerTests.swift,
BurnBarVectorIndexDeltaTests.swift, OpenBurnBarSearchPlannerTests.swift,
OpenBurnBarVectorKitTests.swift, PensieveCloakTSParityTests.swift,
PensieveKnowledgeChunkerTests.swift, PensieveVectorCloakTests.swift

## Expected @testable rewrite per file
Default: `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarVectorKit`.
- BurnBarHNSWVectorIndexTests: already has `@testable import OpenBurnBarVectorKit` — drop the
  Core import only.
- PensieveKnowledgeChunkerTests: KernelCrypto(1) hit — if real, plain
  `import OpenBurnBarKernelCrypto` + AE-dep on the target (cross-platform, acyclic); else
  false positive.
- Pensieve cloak tests use CryptoKit directly (Apple frameworks) — they are compiled on Linux
  today via CoreTests; if any fails to build off-Apple after the move, introduce an
  `openBurnBarVectorKitTestsExcludes` off-Apple seam rather than valving the file back.

## Fixtures
None referenced (verify with a `Bundle.module` grep at move time).

## Close-out
Delete PlaceholderTests.swift; `check-coretests-file-budget.sh --update`; full V-list.

## Execution note (B6, compiler-decided)
- All 8 files `git mv`-d into `Tests/OpenBurnBarVectorKitTests/`; PlaceholderTests.swift
  deleted. Imports (compiler-verified via `swift build --build-tests`, Apple, 0 errors):
  - Default `@testable import OpenBurnBarCore` → `@testable import OpenBurnBarVectorKit`:
    BurnBarScalarQuantizer, BurnBarVectorIndexDelta, OpenBurnBarVectorKit,
    PensieveCloakTSParity, PensieveVectorCloak, PensieveKnowledgeChunker.
  - BurnBarHNSWVectorIndex: already had `@testable import OpenBurnBarVectorKit`; dropped the
    Core import only.
  - OpenBurnBarSearchPlanner: was a PLAIN `import OpenBurnBarCore` (public API only) →
    plain `import OpenBurnBarVectorKit` (tests public `BurnBarFTSQueryBuilder`, in
    Sources/OpenBurnBarVectorKit/OpenBurnBarSearchPlanner.swift). Kept non-@testable.
  - PensieveKnowledgeChunker: the card's "KernelCrypto(1) hit" is REAL — it asserts against
    `OpenBurnBarKernelCrypto.CloudVaultCrypto` (pensieveSlugHmac/openText, both `public`).
    `@testable import OpenBurnBarVectorKit` does not re-export VectorKit's Kernel deps, so
    added a plain `import OpenBurnBarKernelCrypto` + an AE-dep on the test target
    (`dependencies: ["OpenBurnBarVectorKit", "OpenBurnBarKernelCrypto"]`). Acyclic:
    VectorKit already depends on KernelCrypto transitively via the Kernel umbrella; a test
    target naming it adds no product cycle. This mirrors B3's inverse valve
    (KernelCryptoTests AE-deps on OpenBurnBarVectorKit for the same PensieveKnowledgeChunker
    public type).
- NO `openBurnBarVectorKitTestsExcludes` off-Apple seam added. The card flagged the Pensieve
  cloak tests' bare `import CryptoKit` (Apple-only) as a possible off-Apple break. It is not:
  the full-package `swift test` that compiles this target runs ONLY on macos-26
  (.github/workflows/pr-native-fast.yml:120); the off-Apple gate is the
  `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1` **boundary build**, which builds source targets,
  not test targets, so `OpenBurnBarVectorKitTests` is never compiled off-Apple. This is the
  exact proven-green pattern of B3's `OpenBurnBarKernelCryptoTests` (bare `import CryptoKit`
  across 4 files, cross-platform base list, no off-Apple seam). Adding an excludes seam would
  be dead config the card only authorized "if any fails to build off-Apple after the move".
- Whole-package `swift test` (Apple), identical extraction pipeline before/after:
  XCTest-cases-started 2019 → 2018 (exactly −1 = the removed B0 placeholder
  `testScaffoldTargetIsWired`); the 145 moved XCTest methods are conserved 1:1 (git renames
  R, bodies unchanged); 0 real failures both runs; swift-testing untouched (31 methods, 51
  individual). Same scaffold-teardown signature B1–B5 produced.
- Baseline NOT `--update`d (integrator ratchets `coretests-file-baseline.json` at the end);
  the shrink-only gate passes non-fatally (baselined=144 live=27, my 8 among the notice).
