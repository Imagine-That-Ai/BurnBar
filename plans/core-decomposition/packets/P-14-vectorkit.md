# Packet P-14 (DRAFT): move vector indexes + SearchPlanner + SearchContracts + Pensieve → OpenBurnBarVectorKit
STATE: QUEUED
LANE: D          DEPENDS-ON: S0, P-03 (root mission contracts in Kernel)
BASELINE-TOUCHING: none

Root vector files + SearchPlanner + **`OpenBurnBarSearchContracts.swift`** (re-sliced
here by S0-repair FIX 4 — it references `BurnBarEmbeddingDistanceMetric`
(OpenBurnBarVectorKit.swift) + `BurnBarSearchPlan` (OpenBurnBarSearchPlanner.swift), so
it is VectorKit-bound and moves WITH those defining files, NOT ahead of them into
Kernel via P-03; the daemon reaches it through the Engine umbrella which re-exports
VectorKit) + the two Pensieve SharedModels.
`OpenBurnBarVectorKit.swift` uses Accelerate under `canImport` (verified guarded).

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

AT-WAVE closure re-check: `OpenBurnBarSearchContracts.swift` must land in the SAME
packet as its `BurnBarEmbeddingDistanceMetric`/`BurnBarSearchPlan` definers
(OpenBurnBarVectorKit.swift + OpenBurnBarSearchPlanner.swift, both in this mv list) —
verify none raced out to another target first. If SearchContracts' public API is
consumed by other-target callers that were reaching it via the umbrella, the
`@_exported import OpenBurnBarVectorKit` in Core keeps them compiling (zero call-site
changes); INTERNAL-symbol tests get AE-TESTABLE `@testable import OpenBurnBarVectorKit`.

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
V1–V11. V-linux boundary build is the critical Pensieve/CryptoKit check. Not a CANON
packet. Title: "P-14: move vector indexes + SearchPlanner + Pensieve into
OpenBurnBarVectorKit". A1–A6.
