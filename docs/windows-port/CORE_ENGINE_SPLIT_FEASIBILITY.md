# Core Engine/UI Split — Feasibility Analysis + Untangle Plan (VAL-P0-CORE-014)

**Status:** macOS-now spike **COMPLETE — split is TRACTABLE.** Option-A-supporting input for
`GATE-030` §7.3 criterion #1 (CORE-015). This is the *macOS half* only; the Swift-on-Windows
compile of the carved subset is `VAL-P0-CORE-015` (PENDING) and remains the true go/no-go gate.

**Author date:** 2026-07-02 (before any Swift-on-Windows result is known).
**Toolchain:** Apple Swift 6.4 (swiftlang-6.4.0.20.104), `swift build`, macOS 27 / arm64.
**HARD boundary honored:** production `OpenBurnBarCore` is **untouched**. The carve lives only on the
never-merged branch `spike/core-engine-split` (package `spikes/core-engine-split/`, target
`OpenBurnBarEngine`). See *§7 Evidence* for the `git diff --stat` proof.

---

## TL;DR (plain English)

- The macOS app links **one** giant SwiftPM target, `OpenBurnBarCore` (359 Swift files). That single
  target mixes **pure data models** (portable) with **117 SwiftUI view files** and a handful of
  Apple-only service files. Because they're all one target, *anything that imports the models also
  drags in all the SwiftUI* — that's the thing blocking a Windows build.
- **The good news:** the models are already ~90% clean. `SharedModels/` is 122 files, **110 of them
  import only `Foundation`**. The flagship `AgentProvider` enum (32 agent kinds) *imports SwiftUI but
  never uses a single SwiftUI symbol* — the import is dead. Delete one line and it's engine-clean.
- **The spike proves it:** I carved a real, UI-free `OpenBurnBarEngine` target seeded from
  `AgentProvider` + the whole provider-account model cluster, and it **compiles clean on macOS with
  zero SwiftUI / AppKit / Vendor dependencies** (`Build complete! (6.40 sec)`).
- **What's left to untangle** is bounded and known: (a) 5 SwiftUI files that define UI *primitives*
  (colors/`RGBA`) which pure models reference — extract the primitive; (b) ~18 crypto files that
  `import CryptoKit`/`Security` — swap to swift-crypto + a keystore seam; (c) 1 genuinely hard file,
  `PretextEngine` (an offscreen `WKWebView`) — needs a Windows WebView2 substitute; (d) the
  `SecureEnclave` hardware-key path — needs a Windows TPM/CNG substitute. None of these are model code.
- **Verdict:** the split is **tractable**, not intractable. This is a *green* input to G0, **not** an
  Option-B lean. The only open question is whether the carved subset also compiles under
  Swift-on-Windows — that is CORE-015, deliberately out of scope here.

---

## 1. Verified repo facts (how each was measured)

All counts measured on 2026-07-02 against the working tree. Commands are reproducible.

| Fact | Value | How verified |
|---|---|---|
| `OpenBurnBarCore` target file count | **359** `.swift` | `find Sources/OpenBurnBarCore -name '*.swift' \| wc -l` |
| Files `import SwiftUI` | **110** | `grep -rl 'import SwiftUI' … \| wc -l` |
| …of which **guarded** by any `#if` | **0** | line-before-`import SwiftUI` scan across all 110 — none under a `#if` |
| `Views/` files | **117** | `find Views -name '*.swift' \| wc -l` |
| Non-`Views/` Apple-import files | **34** | Apple-framework import scan minus `Views/` |
| `SharedModels/` files | **122** | `find SharedModels -name '*.swift'` |
| …Foundation-only | **110** | 122 minus 12 Apple-coupled |
| `import GRDB` in Core target | **0** | DB is **not** a Core-target blocker (lives in the app target) |
| `OpenBurnBarComputerUseCore` files | **54** | `find` |
| …hard-Apple (Darwin/XPC/Keychain/Security/LocalAuth) | **~12** | import + `audit_token_t`/`SecKeychain`/`NSXPCConnection` markers |
| `SecureEnclave` refs (Core source) | **6** (2 files) | `PhoneControlAuthoritySigningKey.swift`, `PhoneControlStepUpPolicy.swift` |

**`SharedModels` is not a separate target — confirmed.** `OpenBurnBarCore/Package.swift` declares a
single `.target(name: "OpenBurnBarCore")` with the default path `Sources/OpenBurnBarCore`.
`SharedModels/`, `Views/`, `Services/`, `Pretext/`, etc. are all **subfolders of that one target**;
`grep SharedModels Package.swift` returns nothing. Consequence: SwiftPM compiles all 359 files into
one module, and every downstream consumer (`OpenBurnBarMedia`, `OpenBurnBarComputerUseCore`,
`OpenBurnBarSignalCore`, `OpenBurnBarIrohRelay`, the app) that writes `import OpenBurnBarCore`
transitively links the 117 SwiftUI views. **This coupling is the root cause; splitting the target is
the fix.**

---

## 2. Blocker class A — the 110 SwiftUI files (0 guards) + 117 `Views/`

**Shape.** 117 files under `Views/` are pure SwiftUI screens/components (30.7k LOC). The remaining
`110 − (SwiftUI files under Views) = ` handful of SwiftUI imports outside `Views/` are only **5**
files (see §3). Not one of the 110 `import SwiftUI` lines is wrapped in a `#if canImport(SwiftUI)` /
`#if os(...)` guard — so today there is **no** compile-time seam separating UI from engine.

**Untangle.** These 117 `Views/` files are **out of scope for the Engine** — they belong to the macOS
app's presentation layer, and Windows will get a native WinUI equivalent (workstream W6). The split
does **not** port them; it *excises* them from the Core target so they stop contaminating the model
graph. Target topology (§6): move `Views/` into a new `OpenBurnBarCoreUI` target that depends on
`OpenBurnBarEngine`, leaving `OpenBurnBarEngine` free of SwiftUI. The macOS app keeps importing both;
Windows imports only `OpenBurnBarEngine`.

**Cost:** mechanical (target re-partition), **not** a rewrite. No `#if` guards needed on the views —
they simply live in the UI target.

---

## 3. Blocker class B — the 34 non-`Views/` Apple-import files

These are the files that *look* like engine code (services, models, crypto) but still reach an
Apple-only framework. This is the real untangle surface. Full classification:

### B1 — UI primitives leaking into models (5 files, `import SwiftUI`)
| File | Real dependency | Untangle |
|---|---|---|
| `SharedModels/AgentProvider.swift` | **none** — `import SwiftUI` is **dead** (0 SwiftUI symbols used) | **delete the import.** Proven in spike. |
| `SharedModels/ThemePrimitives.swift` | defines color/theme primitives | extract pure `RGBA`/token structs to Engine; keep `Color` extensions in UI target |
| `SharedModels/SwarmColorDriver.swift` | defines `RGBA` + swarm color logic | `RGBA` is a plain struct in a SwiftUI file; move `RGBA` to Engine, `Color` bridge to UI |
| `SharedModels/AgentProvider+LogoBackdrop.swift` | SwiftUI `LinearGradient`/`Color` | pure presentation — moves to UI target |
| `UIMode.swift` | SwiftUI-flavored enum | split: raw `UIMode` enum → Engine; `View` conveniences → UI |

> **Key finding.** Foundation-only model `SubstrateFamily.swift` references `RGBA`, which is defined in
> the SwiftUI file `SwarmColorDriver.swift`. That single cross-file reference is why a naive "lift all
> Foundation-only models" build fails (see §7). Extracting `RGBA` (a plain 4-float struct) to the
> Engine breaks the leak. This is the archetypal untangle move.

### B2 — Crypto files (18: `CryptoKit` and/or `Security`) → swift-crypto + keystore seam
- **CryptoKit-only (13)** — swappable to [`swift-crypto`](https://github.com/apple/swift-crypto)'s
  `Crypto` module, whose API is source-compatible with `CryptoKit` and ships on Windows/Linux:
  `BurnBarPersistentVectorIndex`, `Memory/MemorySecretPIIGate`, `OpenBurnBarAgentContracts`,
  `Services/Insights/{InsightAnalysisCache,InsightAnalysisEngine,InsightAnalysisModelPrompt,InsightCache,InsightDigestBuilder,Verdict/RuleBasedVerdictEngine}`,
  `SharedModels/{EscrowDeviceSafetyCode,Insights/InsightAnalysis,PensieveKnowledgeChunker,PensieveVectorCloak}`.
- **CryptoKit + Security (5)** — need the swift-crypto swap **and** a portable key-storage abstraction
  (Apple `Security`/Keychain → Windows DPAPI/CNG-backed store):
  `SharedModels/{CloudVaultCrypto,CloudVaultDeviceKeypair,HermesRatchetCrypto,HermesRelayCrypto}`,
  `Services/Insights/Verdict/VerdictCache`.

  **Untangle:** introduce a `KeyStoring` protocol in Engine; Apple impl uses Keychain, Windows impl
  uses CNG/DPAPI. The crypto *algorithms* (P256/HKDF/AES-GCM/SHA-512) are all in swift-crypto.

### B3 — Logging (3: `OSLog`/`os.log`) → swift-log shim
`Hermes/HermesAtomNavigator`, `Metrics/OpenBurnBarMetrics`,
`Services/Insights/Adapters/BurnBarHostedInsightAdapter` (and `PretextEngine`). Swap `os.Logger` for a
thin `Logging`-package (`swift-log`) façade; trivial.

### B4 — Process/shell launch (5: `AppKit`) → PAL boundary
`BrowserLaunchAdapter`, `ChromeProfileDiscovery`, `SwitcherBrowserLaunchService`,
`SwitcherCLILAunchService`, `TextExpansion/TextExpansionKeyEventCharacters` (AppKit+CoreGraphics).
These use `NSWorkspace`/`CGEvent` to launch browsers, discover Chrome profiles, and synthesize
keystrokes. **Not engine** — they belong behind the Platform Abstraction Layer (workstream W1);
Windows uses `ShellExecute`/`SendInput`. Move to a `platform-mac` target; define protocol seams in
Engine.

### B5 — Geometry (1: `CoreGraphics`) → portable geometry
`Pretext/PretextTypes.swift` uses `CGFloat`/`CGRect`. Substitute a portable `struct Rect { x,y,w,h:
Double }` or vendor `swift-numerics`-style types; mechanical.

### B6 — Image rendering (1: `UIKit`+`AppKit`) → platform target
`Services/Insights/Share/InsightShareCardRenderer.swift` renders a share-card image. Presentation —
moves to the platform/UI target; Windows renders via Direct2D/WinUI.

### B7 — WebKit (1) — **the one genuinely hard file**
`Pretext/PretextEngine.swift` (463 LOC) runs a **single offscreen `WKWebView`** (`WKWebViewConfiguration`,
`WKNavigationDelegate`, `userContentController`) to execute the bundled Pretext HTML/JS shell.
**Untangle:** this is a real substitution, not a move. Windows needs a `WebView2` (Edge/Chromium)
host implementing the same `PretextEngine` protocol surface (evaluate JS, receive callbacks). Define a
`PretextHosting` protocol in Engine; the Apple impl wraps `WKWebView`, the Windows impl wraps
`WebView2`. This is the **highest-effort item in the Core split** and should be its own workstream.

**Tier tally (34 files):** UI-primitive 5 · crypto 18 · logging 3 · shell/PAL 5 · geometry 1 · image 1 ·
WebKit 1.

---

## 4. Blocker class C — `OpenBurnBarComputerUseCore` (12 Darwin/XPC/Keychain files)

Separate target (54 files, depends on `OpenBurnBarCore` + `OpenBurnBarMedia`). ~20 files `import
CryptoKit` (swift-crypto swappable, same as B2). The **hard-Apple ~12** are the privileged-input /
trust / keychain plumbing:

| File | Apple surface | Windows substitute |
|---|---|---|
| `PrivilegedInputXPCClient.swift` | `Darwin`, XPC (`NSXPCConnection`) | named-pipe / COM broker |
| `PrivilegedInputXPCConstants.swift` | `Darwin` XPC constants | pipe/RPC constants |
| `PrivilegedSocketTrust.swift` | `Darwin` + `Security` (peer `audit_token_t`) | `GetNamedPipeClientProcessId` + token check |
| `ControllerKeyPinStore.swift` | `Security` Keychain | CNG/DPAPI store |
| `IrohHostKeyPinStore.swift` | `Security` Keychain | CNG/DPAPI store |
| `ComputerUseAuditExportSignerProvider.swift` | `LocalAuthentication` + `Security` | Windows Hello + CNG |
| `RemoteUnlockSystemScreenSharingProbe.swift` | `Darwin` (screen-share detection) | `WTSQuerySessionInformation` |
| `Mac/SecKeychainInteractionGate.swift` | `Security` | CNG gate |
| `RemoteUnlockPolicy.swift` / `RemoteUnlockCertificationReport.swift` | keychain/XPC-adjacent | policy layer, PAL-backed |

**Scope note.** ComputerUseCore is a **Phase-2** concern for the port; it is *not* on the critical
path for the first Windows engine slice. The audit-chain / capability-token *models* (BLAKE-swappable
SHA-256, `CryptoKit`) port via swift-crypto; only the OS-privilege plumbing needs PAL work.

---

## 5. Blocker class D — `SecureEnclave` → TPM/CNG substitute

**Surface (verified):** `SecureEnclave.P256.Signing.PrivateKey` in
`OpenBurnBarComputerUseCore/PhoneControlAuthoritySigningKey.swift:16` (a hardware-backed P256 signing
key; the file already abstracts a `PhoneControlP256AuthoritySigning` protocol with a software-key
fallback), and the `.enforcedBySecureEnclaveSignature` step-up rung in `PhoneControlStepUpPolicy.swift`.
6 references in Core source (+1 in AgentLens, +2 in Mobile).

**Why it's already half-solved:** the code path is *protocol-abstracted* — `SecureEnclave.P256…`
merely conforms to `PhoneControlP256AuthoritySigning`, and a software `P256.Signing.PrivateKey`
fallback exists. That is exactly the seam a Windows impl plugs into.

**Windows substitute:** a hardware-backed key via **CNG + the Platform Crypto Provider (TPM)** —
`NCryptCreatePersistedKey(MS_PLATFORM_CRYPTO_PROVIDER, NCRYPT_ECDSA_P256_ALGORITHM, …)`, signing with
`NCryptSignHash`. Exposed to Swift through the C-ABI or the same UniFFI bridge pattern the Rust crates
use. Non-TPM machines degrade to the existing software fallback (policy already models this via the
step-up rungs).

**Disposition:** feeds `GATE-030` §7.3 criterion R14/AC-013 (the App Check / hardware-attestation PIVOT
lane), not the base engine compile. Tractable; needs a native shim, not a redesign.

---

## 6. The untangle plan — target topology

Split the one `OpenBurnBarCore` target into a **layered stack** (each layer a real SwiftPM target so
the compiler enforces the boundary):

```
┌─────────────────────────────────────────────────────────────┐
│ OpenBurnBarCoreUI        (117 Views/ + 5 UI-primitive files) │  SwiftUI — macOS/iOS only
│   depends on ▼                                               │
├─────────────────────────────────────────────────────────────┤
│ platform-mac  │ platform-win   (B4 shell, B6 image, B7 web,  │  #if os / separate targets
│   AppKit/…    │  WebView2/…     SecureEnclave↔TPM, XPC↔pipe)  │
│        both conform to protocol seams declared in ▼          │
├─────────────────────────────────────────────────────────────┤
│ OpenBurnBarEngine   (SharedModels + models + services logic) │  Foundation + swift-crypto + swift-log
│   • AgentProvider (32 cases)  • provider/account/quota models │  NO SwiftUI, NO AppKit, NO WebKit
│   • crypto via swift-crypto   • KeyStoring / PretextHosting / │  ← THE PORTABLE CORE (this spike)
│     PrivilegedInput / P256Signing protocol seams             │
│   depends on ▼                                               │
├─────────────────────────────────────────────────────────────┤
│ OpenBurnBarFirestoreModels   (14 files, Foundation-only)     │  already a clean leaf target
└─────────────────────────────────────────────────────────────┘
```

**Migration order (lowest-risk first):**
1. Extract UI primitives (`RGBA`, tokens, `UIMode` raw enum) out of the 5 SwiftUI files → Engine.
2. Swap `CryptoKit`→`Crypto`, `os.Logger`→`swift-log` in the 18+3 files (source-compatible).
3. Introduce `KeyStoring` / `PretextHosting` / `PrivilegedInput` / `P256Signing` protocol seams in
   Engine; move Apple impls to `platform-mac`.
4. Physically relocate `Views/` → `OpenBurnBarCoreUI`.
5. Flip the target boundary in `Package.swift`; fix the fallout (the compiler now *enforces* no
   SwiftUI in Engine).

Each step is independently compilable and reviewable. No step rewrites model logic.

---

## 7. Evidence — the isolated spike

**Branch:** `spike/core-engine-split` (created from the mission docs branch; **never merged**).
**Package:** `spikes/core-engine-split/` — zero Vendor / xcframework / remote-package dependencies.
**Target `OpenBurnBarEngine`** seeded from the 32-case `AgentProvider` + its real dependency closure:

Compiled files (19, **all `import Foundation` only**):
```
OpenBurnBarEngine/SharedModels/AgentProvider.swift          (32-case enum; SwiftUI import removed)
OpenBurnBarEngine/SharedModels/ProviderAccountTypes.swift   (defines ProviderID — AgentProvider's only dep)
OpenBurnBarEngine/SharedModels/ProviderConnectionTypes.swift
OpenBurnBarEngine/SharedModels/ProviderEndpointProfileRegistry.swift
OpenBurnBarEngine/SharedModels/BudgetRule.swift
OpenBurnBarFirestoreModels/*.swift                          (14 files — the pre-existing clean leaf target)
```

**macOS clean-build log** (`spikes/core-engine-split/evidence/macos-compile.log`):
```
swift build   (from spikes/core-engine-split, rm -rf .build first)
[81/92] OpenBurnBarEngine … [95/98] OpenBurnBarEngine
Build complete! (6.40 sec)
```
Import audit of the compiled target: `grep -rh '^import' Sources | sort | uniq -c` → **`19 import
Foundation`** and nothing else. No SwiftUI, AppKit, UIKit, WebKit, CryptoKit, or Vendor symbol is
linked.

**The single most important proof:** `AgentProvider.swift` — the file the contract names as the carve
seed — went from "imports SwiftUI" to engine-clean by **deleting one dead import line**, with zero
other edits. Its 32 cases, `providerID`/`persistedToken`/catalog-mapping logic, and swarm-glyph
selection all compile on pure Foundation.

**Bounded-untangle proof (the honest limit).** Naively lifting **all 110** Foundation-only
`SharedModels` files into the Engine does **not** compile clean — it fails on exactly the seams this
doc predicts: `cannot find type 'InsightConfidence'` (a type in a `CryptoKit` file) and
`cannot find 'RGBA'`/`'SubstrateCatalog'` (UI primitives in SwiftUI files), which then cascade into
`Encodable`/`Hashable` conformance failures. This is precisely why the split needs the §6 steps and
isn't a free `git mv` — but every failure is a *named, bounded* seam, not an architectural wall.

**Production-Core-untouched proof:** on the spike branch,
```
git diff --stat main -- OpenBurnBarCore/    →  (empty — 0 files changed)
```
The spike adds only `spikes/core-engine-split/**`; `OpenBurnBarCore/Sources` and
`OpenBurnBarCore/Package.swift` are byte-identical to `main`. (Reproduce from the branch; see §8.)

---

## 8. Reproduce

```bash
git switch spike/core-engine-split
cd spikes/core-engine-split && rm -rf .build && swift build        # → Build complete!
git diff --stat main -- OpenBurnBarCore/                            # → empty (production Core untouched)
grep -rh '^import' Sources | sort | uniq -c                        # → only "import Foundation"
```

---

## 9. Disposition for GATE-030 (§7.3 criterion #1 / CORE-015)

- **This finding = GO on the macOS half.** The UI/engine split is **tractable**: the model layer is
  ~90% Foundation-clean already, the flagship `AgentProvider` carves for free, and a real engine
  subset compiles UI-free on macOS. **This is an Option-A-supporting input, not an Option-B lean.**
- **The real gate is CORE-015** (Swift-on-Windows compile of the carved subset), which is *explicitly
  out of scope here*. G0's Option-A ABORT trigger fires only if that subset **cannot** compile clean
  on Swift-on-Windows — a question this spike does not and must not pre-answer.
- **Residual risk items** (each has a named seam + substitute above, none blocks the base engine):
  WebKit/`PretextEngine` (WebView2), `SecureEnclave` (TPM/CNG), XPC/Keychain (pipes/CNG),
  `Security`-backed key storage (`KeyStoring` seam).

**Bottom line:** carve the Engine target, enforce the boundary with the compiler, and the Windows port
inherits a clean, Foundation-only model core. The hard bits (WebView, TPM) are isolated to well-defined
protocol seams, not smeared across the model graph.
