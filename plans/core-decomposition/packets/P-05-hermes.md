# Packet P-05: move Hermes/ → OpenBurnBarHermes
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none

`Hermes/` is 7 files (whole-directory move). Six are Foundation-only; **one —
`HermesAtomNavigator.swift` — additionally uses `PlatformLogger` from OpenBurnBarKernel**
(the S0 card's "7 Foundation-only files (verified)" claim was wrong for that file; wave-1
executor P-05 correctly BLOCKED on it). It resolved in the monolith by co-location; in the
standalone `OpenBurnBarHermes` target it needs an explicit `import OpenBurnBarKernel`.
`PlatformLogger` is `public` in Kernel (`Platform/PlatformSupport.swift`, both
`#if canImport(OSLog)` branches — verified), so NO Kernel access-level change is needed, and
`OpenBurnBarHermes` already declares `dependencies: ["OpenBurnBarKernel"]` (S0). See
Enumerated semantic edits.

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtom.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesAtom.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomNavigator.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesAtomNavigator.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomParser.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesAtomParser.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesAtomURL.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesAtomURL.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesInlineMarkdown.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesInlineMarkdown.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesSourceLinkExtractor.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesSourceLinkExtractor.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Hermes/HermesSystemPromptBuilder.swift OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesSystemPromptBuilder.swift
```
Then `git rm OpenBurnBarCore/Sources/OpenBurnBarHermes/ModuleMarker.swift` (target now
has real sources). Remove the now-empty `Hermes/` dir if git leaves it.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (`Hermes/` is not in
  `openBurnBarCoreExcludes`; verified). If V2 says otherwise, STOP.

## Shim
None. `@_exported import OpenBurnBarHermes` already exists in
`OpenBurnBarHermesReexport.swift` (S0). Do NOT edit it.

## Forbidden actions
Standard.

## Enumerated semantic edits
ONE enumerated EDIT-CLASS 1 edit (see standard block): add `import OpenBurnBarKernel` to
`OpenBurnBarCore/Sources/OpenBurnBarHermes/HermesAtomNavigator.swift`, immediately after its
`import Foundation` line (it references `PlatformLogger`, a public Kernel symbol). The other
6 moved files are genuinely Foundation-only — add NO import to them. Enumerate the single
added line in the PR body. No `public` keyword changes (Hermes types are already `public`;
`PlatformLogger` is already `public` in Kernel).

## Pre-flight checks
1. Path-pin grep of `Hermes/HermesAtom.swift` and `Hermes/` over the automation roots.
   NOTE: a grep for `/Hermes/` hits `OpenBurnBarMobile/Services/Hermes/...` — that is a
   DIFFERENT tree (the mobile app), NOT the Core `Hermes/` dir. Ignore mobile hits.
   Expected Core-path hits: NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `Hermes/` not in excludes. No Package.swift edit.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarHermes` (must be green WITH the one `import
OpenBurnBarKernel` on HermesAtomNavigator) · V2 Core build · V3 PURE · V4 test (EDIT-CLASS 2
candidates: `HermesAtomParserTests.swift`, `HermesInlineMarkdownTests.swift`,
`HermesSourceLinkExtractorTests.swift` — add `@testable import OpenBurnBarHermes` to whichever
V4 shows reaching an `internal` Hermes symbol) · V5 daemon build · V6–V9b ratchets (membership
shrink; Hermes stays under its planned ceiling 10 files/1800 lines) · V11 scope (7 R100, 1 D
marker, 1 M HermesAtomNavigator import, plus any EDIT-CLASS 2 test files).

## PR body / Acceptance
Title: "P-05: move Hermes/ into OpenBurnBarHermes". Invariants: zero call-site changes
(@_exported shim), one enumerated `import OpenBurnBarKernel` (HermesAtomNavigator), no exclude
edits. A1–A6.

## Standard wave-1 allowed-edit classes (S0-repair — apply to this card)

Added after Wave-1 executors correctly BLOCKED (docs/CORE_DECOMPOSITION_PROGRAM.md
§ Wave-1 learnings). ALLOWED here.

### EDIT-CLASS 1 — cross-module imports on MOVED files
Add `import <Dep>` at the top of MOVED files ONLY, where `<Dep>` is a module the destination
target's manifest already declares as a dependency, exactly as the compiler demands.
Enumerate every added line in the PR body. `import OpenBurnBarCore` on a moved file is
FORBIDDEN (inverts layering). P-05 REQUIRED edit: `import OpenBurnBarKernel` on
`HermesAtomNavigator.swift` (for `PlatformLogger`). No other imports.

### EDIT-CLASS 2 — `@testable import OpenBurnBarHermes` on OpenBurnBarCoreTests files
For OpenBurnBarCoreTests files that fail to COMPILE reaching `internal` members of MOVED
files (public symbols resolve via `@_exported`; `@testable`/internal does NOT cross module
boundaries), add `@testable import OpenBurnBarHermes` beneath `@testable import
OpenBurnBarCore`. Do NOT modify test logic/assertions or move test files. Enumerate touched
files in the PR body. Pre-flight candidates listed in V4 above — edit ONLY those V4 proves
reach an internal symbol.
