# Packet K5: Kernel-diet warts (cleanups the split exposes)
STATE: DRAFT  LANE: Kernel-diet  DEPENDS-ON: K1–K4 (each wart lands after its target exists)
BASELINE-TOUCHING: W4 touches nothing baselined; W1 may shrink a manifest edge.
BASE: origin/main (after the relevant K packet merges)

Four independent cleanups the K0 investigation surfaced. Each is its own small commit/
PR — they do NOT block K1–K4. Ordering notes per wart.

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
