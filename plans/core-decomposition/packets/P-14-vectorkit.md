# Packet P-14 (DRAFT): move vector indexes + SearchPlanner + SearchContracts + Pensieve → OpenBurnBarVectorKit
STATE: QUEUED
LANE: D          DEPENDS-ON: S0, P-03 (root mission contracts in Kernel)
BASELINE-TOUCHING: none

Root vector files + SearchPlanner + `OpenBurnBarSearchContracts.swift` (re-sliced HERE from
P-03 — S0-repair) + the two Pensieve SharedModels. `OpenBurnBarVectorKit.swift` uses
Accelerate under `canImport` (verified guarded).

**RE-SLICE (S0-repair, wave-1 learning):** `OpenBurnBarSearchContracts.swift` moved OUT of
P-03 into this packet. It references `BurnBarEmbeddingDistanceMetric` (in
`OpenBurnBarVectorKit.swift`) and `BurnBarSearchPlan` (in `OpenBurnBarSearchPlanner.swift`) —
both land in THIS target — so SearchContracts is dependency-closed here but was NOT in the
leaf Kernel target P-03 targeted (Kernel cannot see those VectorKit types). The daemon reaches
SearchContracts via the Engine umbrella (which `@_exported`s VectorKit), so Kernel-residency
is not required.

## Scope (TO-ENUMERATE-AT-WAVE)
### git mv list
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarHNSWVectorIndex.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarHNSWVectorIndex.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarPersistentVectorIndex.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarPersistentVectorIndex.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarSignpostVectorIndex.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarSignpostVectorIndex.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/BurnBarVectorIndexDelta.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/BurnBarVectorIndexDelta.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarVectorKit.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/OpenBurnBarVectorKit.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarSearchPlanner.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/OpenBurnBarSearchPlanner.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarSearchContracts.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/OpenBurnBarSearchContracts.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveKnowledgeChunker.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/SharedModels/PensieveKnowledgeChunker.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/PensieveVectorCloak.swift OpenBurnBarCore/Sources/OpenBurnBarVectorKit/SharedModels/PensieveVectorCloak.swift
```
Remove `OpenBurnBarVectorKit/ModuleMarker.swift`.

Note: `OpenBurnBarSearchContracts.swift` is currently listed in the membership baseline as a
Core main-target file; moving it here shrinks Core by one more file than the pre-repair P-14
draft assumed (9 moves, not 8). The VectorKit planned ceiling (12 files/5800 lines) already
accounts for SearchContracts (see the S0-repair note in the membership gate).

### Enumerated semantic edits / INFERRED verify
- Pensieve files' CryptoKit: `PensieveVectorCloak`/`PensieveKnowledgeChunker` are in
  `openBurnBarCoreExcludes` today. AT EXECUTION: check whether they import CryptoKit
  UNGUARDED; if so, either add `canImport` guards (enumerate as a semantic edit) OR add
  them to `openBurnBarVectorKitExcludes`. VectorKit is cross-platform (has a product),
  so unguarded CryptoKit would break the off-Apple build — resolve this in-slice.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — DELETE `"SharedModels/PensieveKnowledgeChunker.swift"`
  and `"SharedModels/PensieveVectorCloak.swift"` from `openBurnBarCoreExcludes`; if they
  need off-Apple exclusion in VectorKit, add to `openBurnBarVectorKitExcludes`
  (mutually exclusive with adding canImport guards — pick one, document).

## Validation
V1–V11. V1 `swift build --target OpenBurnBarVectorKit` (add EDIT-CLASS 1 `import
OpenBurnBarKernel` on moved files that reference Kernel PUBLIC types — e.g. SearchContracts
after it joins VectorKit — iterate until green). V4 test (add EDIT-CLASS 2 `@testable import
OpenBurnBarVectorKit` where a test reaches an internal VectorKit symbol). V-linux boundary
build is the critical Pensieve/CryptoKit check. V6–V9b: VectorKit stays under its planned
ceiling (12 files/5800 lines, which INCLUDES SearchContracts). Not a CANON packet. Title:
"P-14: move vector indexes + SearchPlanner + SearchContracts + Pensieve into
OpenBurnBarVectorKit". A1–A6; A3 exception: EDIT-CLASS 1/2 edits + the `openBurnBarCoreExcludes`
Pensieve edits are IN scope.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` (Kernel is the declared VectorKit dependency) at the top of MOVED files
that reference cross-module PUBLIC types, exactly as the compiler demands; iterate until
green. Enumerate every added line in the PR body. `import OpenBurnBarCore` on a moved file is
FORBIDDEN (inverts layering).

### EDIT-CLASS 2 — `@testable import OpenBurnBarVectorKit` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE reaching `internal` members of MOVED
files, add `@testable import OpenBurnBarVectorKit` beneath `@testable import OpenBurnBarCore`.
Do NOT modify test logic/assertions or move test files. Enumerate touched files in the PR
body. Pre-flight candidates: `BurnBarHNSWVectorIndexTests.swift`, `BurnBarVectorIndexDeltaTests.swift`,
`PensieveKnowledgeChunkerTests.swift` — edit ONLY those V4 proves reach an internal symbol.
