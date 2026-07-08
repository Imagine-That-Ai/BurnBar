# Phase 1 — OpenBurnBarCore Engine/UI Split (production refactor plan)

**Status:** ready to execute · **Unlocked by:** G0 → Option A bound (2026-07-03, Swift compiles on Windows).
**Precondition:** land the Phase-0 foundation on a clean base first (PR #1170 conflict cleanup).
Authoritative macOS-half analysis: `docs/windows-port/CORE_ENGINE_SPLIT_FEASIBILITY.md`. This is the
executable production sequence that consumes it.

## ⚠️ Ground-truth correction (verified against committed `Package.swift`)
The earlier "intel" that `OpenBurnBarCore/Package.swift` already has an `#if os(Linux)`
`openBurnBarCoreExcludes` seam + a `swift-crypto 3.0.0` dependency + a wired
`OpenBurnBarLinuxCoreFoundationTests` target is **FALSE** — none exist in any committed manifest (the
Linux files are untracked/unwired on disk). **This plan CREATES that seam (PR-4).** Also verified: of the
110 unguarded `import SwiftUI` files, **105 are under `Views/`; only 5 are outside** — those 5 are the real
Engine-zone blockers.

## Mechanism — a two-tier seam that keeps macOS byte-identical
- **Tier A (manifest, `#if os(Windows)||os(Linux)` in `Package.swift`):** prune Vendor-coupled
  targets/products/deps (SignalCore, IrohRelay, Media, ComputerUseCore, LibSignal path pkg, binaryTargets)
  so the graph *resolves* off-Apple; add `swift-crypto` + `swift-log` `.when(platforms:[.windows,.linux])`.
- **Tier B (file, `openBurnBarCoreExcludes` on the target):** **empty on Apple** → macOS/iOS compile the
  WHOLE target exactly as today (zero risk); populated off-Apple → `Views/` + UI remnants + Apple-runtime
  files excluded ⇒ the Foundation(+swift-crypto) **Engine** subset remains.
- `Package.swift` is host-evaluated, so `#if os(Windows)` is true only on the Windows CI runner.
- Phase-2 (optional): promote the seam into real `OpenBurnBarEngine`/`OpenBurnBarCoreUI` targets for
  compiler-enforced boundaries. Not required to unblock the port.

## File classification (mechanisms: GUARD / EXTRACT→STAY / EXCLUDE / SEAM)
**The 5 non-`Views/` SwiftUI blockers:**
- `SharedModels/AgentProvider.swift` — GUARD: delete the **dead** `import SwiftUI` (0 SwiftUI symbols).
- `SharedModels/SwarmColorDriver.swift` — EXTRACT `struct RGBA`→`SharedModels/RGBA.swift`; `#if canImport(SwiftUI)` the `var color: Color`.
- `SharedModels/ThemePrimitives.swift` — EXTRACT `DesignSystemTokens`+`providerRGBA`→Foundation; EXCLUDE the Color/NSColor/UIColor residue.
- `SharedModels/AgentProvider+LogoBackdrop.swift` — EXCLUDE (pure presentation).
- `UIMode.swift` — EXTRACT raw enum→Foundation; EXCLUDE the Color-accessor remnant.
- *Archetypal leak:* `SubstrateFamily.swift` (Foundation) calls `RGBA(...)` ~12× → extracting `RGBA` (PR-1) closes it.

**`Views/` (117 files/30.7k LOC):** EXCLUDE the folder off-Apple; Windows gets native WinUI equivalents.

**~24 non-`Views/` Apple-import files:** CryptoKit-only (13) → GUARD `#if canImport(CryptoKit) … #else import Crypto` (swift-crypto is source-compatible for AES.GCM/SHA/HKDF/HMAC/P256/Curve25519/SymmetricKey); Crypto+Security (5) → same + GUARD `Security`/Keychain behind a `KeyStoring` seam + shim `SecRandomCopyBytes`; OSLog (3) → GUARD `#if canImport(OSLog)` else swift-log; Shell/PAL (5) → `ProcessLaunching`/`KeystrokeSynthesis` SEAM + EXCLUDE Apple impls; image render (1) → EXCLUDE; `PretextTypes` (CoreGraphics) → EXTRACT portable `Rect`; `PretextEngine` (WebKit) → SEAM+EXCLUDE.

**`OpenBurnBarComputerUseCore` (54 files, 12 hard-Apple):** pruned from the Windows manifest entirely in Phase 1 (Tier-A); comes online when Computer Use is scheduled for Windows.

## Key seams
- **SecureEnclave→TPM/CNG (`PhoneControlAuthoritySigningKey`):** already protocol-abstracted (`PhoneControlP256AuthoritySigning`, existential). GUARD the Apple `SecureEnclave` conformance; software `P256` path + all verification work via swift-crypto; add `WindowsPlatformCryptoP256Key` (CNG Platform Crypto Provider / TPM: `NCryptCreatePersistedKey`+`NCryptSignHash`, raw r‖s) later; **keep the wire enum `secureEnclaveP256`/`keyKind:"se-p256"`** for byte-identical cross-platform pairing.
- **Pretext (R22):** `PretextEngine` drives one offscreen `WKWebView` + bundled JS, consumed by 4 Mac chat views. Recommend **WebView2 behind a `PretextHosting` protocol** (reuses the exact bundled JS → parity for free) as Phase-2; Phase-1 EXCLUDES it, chat renders plain text.
- **wrapUntrusted→Core (R18) predecessor:** create canonical `SharedModels/LLMSafeContent.swift` (Foundation); re-point the app + daemon copies. Consolidates the G8 prompt-injection wrapper + puts it in the Windows Engine subset.

## PR sequence (macOS `xcodebuild` scheme `OpenBurnBar` GREEN at every step)
1. **PR-1** Extract UI primitives to Foundation (RGBA, DesignSystemTokens, UIMode; delete dead SwiftUI import). Pure refactor.
2. **PR-2** swift-crypto import shim + `.when(platforms:[.windows,.linux])` dep; GUARD SecureEnclave/Security/random.
3. **PR-3** R18: `LLMSafeContent`→Core; re-point app+daemon.
4. **PR-4** Manifest Windows/Linux resolvability + **empty** `openBurnBarCoreExcludes` + wire the Foundation test target + add `openburnbar-engine-windows.yml` CI (`resolve` + build `FirestoreModels` + Foundation tests → green).
5. **PR-5 (capstone)** Flip the file seam off-Apple (`Views/`, Pretext, remnants, keychain, SecureEnclave conformance) → **Engine compiles on Windows** (`swift build --target OpenBurnBarCore`).
6. **PR-6** `PretextHosting` seam (R22).
7. **PR-7** `KeyStoring` + `P256HardwareSigning` seams.
8. **PR-8** Shell/PAL seam.
9. **PR-9** Portable geometry → un-exclude `PretextTypes`.
10. **PR-10** Walking skeleton target: one provider (`AgentProvider`) → parse (`HermesOpenAICompatibleStreamParser`, all verified Foundation-only) → auth (`BurnBarProviderAuthRegistry`) → one dashboard tile (`ProviderQuotaPacing`→`BurnBarWidgetSnapshot`), built+asserted on `x86_64-unknown-windows-msvc` CI.

Each PR is small, isolated, macOS-green; Windows CI is required only from PR-5 onward.

## Top risks
- Excluding a file whose symbol a kept file references → land all EXTRACT→STAY untangles (PR-1/2/3) BEFORE the exclude flip (PR-5); shrink the exclude list to re-green Windows; macOS never affected.
- Manifest won't resolve off-Apple (LibSignal/Vendor) → PR-4 gates those behind `#if !(os(Windows)||os(Linux))`.
- swift-crypto adds to the **macOS** link graph → dep is `.when(platforms:[.windows,.linux])` (not linked on Apple).
- Windows CI flakiness gating unrelated PRs → Windows job blocking only from PR-5.

## Windows build recipe (proven on the dev host, for the CI lane)
Swift **6.3.2** Windows toolchain + VS 2022 BuildTools (**VCTools**) + VCRedist 2015+ x64 + Python 3.10 +
`SDKROOT=…\Swift\Platforms\6.3.2\Windows.platform\Developer\SDKs\Windows.sdk`.
