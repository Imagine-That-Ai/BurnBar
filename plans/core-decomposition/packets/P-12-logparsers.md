# Packet P-12 (DRAFT): move Services/LogParser + LogPath (+2 log-discovery models) → OpenBurnBarLogParsers
STATE: QUEUED
LANE: B          DEPENDS-ON: S0, P-01 (SQLiteReader), P-02 (Kernel catalog for ModelPricing)
BASELINE-TOUCHING: none

`Services/LogParser/` (23 files) + `Services/LogPath/` (2 files) +
`SharedModels/AgentProvider+LogDirectory.swift` + `SharedModels/AgentProviderLogDiscovery.swift`.
5 parsers (Windsurf/ForgeDev/Goose/Hermes/Codex) use `SQLiteConnection` → depends on
SQLiteReader (P-01). `ModelPricing.swift`'s `BurnBarCatalogLoader.loadBundledCatalog()`
resolves against Kernel's bundle (P-02). `OpenBurnBarCatalogLookup` is a `private struct`
inside `ModelPricing.swift` — rides along for free.

## Scope (TO-ENUMERATE-AT-WAVE)
### git mv list
Whole `Services/LogParser/` (23) + `Services/LogPath/` (2) into
`OpenBurnBarLogParsers/`, plus the 2 SharedModels log-discovery files. Enumerate each
`.swift` at execution; verify each exists. Remove `OpenBurnBarLogParsers/ModuleMarker.swift`.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (none of these paths is in
  `openBurnBarCoreExcludes`; verify at execution — the LogParser cluster compiles
  off-Apple today). If a file IS excluded, add it to `openBurnBarLogParsersExcludes`.
- **AE-IMPORT / AE-TESTABLE** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): EXPECTED
  here. The 5 SQLite-backed parsers (Windsurf/ForgeDev/Goose/Hermes/Codex) reference
  `SQLiteConnection` (an `OpenBurnBarSQLiteReader` symbol post-P-01) and `ModelPricing`
  resolves `BurnBarCatalogLoader` (a Kernel symbol post-P-02), so those moved files need
  `import OpenBurnBarSQLiteReader` and/or `import OpenBurnBarKernel` — add exactly what
  V1 demands (both are declared deps of `OpenBurnBarLogParsers`); never `import
  OpenBurnBarCore`. Add `@testable import OpenBurnBarLogParsers` beneath the existing
  `@testable import OpenBurnBarCore` in any Core parser test reaching an INTERNAL moved
  symbol. Enumerate every added line/file in the PR body.

## Slice-specific validation (byte-identical parser output)
- `swift run OpenBurnBarG2ParserParity`
- `swift run OpenBurnBarWindowsParserPathParity`
- `swift run OpenBurnBarWalkingSkeleton`
All three must be byte-identical to their goldens (these parity executables keep the
OpenBurnBarCore dep — the umbrella covers them, NO manifest change). Plus V1–V11.
Parity executables' PATH codec (ClaudeCodeProjectPathCodec) moves with LogPath.

## Pre-flight
Path-pin grep of `Services/LogParser`, `Services/LogPath` → NONE (verified at S0).
Bundle.module over mv list → EMPTY (catalog resolution is via Kernel loader, not
Bundle.module in these files). Not a CANON packet.

## PR / Acceptance
Title: "P-12: move Services/LogParser + LogPath into OpenBurnBarLogParsers". Invariants:
byte-identical parser output (3 parity runs), depends on SQLiteReader + Kernel, zero
call-site changes. A1–A6.
