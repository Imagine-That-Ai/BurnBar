# Packet P-04a: move pure SharedModels (incl. CloudVaultCrypto) → OpenBurnBarKernel
STATE: CONVERGED (PR open) — see "Convergence update (integrator, 2026-07-12)" below.
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none

First of the two dependency-closed S4 halves. These are Foundation-only SharedModels
that are NOT in `openBurnBarCoreExcludes` today (they already compile off-Apple), so
this packet edits ZERO Package.swift exclude lines. CloudVaultCrypto is included here
(it is pure Foundation crypto and the P-04b crypto chain depends on it — moving it
first lets P-04b reference it from Kernel).

> **Convergence update (integrator, compile-based closure, 2026-07-12).** The
> original 12-file list did NOT achieve Kernel compile-closure; the compiler surfaced
> three symbol deps grep missed (RGBA, CardEnvelope, SubstrateCatalog) AND a resource
> loader dep (BurnBarCatalogLoader) that forces two files out of this slice. The
> converged slice ships **10 of the 12** carded files + one option-b move
> (`Views/Cards/CardEnvelope.swift`) + one option-c extraction (Kernel `RGBA.swift`),
> removes the redundant `LinuxCardEnvelope.swift` stub, and re-slices
> `CLIRuntimeModelCatalog.swift` + `WandModelRouter.swift` OUT (they depend on P-02's
> resource-backed catalog loader — see the "RE-SLICED OUT" block below). The mv list
> and semantic edits here reflect the CONVERGED (shipped) slice.

## Scope — the ONLY files you may touch

### git mv list (CONVERGED — the 10 that achieve Kernel compile-closure today)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderRuntimeFailoverTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/ProviderRuntimeFailoverTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubscriptionTopic.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubscriptionTopic.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/UIMode.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/UIMode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesSquareFeatureFlags.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesSquareFeatureFlags.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxSubstrateSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxSubstrateSupport.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubstrateFamily.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubstrateFamily.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AskAssistantIntent.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AskAssistantIntent.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AssistantPendingPrompt.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AssistantPendingPrompt.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/Views/Cards/CardEnvelope.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CardEnvelope.swift
```

### Compile-closure convergence edits (semantic, beyond the raw git mv)
- **RGBA (option-c, minimal extraction).** `SubstrateFamily`/`FamilyAccent` reference
  the `RGBA` value type. `SharedModels/RGBA.swift` was Foundation-pure EXCEPT a
  `#if canImport(SwiftUI)` `.color` bridge — and the V3 PURE gate's regex flags ANY
  `import SwiftUI` line regardless of `#if`, so the whole file could not enter the pure
  Kernel. Extracted just the Foundation-pure value type (`struct RGBA { r,g,b,a; init }`)
  into a NEW `OpenBurnBarKernel/SharedModels/RGBA.swift`. The `.color` bridge + color
  math (`bucketKey`/`mix`/`lightened`/`darkened` + `Double.clamped`) stay in Core's
  `SharedModels/RGBA.swift` (path kept identical → zero UI-purity-baseline churn) as
  retroactive extensions behind `#if canImport(SwiftUI)`. Zero call-site changes for
  the ~40 Views/AgentLens `.color`/`.mix`/`.bucketKey` consumers (Kernel type + Core
  extensions both reach them via the `@_exported` umbrella).
- **CardEnvelope (option-b, layer-appropriate file join + stub removal).**
  `SubscriptionTopic.SubscriptionInboxPost.card: CardEnvelope?` references the full
  `CardEnvelope`. The full type in `Views/Cards/CardEnvelope.swift` is `import
  Foundation`-only (no SwiftUI; all `Card*` payload structs in-file; only comment-level
  refs to `Card*View`/`MissionConsoleActiveTile`/`CardSurface`), i.e. layer-appropriate
  for the pure Kernel. Moved it to `OpenBurnBarKernel/SharedModels/CardEnvelope.swift`
  and DELETED the redundant `SharedModels/LinuxCardEnvelope.swift` off-Apple stub (the
  full type now compiles on all platforms in the Kernel — a strict off-Apple win: real
  enum vs the old `.unknown`-only stub). `Views/Cards/CardEnvelopeView.swift` +
  `Views/Square/UnifiedSearchIndex.swift` still resolve `CardEnvelope` via the umbrella.
- **SubstrateCatalog (option-c via guard relaxation).** `SubstrateFamily.currentID`
  reads `SubstrateCatalog.plainID` / `SubstrateCatalog.byID`. The rich catalog in
  `Views/Substrate/SubstrateCatalog.swift` `import SwiftUI` (UI-tainted → forbidden in
  the pure Kernel). The Foundation stub already lived in `LinuxSubstrateSupport.swift`
  (moving to Kernel) behind `#if os(Linux)||os(Windows)`; relaxed that guard so the
  stub `SubstrateCatalog` (plainID/byID only) compiles on ALL platforms and satisfies
  `SubstrateFamily`. VERIFIED empirically: Core + daemon build clean — the same-name
  SwiftUI catalog in the Core/UI module shadows the re-exported Kernel one for Core/UI
  code (`SwarmSubstrateBox.swift`'s `SubstrateCatalog.resolved(...)` still binds the
  Core catalog), and the two types never exchange values. Zero call-site changes.

### RE-SLICED OUT — unstated DEPENDS-ON: P-02 (resource-backed catalog loader)
`CLIRuntimeModelCatalog.swift` (defines `CLIRuntimeModelOption`) and
`WandModelRouter.swift` (uses `CLIRuntimeModelOption`) both stay in Core in this PR.
`CLIRuntimeModelCatalog.swift` has two `catalog: BurnBarCatalog =
BurnBarCatalogLoader.bundledCatalog` DEFAULT-ARG sites, and `BurnBarCatalogLoader`
(`OpenBurnBarCatalogLoader.swift`) is a `Bundle.module`/`catalog.json` resource-backed
loader that **P-02** moves into the Kernel (P-02 card mv list: catalog loader +
`Resources/catalog.json`). Until P-02 lands, moving these two into the Kernel fails
`cannot find 'BurnBarCatalogLoader' in scope`, and pulling the loader+resource into
P-04a is a forbidden **resource-bundle STOP** (Failure Playbook #3). These two files
(+ their tests `CLIRuntimeModelCatalogTests.swift` / `WandModelRouterTests.swift`) ride the
**successor packet `plans/core-decomposition/packets/P-04c-catalog-models-kernel.md`, which
DEPENDS-ON P-02 (#1582) + P-04a (#1586)** (homed wave-1e, 2026-07-12). The DAG had no
P-04a→P-02 edge; this is the wave-1c dependency it missed (recorded as Wave-1 learning 9 —
the `BurnBarCatalogLoader.bundledCatalog` resource-loader hub).

### Allowed edit files
- `OpenBurnBarCore/Package.swift` — NONE expected (none of these 12 files is in
  `openBurnBarCoreExcludes`; verified at S0). If V2 reveals otherwise, STOP.
- **Path-pin edits for `CloudVaultCrypto.swift` (S0-repair FIX-5, machine-derived).**
  The OTHER 11 files have ZERO automation pins (verified: `git grep -n
  'SharedModels/<basename>.swift' -- .github scripts packages tools CODEOWNERS
  .swiftlint.yml project.yml` returns nothing for each). `CloudVaultCrypto.swift` is
  hard-pinned by its exact old path in FOUR files (5 distinct call sites); each must be
  updated from
  `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift`
  →
  `OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift`:
  - `.github/CODEOWNERS` (line ~54) — the explicit security-ownership rule
    `.../SharedModels/CloudVaultCrypto.swift @Ajnunezg @emilio3435`. Update the PATH,
    KEEP the owners. **The path updates IN THIS SAME PR so security ownership FOLLOWS the
    file** (the moved file must never sit un-owned). **PR body MUST flag this CODEOWNERS
    line for Alberto / security review.** Leave the sibling glob rules
    (`SharedModels/*Signal*.swift`, `*HPKE*.swift`) untouched — none of the 12 basenames
    match `*Signal*`/`*HPKE*`.
  - `scripts/ci/verify-codeowners-security-trees.sh` (line ~38) — SEMANTIC pin, not a
    plain path. This gate's `REQUIRED_RULES` list does an EXACT string equality against
    a CODEOWNERS pattern (`rule.pattern == required`); the `CloudVaultCrypto.swift` entry
    in this list must change to the NEW path in LOCKSTEP with the CODEOWNERS line above,
    or the gate fails (`missing explicit CODEOWNERS rule for <old path>`). Update only the
    one `.../SharedModels/CloudVaultCrypto.swift` string; leave the rest of the list.
  - `scripts/ci/write_burnbar_source_provenance.py` (line ~37) — plain-path pin in the
    source-provenance manifest (each entry "must be a real, committed file" and is hashed;
    a stale path fails the release provenance job). Update the one string. (Line ~38 in
    the same list already points at `OpenBurnBarKernel/SharedModels/SignalEnvelopeAAD.swift`,
    confirming the Kernel path shape.)
  - `scripts/privacy/scan-chat-cloud-plaintext.mjs` (lines ~1183, 1188, 1193, 1198, 1203)
    — SEMANTIC pin: FIVE `assertIncludes("<path>", "<security-invariant string>", ...)`
    calls read the file at `<path>` via `fs.readFileSync` (no try/catch → ENOENT crashes
    the privacy scanner) and assert it contains CloudVault sealed-payload v2 AAD
    invariants. Update the FIRST-arg path in all FIVE calls to the new Kernel path; leave
    the needle strings and messages unchanged.
- **AE-IMPORT** (standard, docs/CORE_DECOMPOSITION_PROGRAM.md): if the Kernel build
  demands `import <Dep>` in a moved file, add it (`<Dep>` a Kernel-declared dep only).
  Note the S0-repair FIX-4 closure check: these 12 are Foundation/CryptoKit/Security/
  AppIntents(guarded)/Observation-based with NO VectorKit-bound refs (CloudVaultCrypto's
  `Pensieve` mentions are doc comments only), so no cross-target `import` is expected;
  `AskAssistantIntent.swift` is whole-file `#if canImport(AppIntents)`-guarded (compiles
  off-Apple as empty). Never `import OpenBurnBarCore`.
- **AE-TESTABLE** (standard): add `@testable import OpenBurnBarKernel` beneath the
  existing `@testable import OpenBurnBarCore` in any Core test reaching an INTERNAL
  symbol of a moved file. **CONVERGED actual set: exactly ONE —
  `CloudVaultCryptoTests.swift`** (reaches internal `secureRandomCopyBytes` /
  `resolveAADForTesting`). Every other anticipated test compiled unchanged: the moved
  models expose only PUBLIC symbols (resolved via the umbrella), and the
  `CLIRuntimeModelCatalogTests.swift` / `WandModelRouterTests.swift` tests still reach
  Core (their files did not move — see RE-SLICED OUT).

## Shim
None. Core re-exports Kernel. Do NOT edit `KernelReexport.swift`.

## Forbidden actions
Standard. In particular: do NOT touch `openBurnBarCoreExcludes` (nothing here is in it).

## Enumerated semantic edits
The two SEMANTIC path-pins for `CloudVaultCrypto.swift` (both described in Allowed-edits):
the `verify-codeowners-security-trees.sh` `REQUIRED_RULES` exact-match entry (must move in
lockstep with the CODEOWNERS line), and the five `assertIncludes` first-arg paths in
`scan-chat-cloud-plaintext.mjs`. No Swift `public`/`internal` changes expected (these are
SharedModels the app and daemon both use → already `public`).

## Pre-flight checks
1. Path-pin grep of each basename over `.github scripts packages tools CODEOWNERS
   .swiftlint.yml project.yml` (machine-derived — do NOT assume NONE):
   - The OTHER 11 files → expected NONE (verified 2026-07-12: `git grep -n
     'SharedModels/<basename>.swift'` empty for `CLIRuntimeModelCatalog`,
     `ProviderRuntimeFailoverTypes`, `SubscriptionTopic`, `WandModelRouter`, `UIMode`,
     `HermesSquareFeatureFlags`, `LinuxCardEnvelope`, `LinuxSubstrateSupport`,
     `SubstrateFamily`, `AskAssistantIntent`, `AssistantPendingPrompt`).
   - `CloudVaultCrypto.swift` → EXPECTED HITS (all in Allowed-edits above; update each):
     `.github/CODEOWNERS:54`, `scripts/ci/verify-codeowners-security-trees.sh:38`,
     `scripts/ci/write_burnbar_source_provenance.py:37`, and
     `scripts/privacy/scan-chat-cloud-plaintext.mjs:{1183,1188,1193,1198,1203}`
     (`.swiftlint.yml` / `project.yml`: no `CloudVaultCrypto` hits). If a hit exists that
     is NOT in the Allowed-edit list, STOP (a new pin the plan did not anticipate).
2. Bundle.module grep over mv list → EMPTY.
3. Platform-conditional: confirm NONE of the 12 appear in `openBurnBarCoreExcludes`
   (grep Package.swift). If any does → it belongs in P-04b, STOP.
4. Not a CANON packet.

## Local validation (CONVERGED — all run 2026-07-12, Swift 6.4 / macOS)
V1 Kernel build OK · V2 Core build OK · V3 PURE OK (Kernel SwiftUI/AppKit-free; Core
UI-purity baseline 115=115, RGBA.swift path kept so no ratchet) · V4 61 tests / 0
failures (CloudVaultCrypto 24, CloudVaultAADParity 11, CloudVaultSignalEnvelope 4,
ProviderRuntimeFailoverTypes 4, SwarmSubstrateContract 18) · V5 daemon build OK · V6
membership OK (shrink, non-fatal) · V7 umbrella OK · verify-codeowners PASS ·
scan-chat-cloud-plaintext resolves the 5 CloudVault assertions at the new Kernel path
(only pre-existing unrelated SessionLogSyncService/firestore.rules findings remain,
identical on base). · V11 scope: 9 R100 (SharedModels moves) + 1 R100 (CardEnvelope.swift
Views→Kernel) + 1 A (new Kernel RGBA.swift) + 1 D (LinuxCardEnvelope.swift stub removed)
+ 1 M (Core RGBA.swift → color bridge) + 1 M test + 4 M path-pin gate files. `CLIRuntimeModelCatalog.swift`
+ `WandModelRouter.swift` NOT moved (RE-SLICED OUT to a P-02-dependent successor).

## PR body / Acceptance
Title: "P-04a: move pure SharedModels into OpenBurnBarKernel". Invariants: zero
call-site changes, no exclude-list edits, no contract files; `CloudVaultCrypto.swift`'s
FIVE-file / 8-site path-pins (CODEOWNERS + 3 CI gates) updated IN THIS PR so the
byte-identical crypto file keeps its security ownership + privacy/provenance coverage at
the new Kernel path. **PR body MUST flag the `.github/CODEOWNERS` line move for Alberto /
security review** (ownership follows the file). A1–A6; A3 exception: the enumerated
CODEOWNERS + CI-gate path-pin edits are IN scope (they are path-follow edits for the moved
file, not new logic).
