# Packet P-22 (S15): move Engine/OBBCAbi*.swift → OpenBurnBarCoreCAbi
STATE: PR-OPEN (core-decomp/p-22, base core-decomp/p-21)
LANE: Integrator          DEPENDS-ON: P-21 (LinuxLocalPeerDiscovery already left Core)
BASELINE-TOUCHING: core-target-membership (main-target shrink + CAbi ceiling raise)

Post-program follow-up **(b) / optional S15** from `docs/CORE_DECOMPOSITION_PROGRAM.md`
§ REMAINING WORK. The 4 C-ABI `@_cdecl` export files (851 LOC) move OUT of the Core
main target into the EXISTING `OpenBurnBarCoreCAbi` dynamic-library target, so the Core
main target holds **only** the 11 `@_exported` re-export shims. This is the last step to
floor Core to shims-only (11 files / 127 LOC).

## LAYERING STUDY (the CRITICAL check — verified in the p-21 worktree)
`OpenBurnBarCoreCAbi` is declared in `OpenBurnBarCore/Package.swift`:
- `type: .dynamic`, `path: "Sources/OpenBurnBarCoreCAbi"`, `dependencies: ["OpenBurnBarCore"]`
  (it already depends on the Core **umbrella**), `linkerSettings: [.linkedLibrary("sqlite3", …Apple)]`.
- Its one existing file `OpenBurnBarCoreCAbi.swift` does `@_exported import OpenBurnBarCore`
  and declares the `@_cdecl` wrappers `obb_parse_cli_stdout`/`obb_scan_usage`/`obb_string_free`
  that call the plain `public func` bodies (which live in the OBBCAbi files being moved).

Because `OpenBurnBarCoreCAbi` **already depends on the Core umbrella**, relocating the
`@_cdecl` surface there is layering-SAFE and introduces **no cycle** (Core does NOT depend
on CoreCAbi; the edge is one-way CoreCAbi → Core). The moved bodies reference:
- `TokenUsage`, `AgentProvider`, `OpenBurnBarAppPaths` → **OpenBurnBarKernel**
- `ClaudeCodeParser`, `LogParseOptions`, other parsers → **OpenBurnBarLogParsers**
Both are re-exported by the `OpenBurnBarCore` umbrella, and the sibling
`OpenBurnBarCoreCAbi.swift`'s `@_exported import OpenBurnBarCore` makes them visible
**module-wide** inside `OpenBurnBarCoreCAbi`. **Empirically proven**: after the `git mv`
with ZERO edits to the moved files, `swift build --target OpenBurnBarCoreCAbi` → Build
complete (exit 0). So **no manifest dependency edge is added** (the single `OpenBurnBarCore`
dep already covers Kernel + LogParsers via re-export — cleaner than the card's optional
"add Engine + Insights" note, which would be redundant), and **no moved file imports
OpenBurnBarCore** (the FORBIDDEN import): they keep their original `import Foundation` /
`import OpenBurnBarKernel`, and the umbrella symbols resolve via the sibling's `@_exported`.
No STOP condition — the export bodies reference no Core-umbrella-ONLY symbol that would
force a Core→CAbi cycle.

## Scope (ENUMERATED)
### git mv list (Core Engine/ subdir → CoreCAbi; the Engine/ subdir disappears)
- `…/OpenBurnBarCore/Engine/OBBCAbiInsightExport.swift` → `…/OpenBurnBarCoreCAbi/OBBCAbiInsightExport.swift` (267 LOC)
- `…/OpenBurnBarCore/Engine/OBBCAbiMemory.swift`        → `…/OpenBurnBarCoreCAbi/OBBCAbiMemory.swift` (31 LOC)
- `…/OpenBurnBarCore/Engine/OBBCAbiParseExport.swift`   → `…/OpenBurnBarCoreCAbi/OBBCAbiParseExport.swift` (197 LOC)
- `…/OpenBurnBarCore/Engine/OBBCAbiUsageScanExport.swift` → `…/OpenBurnBarCoreCAbi/OBBCAbiUsageScanExport.swift` (356 LOC)

### Allowed edit files (CONVERGED)
- **AE-IMPORT in the 4 moved files**: none. They keep `import Foundation` (all four) +
  `import OpenBurnBarKernel` (OBBCAbiUsageScanExport, already present) + the platform-cond
  imports in OBBCAbiMemory. They gain NO `import OpenBurnBarCore` (FORBIDDEN) — umbrella
  symbols resolve via the sibling `OpenBurnBarCoreCAbi.swift`'s `@_exported import
  OpenBurnBarCore`. No wrapper-vs-body duplicate-symbol clash: the moved `@_cdecl` names
  (`obb_build_insight_digest`, `obb_build_local_canvas`) are distinct from the sibling's
  (`obb_parse_cli_stdout`/`obb_scan_usage`/`obb_string_free`), and the sibling wrappers now
  call the plain `public func` bodies **same-module** instead of via re-export.
- **Package.swift**: ONE edit — added `"OpenBurnBarCoreCAbi"` to the `OpenBurnBarCoreTests`
  test-target `dependencies` (integrator-authorized; acyclic — a test target depending on a
  dynamic lib forms no product cycle). The `OpenBurnBarCoreCAbi` **target declaration is
  unchanged** (still `dependencies: ["OpenBurnBarCore"]`, same path/linker settings — the 4
  files land under its existing `Sources/OpenBurnBarCoreCAbi/` path, auto-globbed). Core's
  Engine/ subdir was NEVER manifest-referenced (no exclude entry), so no exclude-array edit.
- **AE-IMPORT (test)**: `OBBCAbiUsageScanExportTests.swift` gains `import OpenBurnBarCoreCAbi`
  (plain, NOT `@testable` — it touches only PUBLIC OBBCAbi API: `OBBCAbiUsageScanExport.run`,
  `obb_scan_usage`/`obb_parse_cli_stdout`/`obb_string_free`, and the public response/request
  types). The `@testable import OpenBurnBarCore` stays (for `AgentProvider`, Kernel-re-exported).
  Verified the test reaches ZERO internal OBBCAbi member (no `.success(`/`.failure(`/
  `OBBCAbiContract`/`OBBCAbiClaudeStdoutParser`). It was the ONLY repo-wide consumer of the
  moved types (AgentLens/Mobile/daemon reference none).
- **budgets/core-target-membership-baseline.json**: raised the `OpenBurnBarCoreCAbi` sibling
  ceiling `{2 files / 34 LOC}` → `{7 files / 1098 LOC}` (= ceil(1.25× the post-move measured
  5 files / 878 LOC), exactly what `--update` computes for a non-planned sibling). Rationale
  (per the gate's own guidance "decompose it or raise the ceiling with rationale"): the S0
  marker-era ceiling had zero headroom for the legitimate C-ABI relocation. The main-target
  floor line is NOT ratcheted here (reserved for the close-out `--update`); the main shrink
  (15 → 11 files) is a non-fatal "Improved:" in the gate.

## Validation (RESULTS, macOS host — Apple Swift 6.4 / Xcode 27 beta, arch arm64; full Signal graph)
- `swift build --target OpenBurnBarCoreCAbi` → **Build complete! (1.10s)** — exit 0
- `swift build --target OpenBurnBarCore` → **Build complete! (0.86s)** — exit 0
- `swift build --target OpenBurnBarEngine` → **Build complete! (0.83s)** — exit 0
- `swift build --build-tests` → **Build complete! (44.58s)** — exit 0
  (`OpenBurnBarCoreTests-product` links; the repointed `OBBCAbiUsageScanExportTests`
  compiles against `import OpenBurnBarCoreCAbi` with ZERO OBBCAbi/CoreCAbi errors; the full
  Signal-FFI test targets also link because the Vendor xcframeworks + libsignal submodule
  are materialized — the CI-equivalent path, stronger than a product-only build)
- `cd ../OpenBurnBarDaemon && swift build` → **Build complete! (3.29s)** — exit 0
  (daemon links Engine+Core, NOT CoreCAbi; the C-ABI relocation is orthogonal to the daemon
  closure — confirmed no regression)
- `scripts/debt/check-core-target-membership-budget.sh` → **OK** — main shrink non-fatal
  (baselined 16/1610 → live **11 files / 127 LOC** = shims only); CoreCAbi 5 files/878 LOC
  under its raised ceiling 7/1098; no other sibling over ceiling.
- `scripts/debt/check-engine-closure-ui-purity.sh` → OK (CoreCAbi is NOT in Engine's closure
  — Engine does not depend on it; the closure stays 9 pure targets).
- `node tools/ipc/generate-burnbarrpc-canon.mjs --check` → exit 0 (no wire drift).
Not a CANON packet. Title: "P-22 (S15): move OBBCAbi C-ABI export surface into
OpenBurnBarCoreCAbi (Core main target = 11 @_exported shims only)". A1–A6;
BASELINE-TOUCHING core-target-membership (shrink + CAbi ceiling raise).
