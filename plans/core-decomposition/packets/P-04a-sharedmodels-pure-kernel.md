# Packet P-04a: move pure SharedModels (incl. CloudVaultCrypto) → OpenBurnBarKernel
STATE: QUEUED
LANE: D          DEPENDS-ON: S0
BASELINE-TOUCHING: none

First of the two dependency-closed S4 halves. These are Foundation-only SharedModels
that are NOT in `openBurnBarCoreExcludes` today (they already compile off-Apple), so
this packet edits ZERO Package.swift exclude lines. CloudVaultCrypto is included here
(it is pure Foundation crypto and the P-04b crypto chain depends on it — moving it
first lets P-04b reference it from Kernel).

## Scope — the ONLY files you may touch

### git mv list (run exactly these, from repo root)
```
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CLIRuntimeModelCatalog.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CLIRuntimeModelCatalog.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderRuntimeFailoverTypes.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/ProviderRuntimeFailoverTypes.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubscriptionTopic.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubscriptionTopic.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/WandModelRouter.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/WandModelRouter.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/UIMode.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/UIMode.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesSquareFeatureFlags.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/HermesSquareFeatureFlags.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxCardEnvelope.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxCardEnvelope.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/LinuxSubstrateSupport.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/LinuxSubstrateSupport.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SubstrateFamily.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/SubstrateFamily.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AskAssistantIntent.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AskAssistantIntent.swift
git mv OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AssistantPendingPrompt.swift OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/AssistantPendingPrompt.swift
```

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
  symbol of a moved file. Anticipated: `CLIRuntimeModelCatalogTests.swift`,
  `CloudVaultCryptoTests.swift`, `CloudVaultAADParityTests.swift`,
  `CloudVaultSignalEnvelopeTests.swift`, `ProviderRuntimeFailoverTypesTests.swift`,
  `WandModelRouterTests.swift`, `HermesSquarePhaseATests.swift`,
  `SwarmSubstrateContractTests.swift`, `CLIAgentSessionCodecTests.swift`,
  `PensieveKnowledgeChunkerTests.swift`. Add ONLY where compile fails (public models
  need none); enumerate in the PR body.

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

## Local validation
V1 Kernel build · V2 Core build · V3 PURE · V4 test · V5 daemon build · V6–V9b
ratchets (membership shrink) · V11 scope (12 R100, 0 or 1 M).

## PR body / Acceptance
Title: "P-04a: move pure SharedModels into OpenBurnBarKernel". Invariants: zero
call-site changes, no exclude-list edits, no contract files; `CloudVaultCrypto.swift`'s
FIVE-file / 8-site path-pins (CODEOWNERS + 3 CI gates) updated IN THIS PR so the
byte-identical crypto file keeps its security ownership + privacy/provenance coverage at
the new Kernel path. **PR body MUST flag the `.github/CODEOWNERS` line move for Alberto /
security review** (ownership follows the file). A1–A6; A3 exception: the enumerated
CODEOWNERS + CI-gate path-pin edits are IN scope (they are path-follow edits for the moved
file, not new logic).
