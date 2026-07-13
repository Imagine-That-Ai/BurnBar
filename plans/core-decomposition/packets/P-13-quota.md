# Packet P-13: move ProviderQuota + XAISuperGrokPacingLog → OpenBurnBarQuota
STATE: PR_OPEN (#1652, base core-decomp/p-15b) — see "EXECUTED" section below
LANE: C          DEPENDS-ON: S0, P-01 (SQLiteReader), P-12 (Kernel Identity/AppPaths +
FileManager Sendable shim), P-15b (Kernel CLILaunchAdapter surface + SwitcherProfile)
BASELINE-TOUCHING: none

`ProviderQuota/` (41 files) + root `XAISuperGrokPacingLog.swift` (which
`ProviderQuota/XAISuperGrokUsageLog.swift` calls, so it moves INTO Quota). 3 quota
adapters use `SQLiteConnection` → depends on SQLiteReader (P-01). NO LogParsers edge
(verified zero refs — the "Quota→Views/LogParser refs" were stale nested-type name
collisions). 18 files use `canImport(FoundationNetworking)` → the Linux-boundary build
is the key check.

## Scope (TO-ENUMERATE-AT-WAVE)
### git mv list
Whole `ProviderQuota/` into `OpenBurnBarQuota/ProviderQuota/` (or flatten — decide at
execution to minimize churn; whole-dir move preferred) + root
`XAISuperGrokPacingLog.swift` → `OpenBurnBarQuota/XAISuperGrokPacingLog.swift`.
Enumerate + verify each. Remove `OpenBurnBarQuota/ModuleMarker.swift`.

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (`ProviderQuota/` not in
  `openBurnBarCoreExcludes`; it compiles off-Apple today via FoundationNetworking guards).
  If a Quota file is excluded, add to `openBurnBarQuotaExcludes`.
- **AE-IMPORT / AE-TESTABLE** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): EXPECTED
  here. The 3 SQLite-backed quota adapters reference `SQLiteConnection` (an
  `OpenBurnBarSQLiteReader` symbol post-P-01) and Quota references Kernel/crypto symbols,
  so those moved files need `import OpenBurnBarSQLiteReader` and/or `import
  OpenBurnBarKernel` — add exactly what V1 demands (both are declared deps of
  `OpenBurnBarQuota`); never `import OpenBurnBarCore`. Add `@testable import
  OpenBurnBarQuota` beneath the existing `@testable import OpenBurnBarCore` in any Core
  quota test reaching an INTERNAL moved symbol. Enumerate every added line/file in the
  PR body.

## Slice-specific validation
- Linux-boundary build (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build`) — the
  FoundationNetworking guards must keep the off-Apple graph valid.
- `ProviderQuotaMacParity` harness runner (grep for it at execution; keep green).
- V1–V11. Document in the PR body: "verified zero Quota→Views/LogParser refs".

## Pre-flight
Path-pin grep of `ProviderQuota`, `XAISuperGrokPacingLog.swift` → NONE (verified at S0).
Bundle.module → EMPTY. Not a CANON packet.

## PR / Acceptance
Title: "P-13: move ProviderQuota into OpenBurnBarQuota (the K3 Quota redo)". Invariants:
depends on SQLiteReader + Kernel + crypto, NO LogParsers edge, zero call-site changes.
A1–A6.

## BLOCKED(re-slice) — wave-3 attempt (2026-07-13, base core-decomp/p-12-w2)

The prior-blocker (`OpenBurnBarAppPaths`/`OpenBurnBarIdentity` now in Kernel via P-12) is
resolved. The whole-dir `git mv` (41 `ProviderQuota/` + root `XAISuperGrokPacingLog.swift`,
marker removed) was executed and full compile-closure (`swift build --target
OpenBurnBarQuota`, package-default Swift v6) was run to exhaustion. Compile-closure
resolved the anticipated AE-IMPORT set (27 files `import OpenBurnBarKernel`; 3 files
`import OpenBurnBarSQLiteReader`: `OpenBurnBarQuotaAdapters`, `CursorCookieExtractor`,
`ForgeQuotaAdapter`) plus one closure-forced Foundation SDK shim (see below), then
surfaced **THREE non-import cross-layer edges the DRAFT card's premise missed**. The
first is mechanical; the other two need architect re-slicing, so the packet is
`BLOCKED(re-slice)` — reverted to a pristine, green base (`git stash push -u`; base
Quota marker target builds clean).

1. **FileManager Sendable shim left Core via P-12 (mechanical, fixed in-attempt).**
   `ProviderQuotaAdapter.ProviderQuotaAdapterContext` is a `Sendable` struct with a stored
   `FileManager`. The `extension FileManager: @retroactive @unchecked Sendable {}` SDK
   shim was co-located with ProviderQuota inside Core (`Services/LogParser/
   ParserDiskCache.swift`) until **P-12** moved it into `OpenBurnBarLogParsers` — a leaf
   Quota does NOT depend on — so v6 errors `stored property 'fileManager' … has
   non-Sendable type 'FileManager'`. A `@retroactive @unchecked Sendable` conformance is a
   per-module SDK shim; the resolution is a new
   `OpenBurnBarQuota/QuotaFoundationSendableShims.swift` carrying the FileManager shim with
   the registered `sendable-allowlist: foundation-sdk-shim` token (only FileManager is used
   in a Sendable context here; UserDefaults/NSDictionary/KeyPath are not). NOTE for the
   architect: **P-12 already made Core's own `ProviderQuotaAdapter` fail this v6 check on
   the base branch** (the shim left Core but the adapter did not) — this is a latent P-12
   regression the parity executables' whole-program link masked.

2. **Core edge — `CLILaunchAdapter` + `SwitcherCLIProfileType` (re-slice needed).**
   `CodexQuotaAdapter.swift` and `OMPQuotaAdapter.swift` call
   `CLILaunchAdapter.{resolveExecutable,resolvePinnedExecutable,
   buildAllowlistedBaselineEnvironment,trustedExecutableEnvironmentPath}` and pass
   `SwitcherCLIProfileType` cases `.codex`/`.omp`. `CLILaunchAdapter` is defined in
   `OpenBurnBarCore/SwitcherCLILAunchService.swift` and `SwitcherCLIProfileType` in
   `OpenBurnBarCore/SwitcherProfile.swift` — both Core-resident. `import OpenBurnBarCore`
   is FORBIDDEN (inverts layering). The whole `SwitcherCLILAunchService.swift` file cannot
   move down (it also defines `SwitcherCLILAunchService`/`CLILaunchCoordinator`/
   `CLILaunchInvoker` referencing `SwitcherProfileRecord`/`SwitcherCLIProfileMetadata`/
   Switcher store types). Architect options: (a) extract `CLILaunchAdapter`'s pure
   executable-resolution + env-baseline surface (+ `SwitcherCLIProfileType`, which
   `CLILaunchAdapter.configEnvironmentKeys`/`trustedExecutablePaths` also need) into a
   Kernel/Quota-visible layer; or (b) leave `CodexQuotaAdapter`/`OMPQuotaAdapter` in Core
   (file-leaves-slice) until a successor packet lands the extraction.

3. **LogParsers edge — `FileHandle.readAllUTF8Lines()` / `BufferedLineSequence`
   (re-slice needed; INVALIDATES the card's "NO LogParsers edge" invariant).**
   `AiderQuotaAdapter.swift:56` (`for line in handle.readAllUTF8Lines()`) uses the `public
   extension FileHandle { func readAllUTF8Lines() -> BufferedLineSequence }` defined in
   `OpenBurnBarLogParsers/LogParser/LogParserProtocol.swift`; the return type
   `BufferedLineSequence` is also LogParsers-resident
   (`OpenBurnBarLogParsers/LogParser/BufferedLineSequence.swift`). `OpenBurnBarQuota`
   declares deps `[Kernel, SQLiteReader, swift-crypto]` — NOT LogParsers — and a move
   packet must not add a manifest dependency edge (AE-IMPORT STOP rule). The card's
   central claim "**NO LogParsers edge (verified zero refs)**" is FALSE: the prior grep
   matched only the literal string `LogParser`, missing the *method-name* reference
   `.readAllUTF8Lines()`. Architect options: (a) add `OpenBurnBarLogParsers` as a declared
   Quota dep (would NOT cycle — LogParsers deps are `[Kernel, SQLiteReader]`); or (b)
   re-slice `AiderQuotaAdapter` to a local line reader; or (c) hoist
   `BufferedLineSequence`+`readAllUTF8Lines` into a shared lower layer both leaves import.

Evidence is preserved in the wave-3 lane stash (`P-13-w3 BLOCKED(re-slice): …`). No PR
opened (red tree). Card stays `QUEUED` pending an architect re-slice of edges 2 and 3.

## EXECUTED — third attempt, PR #1652 (2026-07-13, base core-decomp/p-15b)

All three BLOCKED edges resolved upstream/by architect authorization; shipped as PR
**#1652** (stacks on P-15b PR #1648). Branch `core-decomp/p-13-final`.

**Edge resolutions:**
1. **FileManager Sendable shim (was "mechanical, fixed in-attempt").** ALREADY resolved
   before this attempt: a P-12 follow-up homed `extension FileManager: @retroactive
   @unchecked Sendable {}` in `OpenBurnBarKernel/Platform/PlatformSupport.swift` (its
   comment names "the future `OpenBurnBarQuota` target"). Quota deps → Kernel, so `import
   OpenBurnBarKernel` carries the conformance. The card's proposed new
   `QuotaFoundationSendableShims.swift` was **obsolete — not created**.
2. **CLILaunchAdapter + SwitcherCLIProfileType (edge 2).** Resolved by **P-15b**: both are
   now `public` in Kernel (`Platform/CLILaunchAdapter.swift`, `SharedModels/
   SwitcherProfile.swift`) and gone from Core. `CodexQuotaAdapter`/`OMPQuotaAdapter`
   resolve them via `import OpenBurnBarKernel`. **No file-leaves-slice** — both moved and
   compile clean in Quota.
3. **LogParsers edge (edge 3) — INTEGRATOR-AUTHORIZED MANIFEST EDIT.** Added
   `OpenBurnBarLogParsers` to `OpenBurnBarQuota` dependencies. The DRAFT "NO LogParsers
   edge" invariant was FALSE. Compile-closure found **TWO** consumers (card knew one):
   `AiderQuotaAdapter` (`FileHandle.readAllUTF8Lines()`→`BufferedLineSequence`) **and**
   `WarpQuotaAdapter` (`WarpParser`, `TimestampNormalizationUtility`). Acyclic (LogParsers
   deps = `[Kernel, SQLiteReader]`).

**Moved:** whole `ProviderQuota/` (41 files) + root `XAISuperGrokPacingLog.swift` →
`OpenBurnBarQuota/`; deleted `OpenBurnBarQuota/ModuleMarker.swift`. **42 `.swift` in the
target.** `ProviderQuotaMacParity.swift` is an in-target `ProviderQuotaAdapterContext`
convenience extension (NOT an external harness — grep confirmed no CI/runner) and moved
with the target.

**AE-IMPORT (compile-driven, exhausted):** `import OpenBurnBarKernel` ×25;
`import OpenBurnBarSQLiteReader` ×3 (`OpenBurnBarQuotaAdapters`, `CursorCookieExtractor`,
`ForgeQuotaAdapter`); `import OpenBurnBarLogParsers` ×2 (`AiderQuotaAdapter`,
`WarpQuotaAdapter`). Zero `import OpenBurnBarCore`. Prior card predicted 27 Kernel;
compile truth is **25** (P-15b extraction + real symbol closure).
**AE-TESTABLE:** only `ZAIQuotaAdapterTests` broke (internal `zaiUsageQueryItems(now:)`)
→ `@testable import OpenBurnBarQuota` + `OpenBurnBarQuota` on the `OpenBurnBarCoreTests`
target.

**Zero call-site changes for umbrella consumers** (AgentLens, Mobile, daemon): Core's
`OpenBurnBarQuotaReexport.swift` `@_exported import`s Quota and propagates transitively
across the package boundary — proven by a clean daemon build with NO daemon edit. The
Engine `@_exported import OpenBurnBarQuota` line is now real (P-17 #1641 documented Quota
marker-only).

**V-list (macOS Swift 6.4, sandboxed offline):** `swift build --target OpenBurnBarQuota`
clean; full default `swift build` clean; Linux-boundary `swift build` (Engine+Core,
separate scratch) clean; whole-package `swift test` 0 failures (11 xctest + 42
swift-testing); daemon `swift build --target OpenBurnBarDaemon` clean (856 modules); the
3 SPM parity/skeleton execs clean; regrowth gates green (membership shrink non-fatal,
umbrella-imports OK, ui-purity OK — Quota in pureTargets). Membership-baseline
ratchet-down remains a separate integrator JSON-only PR (non-fatal shrink).
