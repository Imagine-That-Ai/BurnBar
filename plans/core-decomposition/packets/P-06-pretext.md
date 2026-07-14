# Packet P-06: move Pretext/ (+ its resources) → OpenBurnBarPretext
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none
MANIFEST-STRUCTURE EDIT: yes (the ONE allowed target-structure edit — adds
`resources: [.process("Resources")]` to the Pretext target). Enumerated below.

`Pretext/` is 2 files + a `Resources/Pretext/` bundle (`index.html`,
`pretext.bundle.min.js`). `PretextEngine.swift` is one of the 3 `Bundle.module` files —
its resources move WITH it, so this packet's Bundle.module hit is EXPECTED (like P-02).
The bundle name changes from `OpenBurnBarCore_OpenBurnBarCore.bundle` (flat) to
`OpenBurnBarCore_OpenBurnBarPretext.bundle`; SwiftPM copies product bundles
automatically and nothing OUTSIDE the package stages Pretext resources (verified at
S0 authoring — grep found no external stager for `Pretext`), so the rename is
app-internal. WebKit import in PretextEngine is Apple-guarded (keep as-is).

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextEngine.swift OpenBurnBarCore/Sources/OpenBurnBarPretext/PretextEngine.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Pretext/PretextTypes.swift OpenBurnBarCore/Sources/OpenBurnBarPretext/PretextTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/Pretext OpenBurnBarCore/Sources/OpenBurnBarPretext/Resources/Pretext
```
Then `git rm OpenBurnBarCore/Sources/OpenBurnBarPretext/ModuleMarker.swift`. Remove the
now-empty `Pretext/` source dir if git leaves it. `Resources/catalog.json` and the
`MiningPickIcon-*.svg` STAY in Core (or already moved to Kernel in P-02) — Core keeps
its own `resources: [.process("Resources")]`.

### Allowed edit files (exhaustive)
- `OpenBurnBarCore/Package.swift` — TWO line-level edits:
  1. Add `resources: [.process("Resources")]` to the `OpenBurnBarPretext` target
     (it declares none at S0; the S0 comment on that target flags this exact edit).
     Keep the target's other fields (name, dependencies, exclude) unchanged.
  2. Do NOT touch Core's `resources` block (catalog/SVGs remain there unless P-02 moved
     catalog to Kernel — either way Core still has SVGs, so keep its resources block).
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): if the Pretext build
  (V1) demands `import <Dep>` in a moved file for a symbol that resolved inside Core,
  add it — `<Dep>` MUST be a module `OpenBurnBarPretext` declares (Kernel). The two
  files import Foundation/WebKit/CoreGraphics/OSLog today (WebKit under
  `#if canImport(SwiftUI)`), with no obvious Kernel-symbol use, so none is expected;
  the compiler is the arbiter. Never `import OpenBurnBarCore`. Enumerate any added line.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarPretext` beneath the
  existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  Pretext symbol. Anticipated: NONE (grep of the Core test tree found no Pretext-typed
  test); if a resource-resolution test fails to compile, add it and enumerate.

## Shim
None. `@_exported import OpenBurnBarPretext` already exists in
`OpenBurnBarPretextReexport.swift` (S0). Do NOT edit it.

## Forbidden actions
Standard. Do NOT touch the three-tier `Bundle.module` lookup inside PretextEngine
(subdirectory → flat → folder) — it is self-healing across `.process` flattening and
must move byte-identically.

## Enumerated semantic edits
None to symbols. The manifest `resources:` addition is the enumerated structure edit.

## Pre-flight checks
1. Path-pin grep of `Pretext/PretextEngine.swift`, `Pretext/PretextTypes.swift`,
   `Resources/Pretext`, and `OpenBurnBarCore_OpenBurnBarPretext.bundle` over the
   automation roots → expected NONE (nothing external stages Pretext resources).
2. Bundle.module grep over mv list → HITS in PretextEngine.swift. EXPECTED for this
   packet (resources move with it). Do NOT treat as BLOCKED(resource-bundle) — that
   rule is for UNexpected hits; this packet's card explicitly authorizes it.
3. Platform-conditional: `Pretext/` not in `openBurnBarCoreExcludes`. The WebKit import
   is `#if canImport(WebKit)`-guarded inside the file — leave it.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarPretext` · V2 Core build · V3 PURE (PretextEngine
guards WebKit via canImport, no bare SwiftUI/AppKit import → PURE) · V4 test (Pretext
resource-resolution tests must find the renamed bundle) · V5 daemon build · V6–V9b
ratchets · V11 scope (3 R100 incl. the Resources dir move, 1 D marker, 1 M Package.swift).

## PR body / Acceptance
Title: "P-06: move Pretext/ (+resources) into OpenBurnBarPretext". Invariants: Pretext
gains its own bundle (`OpenBurnBarCore_OpenBurnBarPretext.bundle`), three-tier
Bundle.module lookup preserved, no external stager affected, zero call-site changes.
A1–A6; A3 exception: the enumerated `resources:` manifest edit is IN scope.
