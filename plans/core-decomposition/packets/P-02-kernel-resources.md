# Packet P-02: move catalog loader + PII gate (+ their resources) → OpenBurnBarKernel
STATE: QUEUED
LANE: Integrator          DEPENDS-ON: S0
BASELINE-TOUCHING: none

INTEGRATOR-ONLY packet: it edits ops files (bundle staging) and creates a NEW
resource bundle on the Kernel target. A weak model must NOT run this. It has the
resource-bundle hazard the failure playbook §3 STOPs on — here it is EXPECTED and
handled, which is exactly why the integrator owns it.

The Kernel gains its own `Resources/` bundle (`OpenBurnBarCore_OpenBurnBarKernel.bundle`).
`OpenBurnBarCatalogLoader.swift` and `Memory/MemorySecretPIIGate.swift` are the only
two Core files (besides Pretext) that use `Bundle.module`; they move with their JSON
resources so the bundle resolves.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/OpenBurnBarCatalogLoader.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/OpenBurnBarCatalogLoader.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Memory/MemorySecretPIIGate.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/Memory/MemorySecretPIIGate.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/secret-pattern-corpus.json OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/secret-pattern-corpus.json
```
`MiningPickIcon-*.svg` and `Resources/Pretext/` STAY in Core (SVGs are app-only;
Pretext leaves in P-06). Kernel needs `resources: [.process("Resources")]` added to
its target (see Allowed edits). Core keeps `resources: [.process("Resources")]`
because the SVGs + Pretext remain.

### Allowed edit files (exhaustive; edits described per file)
- `OpenBurnBarCore/Package.swift` — add `resources: [.process("Resources")]` to the
  `OpenBurnBarKernel` target (it has none today). Do NOT remove Core's `resources`
  block (SVGs + Pretext remain). No target/product/dependency changes.
- `AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonManager.swift` — daemon
  installer: ADD staging of `OpenBurnBarCore_OpenBurnBarKernel.bundle` alongside the
  existing `OpenBurnBarCore_OpenBurnBarCore.bundle` (keep staging the old bundle too —
  SVGs + Pretext still live there). Enumerate the exact staging block from the file.
- `.github/workflows/release.yml` (lines ~1150–1151) — ADD `DAEMON_RESOURCE_BUNDLE`/
  `DAEMON_HELPER_RESOURCE_BUNDLE` handling for `OpenBurnBarCore_OpenBurnBarKernel.bundle`
  next to the existing `OpenBurnBarCore_OpenBurnBarCore.bundle` lines. Keep the old.
- `scripts/build-macos-website-release.sh` (lines ~163–164) — same: stage the new
  Kernel bundle alongside the old Core bundle.
- `scripts/ci/smoke-openburnbar-release-dmg.sh` (lines ~123–127) — assert the new
  Kernel bundle is present in the app/helper dirs alongside the old Core bundle.
- `tools/openburnbar-mcp/ministry.py` (line ~29) + `tools/openburnbar-mcp/select_wand_models.py`
  (line ~38) — **NEW HIT the plan did not anticipate**: both hard-code
  `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json` as `CATALOG_PATH`.
  Update both to `OpenBurnBarCore/Sources/OpenBurnBarKernel/Resources/catalog.json`.
  (Also re-check `tools/openburnbar-mcp/tests/test_ministry.py` line ~22 which asserts
  the same path.)

## Shim
None. Catalog loader + PII gate become Kernel symbols; Core already re-exports Kernel
via `KernelReexport.swift`. Do NOT edit it.

## Forbidden actions (any = STOP, revert, report)
- No reformat. No renames beyond the mv list. Keep staging BOTH bundles.
- Do not touch project.yml/*.pbxproj (note: `project.yml` lines 380–404, 736 stage the
  `secret-pattern-corpus.json` from `tools/project-code-memory/`, a DIFFERENT copy —
  NOT the Core Resources copy this packet moves. Do NOT touch those project.yml lines;
  confirm they reference `tools/project-code-memory/secret-pattern-corpus.json`, not
  the moved path, and leave them).
- Do not touch LINT_RATIONALE.md, budgets/.

## Pre-flight checks
1. Path-pin grep for each moved path over `.github scripts tools packages .swiftlint.yml project.yml`.
   Expected hits (all in Allowed-edits): `OpenBurnBarCore_OpenBurnBarCore.bundle`
   (release.yml, build-macos-website-release.sh, smoke-openburnbar-release-dmg.sh),
   `catalog.json` (ministry.py, select_wand_models.py, test_ministry.py). `secret-pattern-corpus.json`
   project.yml hits are the tools/project-code-memory copy — NOT in scope, leave.
2. Bundle.module grep over mv list: `OpenBurnBarCatalogLoader.swift` +
   `MemorySecretPIIGate.swift` WILL hit `Bundle.module`. This is EXPECTED for this
   packet (they carry their resources into Kernel's new bundle). MemorySecretPIIGate
   has a documented Bundle.module fallback probing for daemon test contexts — re-check
   its fallback paths still resolve against the Kernel bundle.
3. `MiningPickIcon` grep repo-wide → confirm no reader depends on them being in a
   specific bundle before leaving them in Core.

## Local validation
- V1: `cd OpenBurnBarCore && swift build --target OpenBurnBarKernel`
- V2: `cd OpenBurnBarCore && swift build --target OpenBurnBarCore`
- V4: `cd OpenBurnBarCore && swift test` (catalog + PII gate tests must resolve the new
  bundle). EXPECTED to need EDIT-CLASS 2: `MemorySecretPIIGateTests.swift` reaches the
  now-cross-module `internal` `_evaluate(_:policy:overrideCorpus:)` + `LoadedCorpus` of
  the moved `MemorySecretPIIGate` → add `@testable import OpenBurnBarKernel` beneath its
  `@testable import OpenBurnBarCore`. `OpenBurnBarCatalogTests.swift` uses only the
  PUBLIC `BurnBarCatalogLoader` API → needs NO edit (its errors, if any, are cascade from
  the shared compile unit and clear once the PII-gate test compiles). See the standard
  block below.
- V5: `cd OpenBurnBarDaemon && swift build`
- V6–V9b: the four ratchets (membership = "Improved" shrink, non-fatal)
- Release smoke: `bash scripts/ci/smoke-openburnbar-release-dmg.sh` (or declare CI-covered)
- MCP tool sanity: `python3 -c "import tools.openburnbar_mcp.ministry"` style path check, or run the test_ministry catalog-path assertion.

## PR body template
Title: "P-02: move catalog loader + PII gate (+resources) into OpenBurnBarKernel"
- Packet + sha; review map (2 swift + 2 json mv, 1 manifest resources edit, 6 ops/tool edits).
- Invariants: Kernel gains its own bundle; Core keeps staging the old bundle (SVGs+Pretext remain); zero call-site changes.
- Validation matrix + release-smoke result.
- Known risks: Bundle.module resolution in daemon test contexts (MemorySecretPIIGate fallback) — V4 + smoke catch it.
- Rollback: git revert. Cross-agent receipt.

## Acceptance criteria
A1–A6 per template. A3 exception: this packet IS allowed to edit the enumerated ops
files + the two tools/openburnbar-mcp py files (integrator packet). project.yml/pbxproj
still forbidden. A3 also allows the EDIT-CLASS 1/2 edits enumerated below (moved-file
imports; `@testable import OpenBurnBarKernel` in the failing test file).

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED on them (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` at the top of MOVED files ONLY, where `<Dep>` is a module the
destination target's manifest already declares as a dependency, exactly as the compiler
demands (same-module references become cross-module after the move). Enumerate every added
line in the PR body. `import OpenBurnBarCore` on a moved file is FORBIDDEN (inverts
layering). P-02 expectation: catalog loader + PII gate are Foundation/Crypto — NO import
additions expected; if V1 demands one, it must be a declared Kernel dependency.

### EDIT-CLASS 2 — `@testable import <NewTarget>` on OpenBurnBarCoreTests files
For test files under `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/` that fail to COMPILE
because they reach `internal` members of MOVED files (public symbols resolve via the
`@_exported` shim; `@testable`/internal does NOT cross the module boundary), add
`@testable import <NewTarget>` beneath the existing `@testable import OpenBurnBarCore`.
Do NOT modify test logic/assertions or move test files. Enumerate every touched test file
in the PR body. Pre-flight (grep OpenBurnBarCoreTests for the moved basenames/type names)
found the expected file for P-02: **`MemorySecretPIIGateTests.swift`** → add `@testable
import OpenBurnBarKernel` (the one authorized test edit).
