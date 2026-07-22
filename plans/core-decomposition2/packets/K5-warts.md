# Packet K5: Kernel-diet warts (cleanups the split exposes)
STATE: CONVERGED (shipped as one stacked commit)  LANE: Kernel-diet  DEPENDS-ON: K1–K4
BASELINE-TOUCHING: W4 touches nothing baselined; W1 shrinks LogParsers (−1 file), grows
KernelPlatform to exactly 14/14 files (gate is `>`, so it PASSES). No baseline JSON edit
needed (all ceilings hold with headroom except KernelPlatform files which sit at ceiling).
BASE: origin/core-decomp2/k4 (stacked; PR base core-decomp2/k4).

Four independent cleanups the K0 investigation surfaced. All four landed in ONE packet
commit (K5 is a single stacked PR, not four). Ordering notes per wart.

## CONVERGED REALITY (what actually shipped)
- W1: MOVED `BufferedLineSequence.swift` + extracted the `readAllUTF8Lines()` `FileHandle`
  extension (into new `OpenBurnBarKernelPlatform/FileHandle+UTF8Lines.swift`) DOWN to
  KernelPlatform. Dropped `import OpenBurnBarLogParsers` from `AiderQuotaAdapter.swift`
  (its only LogParsers symbol was `readAllUTF8Lines`, now reached via the Kernel umbrella
  `@_exported import OpenBurnBarKernelPlatform`; Quota does not declare KernelPlatform, so
  no new import is AE-IMPORT-valid — the umbrella covers it). **The `Quota→LogParsers`
  edge is KEPT** — the W1 premise "AiderQuotaAdapter is the SOLE consumer" was FALSE:
  `WarpQuotaAdapter.swift` also calls `WarpParser.extractBodyJSONObjects(from:)` and
  `TimestampNormalizationUtility.date(fromEpoch:)`, both LogParsers-only types. The card's
  own W1 self-guard ("no other Quota file may reference any LogParsers-only type → keep the
  edge, document why") therefore mandates keeping it. Manifest comment updated to record
  this. NOTE on the grep gate: after the move `readAllUTF8Lines` is a KernelPlatform
  primitive, so its CALL still legitimately appears in `AiderQuotaAdapter.swift`; the
  "grep must return ZERO" literal is unsatisfiable-by-design once the method relocates (the
  call must remain) — the edge decision correctly rests on the WarpParser finding, not the
  call-site grep. `BufferedLineSequence` type: ZERO refs in Quota (clean).
- W2: VERIFIED no-op. `OpenBurnBarKernelModels/SharedModels/RGBA.swift` imports only
  Foundation (no SwiftUI); the SwiftUI `Color` bridge lives in `OpenBurnBarUI/SharedModels/
  RGBA.swift` + `OpenBurnBarUI/Views/SwarmCanvasView+Color.swift`. KernelModels ∈ pureTargets
  so the ui-purity gate mechanically enforces zero SwiftUI. No code change.
- W3: VERIFIED KEEP the documented shim. The `extension FileManager: @retroactive
  @unchecked Sendable {}` shim lives in `KernelPlatform/Platform/PlatformSupport.swift`.
  `ProviderQuotaAdapterContext.fileManager` is `public let fileManager: FileManager` (a
  public-API type), and the adapters call an OPEN FileManager surface (`fileExists`,
  `createDirectory`, `enumerator`, `urls`, `homeDirectoryForCurrentUser`,
  `contentsOfDirectory`, plus direct `FileManager` params e.g. `WarpQuotaAdapter
  .candidateLogFiles(in:fileManager:)`). A purpose-built `Sendable` wrapper is NOT mechanical
  and would change public API + weaken nothing — per the card, KEEP the shim. No code change.
  (Note: a purpose-built `Sendable` file abstraction — `SendableFileSystem` — already exists
  in KernelPlatform for NEW call-sites; the legacy FileManager-typed context stays on the shim.)
- W4: RENAMED `SwitcherCLILAunchService` → `SwitcherCLILaunchService` (git mv of the file
  too), added `@available(*, deprecated, renamed:) public typealias SwitcherCLILAunchService`
  for external callers, and repointed EVERY in-tree consumer: 2 AgentLens views
  (`DashboardQuickSwitchView`, `PopoverQuickSwitchView`), 4 `AgentLensTests/Active/*` files
  (incl. the renamed `SwitcherCLILaunchServiceTests` class), 1 `OpenBurnBarCoreTests/
  SwitcherCLIPostLaunchFallbackTests.swift`, and 2 K1/K2 provenance comments
  (`KernelModels/CLILaunchAdapter.swift`, `KernelPlatform/Platform/CLILaunchRedactor.swift`,
  which named the old filename). The card enumerated only the 2 views + 1 Core test; the
  4 AgentLensTests files were additional consumers found by re-grep and repointed too. The
  2 AgentLens views were PROVEN to compile via a full headless `xcodebuild` of the macOS
  `OpenBurnBar` app scheme (BUILD SUCCEEDED) — not CI-deferred.

## W1 — move BufferedLineSequence + readAllUTF8Lines to KernelPlatform, drop the Quota→LogParsers edge
K0 finding: `BufferedLineSequence.swift` (LogParser/) + `FileHandle.readAllUTF8Lines()`
(in `LogParser/LogParserProtocol.swift`) live in `OpenBurnBarLogParsers`. The ONLY
`OpenBurnBarQuota` consumer of them is `ProviderQuota/AiderQuotaAdapter.swift`, and that
single reference is the SOLE reason the manifest carries the `OpenBurnBarQuota →
OpenBurnBarLogParsers` dependency edge (phase-1 P-13 added it explicitly for exactly
this). These are generic UTF-8 line primitives — they belong in the leaf.
- MOVE `BufferedLineSequence.swift` + the `readAllUTF8Lines` extension into
  `OpenBurnBarKernelPlatform` (extract the extension into its own file if it shares a
  file with LogParser-only code — grep `readAllUTF8Lines` first).
- ADD `import OpenBurnBarKernelPlatform` to `AiderQuotaAdapter.swift` (AE-IMPORT) and to
  any LogParsers file that still uses them.
- REMOVE the `"OpenBurnBarLogParsers"` dependency from the `OpenBurnBarQuota` target in
  `OpenBurnBarCore/Package.swift` — BUT FIRST re-grep: `grep -rl
  'BufferedLineSequence\|readAllUTF8Lines' OpenBurnBarCore/Sources/OpenBurnBarQuota` must
  return ZERO after the AiderQuotaAdapter import repoint, AND no other Quota file may
  reference any LogParsers-only type. If any remains → keep the edge, document why.
- VERIFY: whole build + `--target OpenBurnBarQuota` + `--target OpenBurnBarLogParsers` +
  `--target OpenBurnBarKernelPlatform` + swift test + Linux-boundary build.
Ordering: after K1 (KernelPlatform exists). Membership: Platform +2 files (still under 14).

## W2 — RGBA SwiftUI Color bridge → OpenBurnBarUI  [VERIFY-NO-OP: already satisfied]
K0 finding: there is NO SwiftUI file in the OpenBurnBarCore umbrella target, and the
RGBA SwiftUI `Color` bridge ALREADY lives in `OpenBurnBarUI/SharedModels/RGBA.swift`
(plus `OpenBurnBarUI/Views/SwarmCanvasView+Color.swift`). The Kernel's
`SharedModels/RGBA.swift` (28 LOC → KernelModels in K2) is the Foundation-only raw
components (`struct RGBA` for Canvas draw contexts), NO `import SwiftUI`.
- ACTION: verify (no move). Confirm `OpenBurnBarKernelModels/SharedModels/RGBA.swift`
  has no `import SwiftUI` after K2 (the ui-purity gate asserts this — KernelModels is in
  pureTargets). If a future edit adds a SwiftUI bridge to the Models RGBA, THAT is the
  file to relocate to OpenBurnBarUI. As of K0, W2 is a no-op; record the verification.

## W3 — FileManager unchecked-Sendable shim → Sendable wrapper at the use-site
K0 finding: the FileManager `@unchecked Sendable` shim lives in
`OpenBurnBarKernel/Platform/PlatformSupport.swift` (→ KernelPlatform in K1) and is used
across `OpenBurnBarQuota/ProviderQuota/*` (ClaudeOAuthUsageFetcher, XAIQuotaAdapter,
StubQuotaAdapter, ZAIQuotaAdapter, …) + `OpenBurnBarLogParsers/LogParser/ParserDiskCache.swift`.
The task's target is the `ProviderQuotaAdapterContext` use-site.
- ACTION: at the `ProviderQuotaAdapterContext` construction site, replace the shared
  unchecked-Sendable FileManager with a purpose-built `Sendable` wrapper (a value type
  holding only the paths/closures the adapters actually need) IF mechanical. Grep the
  adapter context's FileManager surface first; if the adapters call arbitrary
  FileManager API, a full Sendable wrapper is not mechanical → KEEP the documented shim
  and record why (do not weaken concurrency for convenience).
- VERIFY: `--target OpenBurnBarQuota` + swift test under Swift 6 strict concurrency;
  no new data-race diagnostics.
Ordering: after K1 (shim lives in KernelPlatform).

## W4 — rename SwitcherCLILAunchService → SwitcherCLILaunchService (+ deprecated typealias)
K0 finding: the typo'd type `SwitcherCLILAunchService` (capital-A "LAunch") lives in
`OpenBurnBarCore/Sources/OpenBurnBarLaunchServices/SwitcherCLILAunchService.swift`.
Consumers of the typo'd name (grep, 20 total refs across repo):
- `AgentLens/Views/Popover/PopoverQuickSwitchView.swift`
- `AgentLens/Views/Dashboard/Components/DashboardQuickSwitchView.swift`
- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/SwitcherCLIPostLaunchFallbackTests.swift`
- (the defining file itself)
- `OpenBurnBarKernel/Platform/CLILaunchAdapter.swift` +
  `OpenBurnBarKernel/Platform/CLILaunchRedactor.swift` — VERIFY these are substring
  matches on `CLILaunch*` (the Redactor/Adapter), NOT the typo'd service; exclude if so.
ACTION:
- `git mv` the file to `SwitcherCLILaunchService.swift`; rename the TYPE to
  `SwitcherCLILaunchService` throughout.
- ADD `@available(*, deprecated, renamed: "SwitcherCLILaunchService") public typealias
  SwitcherCLILAunchService = SwitcherCLILaunchService` so external callers keep
  compiling (belt-and-suspenders; then repoint the 2 AgentLens views + the test).
- Repoint the enumerated consumers to the corrected name.
- VERIFY: whole build + swift test + AgentLens builds (the 2 views compile).
Ordering: independent of K1–K4 (LaunchServices is a separate target); can land anytime.

## Validation (per-wart)
Each wart runs the subset of the K1 V-list relevant to the targets it touches, plus a
scope-diff. None may PR from a red tree. W1/W3 must show no new Swift-6 concurrency
diagnostics; W4 must keep AgentLens green.
