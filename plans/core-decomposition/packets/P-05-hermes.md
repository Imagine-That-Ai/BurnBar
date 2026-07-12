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

## Shim
None. `@_exported import OpenBurnBarHermes` already exists in
`OpenBurnBarHermesReexport.swift` (S0). Do NOT edit it.

## Forbidden actions
Standard.

## Enumerated semantic edits
None expected (Hermes types are consumed by AgentLens/Mobile via the umbrella →
already `public`).

## Pre-flight checks
1. Path-pin grep of `Hermes/HermesAtom.swift` and `Hermes/` over the automation roots.
   NOTE: a grep for `/Hermes/` hits `OpenBurnBarMobile/Services/Hermes/...` — that is a
   DIFFERENT tree (the mobile app), NOT the Core `Hermes/` dir. Ignore mobile hits.
   Expected Core-path hits: NONE.
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: `Hermes/` not in excludes. No Package.swift edit.
4. Not a CANON packet.

## Local validation
V1 `swift build --target OpenBurnBarHermes` · V2 Core build · V3 PURE · V4 test ·
V5 daemon build · V6–V9b ratchets (membership shrink) · V11 scope (7 R100, 1 D marker).

## PR body / Acceptance
Title: "P-05: move Hermes/ into OpenBurnBarHermes". Invariants: zero call-site
changes (@_exported shim), Foundation-only, no exclude edits. A1–A6.
