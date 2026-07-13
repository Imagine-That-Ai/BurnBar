# Packet P-15b: extract the pure CLI-launch resolution surface → OpenBurnBarKernel
STATE: PR-OPEN (core-decomp/p-15b, base core-decomp/wave3-base) — PR #1648
LANE: A          DEPENDS-ON: S0, P-15 (LaunchServices; the file this splits already
lives in `OpenBurnBarLaunchServices/`, and `SwitcherProfile.swift` is already in Kernel)
BASELINE-TOUCHING: none (Kernel stays UI-purity assert-zero; no `--update`)

NEW predecessor packet for **P-13 (Quota)** and **P-18 (daemon/CLI repoint)** — both were
BLOCKED pending "the CLI-launch cluster extraction" (see the P-13/P-18 lane stashes). Two
consumers verified in-tree:
1. **Daemon repoint (P-18).** `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarSwitcherShell.swift:703`
   calls `CLILaunchAdapter.buildCLILaunch(profile:)` in `shellConfiguration(...)` —
   UNGUARDED (no `#if os(macOS)`; the macOS switcher shell is Linux-excluded via
   `daemonExcludes`, so this path is macOS-only at build time). When P-18 repoints the
   daemon off the `OpenBurnBarCore` umbrella onto the UI-free `OpenBurnBarEngine`, the
   daemon must reach the executable-resolution + launch-build surface WITHOUT linking
   the AppKit-adjacent, Apple-only `OpenBurnBarLaunchServices`. Engine re-exports Kernel,
   so homing the adapter in Kernel is what makes the repoint possible.
2. **Quota adapters (P-13).** `OpenBurnBarCore/Sources/OpenBurnBarCore/ProviderQuota/OMPQuotaAdapter.swift`
   (`.omp`) and `CodexQuotaAdapter.swift` (`.codex`) call
   `CLILaunchAdapter.{resolveExecutable, resolvePinnedExecutable, buildAllowlistedBaselineEnvironment,
   trustedExecutableEnvironmentPath}` (each `#if os(macOS)`-gated). P-13 moves
   `ProviderQuota/` into `OpenBurnBarQuota` (deps: Kernel, SQLiteReader, crypto — NOT
   LaunchServices), so those adapters lose the LaunchServices re-export and need the
   adapter in a target Quota already depends on = Kernel.

## Scope (ENUMERATED + CONVERGED via compile-closure)
This is a FILE SPLIT (not a whole-file `git mv`): the pure surface becomes a NEW Kernel
file; the launch-coordinator / process-invoker / profile-store-coupled half STAYS in
`SwitcherCLILAunchService.swift` (LaunchServices). Pure code motion, zero behavior change.

### New file
- `OpenBurnBarCore/Sources/OpenBurnBarKernel/Platform/CLILaunchAdapter.swift` (NEW) —
  the Foundation-pure `public enum CLILaunchAdapter` (executable resolution, pinned
  resolution, trusted-path env building, allowlisted-baseline env, arg/env/profile
  validation, launch-config construction) + `public enum CLILaunchError` (its validation
  surface returns it — symbol closure requires it move too, since it cannot stay ABOVE
  the Kernel while the moved adapter references it). Extracted verbatim from
  `SwitcherCLILAunchService.swift` lines 26–844 (adapter) + 850–932 (error). The
  `#if os(macOS)` guard is preserved: the resolver is macOS launch semantics and every
  consumer already gates on `#if os(macOS)` (Quota adapters) or an all-macOS build
  (LaunchServices, daemon macOS leg), so off-Apple the type simply does not exist —
  byte-identical to before. Kernel-internal symbols (`Locked`, `SwitcherCLIProfileType`,
  `SwitcherProfileRecord`, `SwitcherProfileTargetKind`, `SwitcherCLIProfileMetadata`)
  resolve same-module. `import Foundation` only — the vestigial `#if canImport(AppKit)
  import AppKit` from the origin file is dropped (the adapter uses ZERO AppKit symbols;
  machine-verified over the whole origin file — only `NSHomeDirectory`/`NSTemporaryDirectory`,
  which are cross-platform Foundation).

### Modified files
- `OpenBurnBarCore/Sources/OpenBurnBarLaunchServices/SwitcherCLILAunchService.swift`
  (−940 lines): the `CLILaunchAdapter` + `CLILaunchError` blocks removed; the staying
  half (`CLILaunchCoordinator`, `CLILaunchInvoker`, `SwitcherCLILAunchService`,
  `CLIFallback*`, `CLILaunchServiceEvent`, `CLILaunchOutcome`, `CLILaunchRedactor`,
  `QuotaSignalRecorder`, `LaunchObservationCleanup`) kept intact under its existing
  `#if os(macOS)` guard. It already `import OpenBurnBarKernel`, so it reaches the moved
  adapter/error through LaunchServices' declared Kernel dependency — NO new import. The
  now-truly-unused `#if canImport(AppKit) import AppKit` is removed (staying code uses
  zero AppKit symbols; verified). File shrinks 1803 → 887 LOC.
- **Package.swift — NONE.** The Kernel target globs `Sources/OpenBurnBarKernel/`
  (no `sources:`/`exclude:`), so the new `Platform/CLILaunchAdapter.swift` is auto-included.
  LaunchServices keeps every file it had (the split file stays). No target/dep edit.

### P-12 FOLLOW-UP (side-finding fix, documented in the P-13 card BLOCKED section)
P-12 moved the `FileManager: @retroactive @unchecked Sendable` shim out of Core into
`OpenBurnBarLogParsers/LogParser/ParserDiskCache.swift`. Core's
`ProviderQuotaAdapterContext` (`ProviderQuota/ProviderQuotaAdapter.swift:14`, a `Sendable`
struct with `public let fileManager: FileManager`) then saw the conformance ONLY
transitively via Core's `@_exported import OpenBurnBarLogParsers` — a split-brain that
fails Swift-6 Sendable checking in build modes where the re-exported retroactive
conformance is not propagated, and would break outright when P-13 moves the adapters into
`OpenBurnBarQuota` (which does not depend on LogParsers). FIX (minimal, architecturally
correct): home the `FileManager` shim in the Kernel — the common ancestor of Core, Quota,
and LogParsers — in `Platform/PlatformSupport.swift` (alongside the existing crypto
`@retroactive @unchecked Sendable` shims), UNGUARDED (`FileManager` is not `Sendable` on
any platform, unlike the `#if os(Linux) || os(Windows)` crypto shims). Then remove the
`FileManager` line from `ParserDiskCache.swift` and add `import OpenBurnBarKernel` there so
it inherits the conformance (its `UserDefaults`/`NSDictionary`/`KeyPath` shims stay). Now
`ProviderQuotaAdapterContext` sees `FileManager: Sendable` via Core's
`@_exported import OpenBurnBarKernel`, LogParsers inherits it, and P-13's future
`OpenBurnBarQuota` gets it via its Kernel dep. Single declaration → no redundant
conformance. `foundation-sdk-shim` token preserved (unchecked-Sendable gate stays 0/66).

### AE-IMPORT (compile-driven)
- `import OpenBurnBarKernel` added to `OpenBurnBarLogParsers/LogParser/ParserDiskCache.swift`
  (P-12 follow-up: to see the Kernel-homed `FileManager: Sendable`). The new Kernel file
  imports Foundation only (same-module for all Kernel symbols). The staying LaunchServices
  file needs NO new import (already `import OpenBurnBarKernel`). Never `import OpenBurnBarCore`.

### AE-TESTABLE (compile-driven — the ACTUAL set the compiler demanded)
`@testable import OpenBurnBarKernel` added beneath the existing testable imports in the
2 Core-package tests reaching INTERNAL adapter seams now in Kernel
(`environmentProvider`/`homeDirectoryProvider`/`trustedExecutableSearchDirectories`/
`allowsAmbientUserManagedExecutableFallback`/`ambientFallbackExecutableSearchDirectories`):
- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CLILaunchAdapterExecutableResolutionTests.swift`
- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CLIAuthDiscoveryTests.swift`
`CLILaunchInvokerTests` (invoker internals stay in LaunchServices — already has its
`@testable`) and `SwitcherCLIPostLaunchFallbackTests` (public-only) compile unchanged.
**AgentLens tests: NO change** — mirroring P-15's precedent exactly (P-15 moved this
adapter Core→LaunchServices and modified ONLY the 5 Core-package tests, leaving
`AgentLensTests/Active/SwitcherCLILaunchTests.swift` — which reaches the same internal
seams — untouched; the Xcode app-test target reaches leaf-target internals through
`@testable import OpenBurnBarCore`/`OpenBurnBar`, unaffected by which package target
hosts the enum). Public adapter members flow to all app/test consumers via the
`@_exported` umbrella.

## Validation (RESULTS, macOS host — Swift 6.4 / Xcode 27 beta)
- swift build --target OpenBurnBarKernel → Build complete (adapter+error closed over Foundation+Kernel)
- swift build --target OpenBurnBarLogParsers → Build complete (inherits FileManager:Sendable from Kernel)
- swift build --target OpenBurnBarLaunchServices → Build complete (staying half; adapter/error via Kernel)
- swift build --target OpenBurnBarCore → Build complete (ProviderQuotaAdapterContext sees FileManager:Sendable via Kernel)
- swift build --target OpenBurnBarEngine → Build complete
- swift build --target OpenBurnBarDaemon (separate pkg, macOS leg) → Build complete
  (DAEMON PROOF: `OpenBurnBarSwitcherShell.buildCLILaunch` resolves CLILaunchAdapter via Core→Kernel)
- swift build --build-tests + swift test → all XCTest bundles + swift-testing PASS, 0 failures
  (incl. CLILaunchAdapterExecutableResolutionTests, CLIAuthDiscoveryTests, ProviderQuota* suites)
- swift build --build-tests (OpenBurnBarDaemon pkg) → Build complete
  (OpenBurnBarSwitcherShellTests compiles against CLILaunchAdapter via umbrella→Kernel)
- OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1 swift build --target OpenBurnBarCore → Build complete
  (off-Apple graph consistent; adapter `#if os(macOS)` vanishes; quota calls are `#if os(macOS)`-gated;
   true Linux leg CI-covered)
- core-target-membership gate → OK (Kernel `planned` ceiling accommodates the new file; main shrink non-fatal)
- core-ui-purity gate → OK (baselined=109 live=109; Kernel assert-zero — new file is Foundation-only)
- core-umbrella-imports gate → OK (no new umbrella imports; daemon still 203 — repoint is P-18)
- unchecked-sendable gate → OK (ratchet 0/66; FileManager shim relocated Kernel-ward, foundation-sdk-shim kept)
- mission-splitbrain gate → OK (11 files/3694 lines, no drift)
- swift-file-size gate → OK (new file 938 LOC < 2000; staying file 1803 → 887)

## Pre-flight
PATH-PIN sweep (learning 5): `git grep -n "SwitcherCLILAunchService\|CLILaunchAdapter.swift\|Platform/CLILaunchAdapter"
-- .github scripts packages tools CODEOWNERS .swiftlint.yml project.yml website` → NONE
(this packet splits an already-moved file + adds a new Kernel file; no path-pinned path moves).
Bundle.module over the moved code → EMPTY. Not a CANON packet (canon reads only
`OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift` + generated; this adds a Platform/ file).

## PR / Acceptance — PR #1648
Title: "P-15b: extract Foundation-pure CLILaunchAdapter surface into OpenBurnBarKernel
(+ P-12 FileManager Sendable follow-up)". Base core-decomp/wave3-base. Label codex.
Invariants: pure code motion, zero behavior change, zero call-site changes; Kernel stays
UI-purity assert-zero; the adapter is AppKit-free (Kernel purity proven); the daemon +
Quota consumers reach it via Kernel; the P-12 split-brain is closed at the Kernel layer.
A1–A6.
