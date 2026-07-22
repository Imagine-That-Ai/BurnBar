# Packet P-04c: move catalog-model SharedModels (CLIRuntimeModelCatalog + WandModelRouter) → OpenBurnBarKernel
STATE: QUEUED-WAVE1F (blocked on #1582 / P-02 merge)
LANE: D          DEPENDS-ON: S0, P-02 (#1582 — the resource-backed `BurnBarCatalogLoader`/`catalog.json` must be Kernel-resident first), P-04a (#1586 — the pure-SharedModels predecessor these two were RE-SLICED OUT of)
BASELINE-TOUCHING: none

Successor to **P-04a**. During P-04a's compile-based closure (2026-07-12) two files were
RE-SLICED OUT because they transitively require the resource-backed catalog loader:
`SharedModels/CLIRuntimeModelCatalog.swift` and `SharedModels/WandModelRouter.swift`.
`CLIRuntimeModelCatalog.swift` has TWO `catalog: BurnBarCatalog =
BurnBarCatalogLoader.bundledCatalog` DEFAULT-ARG sites (verified live at lines **698** and
**709**); `WandModelRouter.swift` uses `CLIRuntimeModelOption` (defined in
`CLIRuntimeModelCatalog.swift`), so it inherits the same P-02 edge transitively. Neither file
can enter the Kernel until **P-02** moves `BurnBarCatalogLoader`
(`OpenBurnBarCatalogLoader.swift`) + `Resources/catalog.json` into the Kernel — otherwise the
Kernel build fails `cannot find 'BurnBarCatalogLoader' in scope`, and pulling the loader+
resource into this packet is a forbidden **resource-bundle STOP** (Failure Playbook #3). See
docs/CORE_DECOMPOSITION_PROGRAM.md Wave-1 learning (9) — the resource-loader hub. These two
files are NOT in `openBurnBarCoreExcludes` today (they already compile off-Apple; verified), so
this packet edits ZERO Package.swift exclude lines.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/WandModelRouter.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift
```
TO-ENUMERATE-AT-WAVE: verify each source still exists at these paths (re-run the two
`git mv` sources through `git ls-files`) before running the moves — if P-04a or a sibling
already moved one, STOP and report (double-move).

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (neither file is in
  `openBurnBarCoreExcludes`; verified 2026-07-12). If V2 reveals otherwise, STOP.
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): both files are
  `import Foundation`-only inside Core today. In the Kernel, `CLIRuntimeModelCatalog.swift`'s
  `BurnBarCatalog`/`BurnBarCatalogLoader` references (3 sites) resolve WITHIN the Kernel
  after P-02 lands the loader there — no cross-target `import` is expected (both types become
  Kernel-resident). If the Kernel build (V1) demands an `import <Dep>` for a symbol that used
  to resolve inside Core, add it to the MOVED file, where `<Dep>` MUST be a module the Kernel
  declares. Never `import OpenBurnBarCore`. Enumerate every added line in the PR body.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarKernel` beneath the existing
  `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL symbol of a moved
  file. **Anticipated: `CLIRuntimeModelCatalogTests.swift` and `WandModelRouterTests.swift`
  (both under `Tests/OpenBurnBarCoreTests/`).** Machine-checked 2026-07-12: BOTH tests
  currently exercise ONLY PUBLIC symbols — `CLIRuntimeModelCatalog` (public enum, :303),
  `CLIRuntimeModelOption` (public struct, :241), and `WandModelRouter` (public enum, :10) —
  which resolve via the `@_exported` umbrella, so NEITHER is expected to need `@testable`
  (same result P-04a proved: "still reach Core, their files did not move"). Add
  `@testable import OpenBurnBarKernel` ONLY where compile actually fails; enumerate each in
  the PR body (expected: none).

## Shim
None. Core re-exports Kernel via `KernelReexport.swift`. Do NOT edit it. `CLIRuntimeModelCatalog`,
`CLIRuntimeModelOption`, and `WandModelRouter` become Kernel symbols reaching all consumers
via the umbrella (zero call-site changes).

## Forbidden actions (any = STOP, revert, report)
- No reformat/re-indent/reorder. No symbol/file/dir renames beyond the mv list.
- No access-level changes (the moved types are already `public`; confirm with V1/V2, do NOT
  add `public` speculatively).
- Do NOT touch `openBurnBarCoreExcludes` (nothing here is in it).
- Do NOT move `OpenBurnBarCatalogLoader.swift` or `Resources/catalog.json` — those are P-02's
  scope; this packet depends on P-02 already having landed them in the Kernel.
- Do not touch: project.yml, *.pbxproj, docs/LINT_RATIONALE.md, budgets/, any file not in the
  Allowed list. No `git worktree remove`.

## Enumerated semantic edits
None expected. (These are `public` SharedModels the app and daemon both use.)

## Pre-flight checks (BEFORE first git mv; any hit not in Allowed-edits = STOP)
1. **P-02 landed check (the whole reason this packet is WAVE1F):** confirm
   `OpenBurnBarKernel/OpenBurnBarCatalogLoader.swift` and
   `OpenBurnBarKernel/Resources/catalog.json` exist on the base (P-02 / #1582 merged). If
   `BurnBarCatalogLoader` is still Core-resident → STOP, `BLOCKED(dep P-02)`.
2. Path-pin grep (machine-derived, verified empty 2026-07-12 — do NOT assume):
   ```
   for p in "SharedModels/CLIRuntimeModelCatalog.swift" "SharedModels/WandModelRouter.swift"; do
     git grep -nF -- "$p" -- .github scripts tools packages .swiftlint.yml project.yml CODEOWNERS || true
   done
   ```
   Expected hits: NONE (verified). Any hit → STOP (a new pin the plan did not anticipate).
3. Bundle.module grep over the mv list → must be EMPTY (verified 2026-07-12: neither file
   uses `Bundle.module`; the bundle is carried by `BurnBarCatalogLoader`, moved in P-02). If
   non-empty → BLOCKED(resource-bundle).
4. Platform-conditional: confirm NEITHER file appears in `openBurnBarCoreExcludes`
   (grep Package.swift). If either does → it belongs in a crypto/off-Apple slice, STOP.
5. Not a CANON packet (mv list does not touch `Sources/OpenBurnBarKernel/Contracts/*`).
6. **Symbol-closure / compile-closure (MANDATORY, Wave-1 learning 9).** After P-02 is on the
   base, dry-run the moves in a scratch worktree and `swift build --target OpenBurnBarKernel`
   BEFORE finalizing: `CLIRuntimeModelCatalog.swift`'s `BurnBarCatalogLoader.bundledCatalog`
   default-args (:698/:709) and its `BurnBarCatalog` refs must resolve to the Kernel-resident
   loader, and `WandModelRouter.swift`'s `CLIRuntimeModelOption` ref must resolve to the moved
   `CLIRuntimeModelCatalog.swift`. If any symbol is unresolved → STOP (P-02 didn't land the
   loader, or another `bundledCatalog` consumer leaked into this slice).

## Local validation (ALL, in order; paste outputs into PR matrix)
- V1: `cd OpenBurnBarCore && swift build --target OpenBurnBarKernel` (the two files must
  resolve `BurnBarCatalogLoader`/`BurnBarCatalog`/`CLIRuntimeModelOption` within the Kernel)
- V2: `cd OpenBurnBarCore && swift build --target OpenBurnBarCore`
- V3: `grep -rlE '^\s*import (SwiftUI|AppKit)' OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift || echo PURE` → must print PURE (both are Foundation-only)
- V4: `cd OpenBurnBarCore && swift test` (CLIRuntimeModelCatalogTests + WandModelRouterTests must resolve the moved types via the umbrella)
- V5: `cd OpenBurnBarDaemon && swift build`
- V6: `./scripts/debt/check-core-ui-purity-budget.sh`
- V7: `./scripts/debt/check-mission-splitbrain-budget.sh` (confirm the SAME pre-existing single AgentLens failure persists; your diff touches no AgentLens file — else STOP)
- V8: `./scripts/debt/check-swift-file-size-budget.sh`
- V9: `./scripts/debt/check-core-target-membership-budget.sh` → "Improved: 2 file(s) left … run --update"; exit 0 (non-fatal shrink — do NOT run --update; the integrator ratchets)
- V9b: `./scripts/debt/check-core-umbrella-imports-budget.sh`
- V11: `git diff --name-status -M100 origin/main | sort` → 2 lines R100 (the mv), plus any enumerated AE-TESTABLE test-file M's / AE-IMPORT moved-file content-M's (each named in the PR body; expected: none). Nothing else.

Linux boundary: these two files already compile off-Apple as Core files and stay Foundation-
only in the Kernel (which links `swiftCryptoNonAppleDependency`); run
`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build` if docker/Linux available, else declare
"CI-covered by linux-pr-gate + openburnbar-engine-windows" in the PR body.

## PR body template
Title: "P-04c: move catalog-model SharedModels (CLIRuntimeModelCatalog + WandModelRouter) into OpenBurnBarKernel"
- Packet: plans/core-decomposition/packets/P-04c-catalog-models-kernel.md @ <sha>
- Review map: 2 files git mv (R100 ×2), 0 Package.swift edits, 0 call-site changes.
- DEPENDS-ON: P-02 (#1582 — `BurnBarCatalogLoader`/`catalog.json` Kernel-resident), P-04a (#1586).
- Invariants: zero call-site changes (@_exported umbrella), no exclude-list edits, no contract
  files in scope; the `bundledCatalog` default-args (:698/:709) now resolve to the Kernel loader.
- Validation matrix: V1–V11 with literal outputs (INCLUDE the mandatory compile-closure result).
- Deferred to CI (named): linux-pr-gate (IPC drift + Linux boundary), openburnbar-engine-windows.
- Known risks: a hidden `bundledCatalog` consumer left in Core could unmask on the Core build —
  V2/V4 catch it locally; the pre-flight compile-closure (check 6) catches it before finalize.
- Rollback: git revert of this squash commit.
- Cross-agent receipt: saw / reaction / status / next owner.

## Acceptance criteria (reviewer checks mechanically)
A1: `git diff --name-status -M100 origin/main` matches this packet's scope exactly (2 R100 + any enumerated AE lines).
A2: Validation matrix V1–V9b all green (V7 = the SAME pre-existing single AgentLens failure, not a new one); compile-closure (pre-flight 6) shown green.
A3: No diff hunks in project.yml/pbxproj/LINT_RATIONALE.md/budgets/Package.swift.
A4: V3 shows PURE.
A5: All pre-flight path-pin hits (none) resolved; P-02 landed (pre-flight 1) confirmed.
A6: PR body names packet file + sha.
