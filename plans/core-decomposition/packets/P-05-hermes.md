# Packet P-05: move Hermes/ → OpenBurnBarHermes
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none

`Hermes/` is 7 Foundation-only files (verified). Whole-directory move.

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
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): **REQUIRED in this
  packet** — `HermesAtomNavigator.swift` constructs `PlatformLogger(subsystem:…,
  category:…)` (its line 31: `private let logger = PlatformLogger(...)`), and
  `PlatformLogger` is a platform-support symbol (`OpenBurnBarPlatformSupport/PlatformSupport.swift`,
  `public struct PlatformLogger: Sendable`). Inside the old Core target it resolved
  without an import; in the `OpenBurnBarHermes` target it does NOT (Hermes declares
  `OpenBurnBarKernel` as a dep but the source must still import it). So ADD `import
  OpenBurnBarKernel` at the top of `HermesAtomNavigator.swift` (beneath `import
  Foundation`), and to any other moved Hermes file the V1 build flags for a Kernel
  symbol. Enumerate every added line in the PR body. Never `import OpenBurnBarCore`.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarHermes` beneath the
  existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  Hermes symbol. Anticipated: `HermesAtomParserTests.swift`,
  `HermesInlineMarkdownTests.swift`, `HermesSourceLinkExtractorTests.swift`. Add ONLY
  where compile fails; enumerate in the PR body.

## Shim
None. `@_exported import OpenBurnBarHermes` already exists in
`OpenBurnBarHermesReexport.swift` (S0). Do NOT edit it.

## Forbidden actions
Standard.

## Enumerated semantic edits
FALSE-PREMISE CORRECTION (S0-repair FIX 2): the original card claimed "None expected"
because Hermes types are `public`. That is true for the type VISIBILITY, but the MOVE
still needs one cross-module import: `HermesAtomNavigator.swift` references
`PlatformLogger` from the Kernel, which is UN-imported inside the Hermes target.
`PlatformLogger` is ALREADY `public` in the Kernel
(`OpenBurnBarPlatformSupport/PlatformSupport.swift`) — verified at S0-repair — so NO
one-line public change is required in the Kernel; the ONLY edit is the AE-IMPORT
`import OpenBurnBarKernel` line above. Everything else is Foundation-only (verified).

## Pre-flight checks
1. Path-pin grep of `Hermes/HermesAtom.swift` and `Hermes/` over the automation roots.
   NOTE: a grep for `/Hermes/` hits `OpenBurnBarMobile/Services/Hermes/...` — that is a
   DIFFERENT tree (the mobile app), NOT the Core `Hermes/` dir. Ignore mobile hits.
   Expected Core-path hits: NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `Hermes/` not in excludes. No Package.swift edit.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarHermes` (this build DEMANDS the `import
OpenBurnBarKernel` on HermesAtomNavigator.swift — expect a "cannot find PlatformLogger
in scope" error until it is added) · V2 Core build · V3 PURE · V4 test (with any
AE-TESTABLE lines) · V5 daemon build · V6–V9b ratchets (membership shrink) · V11 scope
(7 R100, 1 D marker, at least 1 content-M on HermesAtomNavigator.swift for the required
`import OpenBurnBarKernel`, plus any enumerated AE-TESTABLE test-file M's).

## PR body / Acceptance
Title: "P-05: move Hermes/ into OpenBurnBarHermes". Invariants: zero call-site
changes (@_exported shim), Foundation + one enumerated `import OpenBurnBarKernel`
(HermesAtomNavigator uses Kernel's public PlatformLogger), no exclude edits. Enumerate
the AE-IMPORT + AE-TESTABLE lines. A1–A6.
