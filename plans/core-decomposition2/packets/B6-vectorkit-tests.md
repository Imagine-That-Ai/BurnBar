# Packet B6: move VectorKit-owned tests → OpenBurnBarVectorKitTests (8 files)
STATE: READY  LANE: Test-decomposition (WS-B)  DEPENDS-ON: B0
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
