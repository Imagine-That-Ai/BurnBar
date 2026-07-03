# OpenBurnBar — Windows Port Master Plan

**Status:** DRAFT v2.1 (post adversarial review + Codex second opinion + web research) · **Author:** Claude (8-agent survey + synthesis + 4-critic adversarial pass + Codex consult) · **Date:** 2026-07-02
**Target:** Full **peer** parity of the macOS app (`AgentLens/`) on Windows 10/11 (x64 + ARM64).
**Not** a cloud-only companion (that is what iOS/Android already are). Windows is a **local log-reading peer**, like the Mac.

> **The completion bar (from `AGENTS.md`).** This plan ships the *whole* thing: the local-peer engine, every UI
> surface, computer-use, the daemon, the pet, distribution, and a parity-certification harness that proves it.
> No "table it for later," no scope-laundering. Where a macOS capability has no Windows analog, this plan defines
> an **explicit equivalent**; where a capability is genuinely blocked, it says so in the risk register instead of
> hiding it.

> **⚠️ Read §0.1 first.** A four-lens adversarial review found **two potentially existential blockers** (Firebase
> App Check attestation lockout; SQLCipher/GRDB-on-Windows unproven), a materially **inflated core-reuse estimate**,
> and **~19 shipping subsystems missing from the parity matrix**. This v2 integrates all confirmed findings. The
> headline consequence: **Phase 0 is now a real go/no-go**, not a formality — two spikes can kill or repivot the
> whole approach before a line of production code is written.

---

## 0. How to read this document

- **§0.1** — the adversarial-review changelog (what v2 fixed and why). Read it first.
- **§1–§5** frame the problem: parity definition, current state, the stack decision, the reuse ledger.
- **§6–§8** are the operating model: parallel-workstream topology, the between-phase adversarial gates, the phase plan.
- **§9** is the engineering detail: 12 workstream deep-dives with macOS→Windows API mapping.
- **§10** is the parity matrix — now with a **full subsystem inventory** (§10.1) so nothing is silently dropped.
- **§11–§15** are verification, CI/distribution, the risk register (now including security-regression rows), sizing,
  and the open decisions for Alberto.

This is a **plan**, not an implementation, written to be executed by a **fleet of parallel agents** through the
BurnBar software factory (`docs/SOFTWARE_FACTORY_PR_LOOP.md`). Every workstream is a stream of small, reviewable PRs.

### 0.1 Adversarial-review changelog (v1 → v2)

Four independent critics (technical, parity-gap, process, security) each attacked v1 and verified against the
codebase. Confirmed findings, folded into v2:

**Factual corrections to v1 (the draft was wrong):**
- **Core reuse was overstated.** `OpenBurnBarCore` has **110 files with unguarded `import SwiftUI`** and **117 files
  / ~30.7k LOC of SwiftUI Views living *inside* the "portable" core** (`OpenBurnBarCore/Sources/OpenBurnBarCore/Views/`).
  `SharedModels/AgentProvider.swift` — the 32-case provider enum the parsers depend on — imports SwiftUI
  unconditionally. **Option A now requires splitting Core into `…Engine` (no SwiftUI/AppKit) + `…UI` targets as a
  prerequisite**, and the reusable figure drops from "~120k" to **~90k**. (§4, §9.2)
- **The DB layer is NOT in Core.** `import GRDB` = **0 in Core, 46 in `AgentLens/`, 4 in daemon.** The 2,055-LOC
  migrator, DataStore, and all 53 migrations live in the app target v1 called "not reusable." Reusing them means
  **extracting them from the app first** — reclassified accordingly. (§9.3)
- **GRDB has zero Windows support.** `Vendor/GRDB-SQLCipher/Package.swift` lists only Apple platforms; no
  `windows`/`msvc` anywhere. "Compile GRDB for Windows" is now an **explicit Phase-0 spike with a raw-SQLCipher-C
  fallback**, not an assumption. (§4, §8 Phase 0, R2)
- **Counts fixed:** `AF_UNIX`/`sockaddr_un` ≈ **116 sites** (not 35); codesign peer-auth ≈ **85 sites**. Firebase
  callables = **53 `onCall`** (v1 said "13" in one place and "157" in another — both wrong). (§3, §9.1, §9.3)
- **`OpenBurnBarComputerUseCore` is not "directly portable"** — 37 Apple-only sites (XPC, audit-token, CGEvent/AX)
  co-mingled; needs the same target-split surgery. (§9.5)
- **swift-crypto has no `SecureEnclave`** (used in `PhoneControlAuthoritySigningKey.swift`) — needs a TPM/CNG
  substitute. (§9.2, R15)
- Combine is a **non-issue** (0 imports in Core); Rust-crates-to-Windows is credible; most CryptoKit is covered by
  swift-crypto — these v1 assumptions held up.

**Two potentially existential blockers added (were underweighted):**
- **Firebase App Check attestation lockout (R14, Critical).** `enforceAppCheck` defaults **true** and prod refuses
  to boot without it (`functions/src/config.ts:397-411`); **52 function files enforce it**; the Firestore product
  is console-tier App-Check-gated; the Hermes relay checks `x-firebase-appcheck`. The only providers are Apple
  **App Attest/DeviceCheck** — **no Windows attestation exists.** A Windows REST client is rejected at the network
  boundary across *all* cloud surfaces. This needs a **new backend custom-attestation provider** (or a written,
  risk-accepted weaker posture) — it is **not** the client-only "Firestore REST gateway" v1 scoped. Now a Phase-0
  spike + open decision #6.
- **SQLCipher/FTS5 byte-compat + GRDB-on-Windows (R2, Critical)** — see above; promoted to a Phase-0 kill-risk.

**Parity matrix completeness:** v1's matrix silently omitted **~19 shipping subsystems** — most damningly the
**Budget / spend-enforcement subsystem** (the product is named *BurnBar*), plus Google Cast, Home Assistant, the
SmartHub bridge server, **mDNS/Bonjour discovery** (a missing PAL seam), Mission Control, the Switcher multi-account
system, TextExpansion's **global keystroke-interception** hook, Elder Wand, Data Control Center, CursorConnector,
ProjectionPipeline, DailyDigest, and the full **Mercury media pipeline** (audio/mic/camera/VoIP/RFB, not just screen
mirror). All added to §10.1.

**Security-regression rows added (R14–R19):** App Check, DPAPI≠Keychain invariants, named-pipe peer-auth weakness,
`SendInput` making the capability-token gate advisory, the prompt-injection wrapper being a rewrite with no contract
vector, and signing-chain gaps (no notarization staple; DLL sideload defeats `WinVerifyTrust`).

**Process fixes:** gate criteria made falsifiable (§7.3 rubric); the "headless engine before UI" waterfall replaced
with a **Phase-1 walking-skeleton vertical slice** (auth needs UI, so the "headless" claim was false); the "freeze
PAL at G1" trap replaced with **per-seam semver freeze on second consumer**; factory scaling fixed (**sharded review,
single-owned shared files, rolling gates, per-workstream integration branches**); Phase 0 re-sized **S→M** with new
spikes; a **defensible sizing envelope** added (§14); and the Pet / secure-desktop "fast-follow" trapdoors converted
to an explicit **v1.1 non-goals list** (§15.1).

**Codex second-opinion pass (v2 → v2.1), verified against the code + web research.** A `/codex` consult
(read-only, code-verified) confirmed the v2 direction but showed three items were still under-scoped, and found one
new blocker:
- **The Core split is 24-file cross-cutting surgery, not "de-SwiftUI AgentProvider + peers."** Outside `Views/`,
  Codex found 24 non-UI files with unguarded UI/Apple imports — `PretextEngine` imports **WebKit + OSLog and owns a
  `WKWebView`**; `PretextTypes` imports CoreGraphics; `CloudVaultCrypto` imports Security; plus feature-flag and
  app-state types. `ComputerUseCore` adds **12 files** with Darwin/XPC/`audit_token_t`/Keychain entanglement
  (`PrivilegedInputXPCClient`, `ControllerKeyPinStore` Keychain-default). The split spans rendering, crypto, and app
  state — see the sharpened R21. (§9.2)
- **App Check: the concrete attestation *signal* was hand-waved.** Codex correctly flagged "Windows client → minting
  endpoint" is a bearer-token vending machine until the signal is named. Web research resolves it: the signal is
  **TPM hardware-backed key attestation** (Windows CNG `NCryptCreateClaim` / Windows Attestation APIs) verified by a
  **new Node Firebase-Admin backend** that then mints an App Check token via `createToken`. There is a **known
  `App attestation failed` bug on Windows 11 with the Admin SDK** (firebase-admin-node #2308) to validate in the
  spike. R14 updated from "existential unknown" to "hard but solvable — a real backend workstream." (§9.3, R14)
- **`wrapUntrusted` is a hard serialization predecessor, not a later cleanup.** W3/W4/W7 cannot safely run in
  parallel until it's extracted to Core and frozen — it's a security boundary with delimiter-defanging + truncation
  reseal. Now an explicit Phase-1 predecessor (§6.2, R18).
- **New blocker: Pretext is a `WKWebView`-backed engine** (bundled JS, cached prepared-text handles) called directly
  by chat surfaces — not "UI shell." Windows needs a **WebView2 + JS bridge** (or a native text-layout replacement)
  with its own parity tests. Added to §10.1 + R22.
- **SQLCipher parity pinning made concrete:** byte-compat holds only **within a SQLCipher major version**; the port
  must pin `cipher_compatibility` / `kdf_iter` / `cipher_page_size` and match the `porter unicode61` tokenizer +
  `bm25()`/`snippet()` ordering. The crypto provider can differ (Mac CommonCrypto vs. Windows OpenSSL/CNG) **iff
  algorithm params match** — so the real fix is explicit PRAGMA pinning (currently implicit in the Mac code). (R2, §9.2)
- **Swift-on-Windows reality check (web research):** officially supported since 2020 (Foundation/Dispatch/XCTest/SPM/
  LLDB), but the **Swift Windows Workgroup only formed Jan 2026** — an organizational-commitment signal, explicitly
  "still maturing." This *reinforces* keeping Option A spike-gated with a hard Option-B fallback (§4); the UI stays
  WinUI (Swift-on-Windows has no production UI story).
- **Estimate tempered:** Codex calls ~1,000–1,300 PRs optimistic given rework concentrates on PAL/DB/App Check/
  security/UI — §14 now states the envelope holds only if rework stays low and leans to the higher end for Option A.

---

## 1. Executive summary

The macOS app is large and deeply Apple-coupled, but the coupling is **localized behind seams**, and a meaningful
fraction of the logic is either **already cross-platform** or **cross-platform-shaped** — *after* two corrections
the adversarial pass forced: the "portable core" must first be **split away from ~30.7k LOC of in-core SwiftUI**, and
the **DB layer must be extracted from the app target**.

| Layer | Scale | Portability (corrected) |
|---|---|---|
| `AgentLens/` (macOS app target) | ~280k LOC / 792 Swift files | UI = rewrite; Services logic = extract + port-with-seams; **DB layer lives here** |
| `OpenBurnBarCore/` (shared SwiftPM) | ~120k LOC / 481 files | **~90k portable engine subset after removing 30.7k in-core SwiftUI**; requires Engine/UI target split first |
| `OpenBurnBarDaemon/` | ~50k LOC / 150 files | macOS-only host glue; portable *protocol shape* (Unix-socket JSON-RPC), but ~116 AF_UNIX + 85 codesign-peer-auth sites to redesign |
| Rust crates (`burnbar-remote`, `openburnbar-iroh`, `project-code-static-parser`) | 3 crates | **Already multi-target** (Apple + Android); add `*-pc-windows-msvc` — credible |
| Language-neutral contracts (`packages/`) | wire-protocol, data-domains, design-tokens, entitlements | **Reusable as-is** with CI parity locks |

**The load-bearing truths (updated):**

1. **The UI is a rewrite regardless of stack** (~118k app UI + ~30.7k in-core UI). SwiftUI has no production Windows
   backend.
2. **Firebase is gated by Apple-only App Check**, not just Auth. This is the single most likely launch-blocker and is
   *not* solvable client-side (R14). It needs a backend attestation provider or a written risk acceptance — decided
   at Phase 0.
3. **The agent-log ingestion engine is the product, is 100% macOS-pathed, and has no portable test fixtures yet.**
   16 parsers, path-remap, and a parser-output contract that **does not exist on any platform** and must be built
   before parity is even measurable (§11).
4. **The local DB is a crown-jewel exact-parity item on an unproven foundation** (GRDB has no Windows support;
   SQLCipher/FTS5 byte-compat unverified). Phase-0 spike or the whole "reuse the Mac DB + cross-device sync" premise
   is at risk (R2).

**Recommended shape:** a **WinUI 3 (C#/.NET) shell** over a native engine core whose strategy is **bound by Phase-0
spikes** (Option A = Swift-on-Windows engine reuse vs. Option B = Rust/C# reimplementation — §4). Rust
transport/crypto extends the **existing crates** with a Windows target. Cloud goes through a **Firestore REST
gateway *plus* a new App Check custom-attestation path**. The daemon becomes a **Windows Service** with hardened
**named-pipe IPC**.

**Velocity model:** 12 parallel workstreams, 6 phases, an **adversarial red-team gate between every phase**, a
**walking-skeleton vertical slice in Phase 1** to kill the big-bang integration risk, **sharded review + integration
branches** so the factory scales to ~1,000+ PRs, and **per-seam rolling gates** instead of fleet-wide convoy
barriers. Order-of-magnitude cost envelope in §14.

---

## 2. What "complete parity" means (parity contract)

Parity is defined per-capability, in three tiers, so the definition is honest and testable. **The full
subsystem-by-subsystem inventory is §10.1** — this section defines the tiers and the Windows-equivalent mappings.

- **Tier A — Exact parity.** Byte/behavior-identical: DB schema (all 53 migrations), wire protocol, CloudVault
  crypto, **prompt-injection `<UNTRUSTED_CONTENT>` wrapping**, parser token/cost/model output, entitlement math,
  Firestore documents. Verified by shared vectors.
- **Tier B — Functional parity via native equivalent:**

  | macOS | Windows equivalent |
  |---|---|
  | NSStatusItem menu-bar + NSPopover | `Shell_NotifyIcon` tray + borderless top-most flyout |
  | Keychain (`SecItem*`, `WhenUnlockedThisDeviceOnly` + LAContext) | **TPM/CNG `NCRYPT` KSP key, non-exportable, Hello-gated release** + DPAPI outer wrap — **NOT raw DPAPI** (R15) |
  | LaunchAgent + Unix socket + codesign peer gate | Windows Service (SCM) + named pipe with **SDDL DACL + `FIRST_PIPE_INSTANCE` + signed-nonce mutual handshake + loaded-module validation** (R16) |
  | `openpty` interactive sessions | ConPTY (`CreatePseudoConsole`) |
  | `posix_spawn` / `Process` (SIGTERM, exit-15-clean) | `CreateProcess` + Job Objects; **no SIGTERM** → `GenerateConsoleCtrlEvent`/`TerminateProcess` (rewrite exit-code logic) |
  | CGEvent input synthesis | `SendInput` — **advisory only** for non-bypassable actions; route those through ViGEm/driver (R17) |
  | CGEvent global keystroke-**interception** tap (TextExpansion) | `WH_KEYBOARD_LL` low-level hook + `SendInput` (harder than one-shot synthesis) |
  | AXUIElement inspection | UI Automation (`IUIAutomation`) |
  | ScreenCaptureKit / CGDisplayCreateImage | Windows.Graphics.Capture / DXGI Desktop Duplication / `BitBlt` |
  | AVFoundation audio/mic/camera + encoders (Mercury) | Media Foundation / WinRT MediaCapture + WASAPI |
  | Apple Remote Desktop RFB/VNC client | port RFB client (protocol is cross-platform) |
  | Bonjour / mDNS (`NWBrowser`/`NetService`, Cast/SmartHub/CursorConnector) | DNS-SD via Bonjour SDK or a managed mDNS lib — **new PAL seam** |
  | FSEvents / DispatchSource | `ReadDirectoryChangesW` / `FileSystemWatcher` |
  | UserNotifications | WinRT Toast |
  | Liquid Glass (`glassEffect`) | Mica / Acrylic |
  | SceneKit + GLTFKit2 (115 `.glb`) | glTF runtime (Phase-4 sub-spike) |
  | Carbon `RegisterEventHotKey` | Win32 `RegisterHotKey` |
  | LAContext (Touch ID) | Windows Hello — **consent gate only; must also gate key *release* via CNG** (R15) |
  | Sparkle-signed feed + custom updater | MSIX/WinSparkle/Squirrel with **pinned Ed25519 feed key** (R19) |
  | Homebrew cask | winget + Chocolatey |
  | virtual HID (`IOHIDUserDevice`, `hid.virtual.device`) | ViGEmBus (secure-desktop/lock-screen = signed-driver, v1.1) |
  | code-signature self-check (`DaemonSelfCodeSignatureVerifier`) | `WinVerifyTrust` **+ DLL-load hardening** (image-only check is insufficient — R19) |

- **Tier C — Parity by explicit substitution (Apple-only, no analog):** Sign in with Apple → MSA/Google/email OAuth;
  iCloud mirror → OneDrive/Firestore-only; App Intents/Siri → command palette + hotkey; MAS sandbox → MSIX identity;
  TCC prompts → in-app consent + UAC; **StoreKit IAP → Stripe web-checkout / Microsoft Store IAP** (winget-primary
  distribution has no IAP, so the purchase flow needs an explicit substitute — R-parity #12).

Each Tier-C row carries a **machine-checkable or signed-off "the substitute works" criterion** in §10 (no bare
dashes — that was a v1 gate hole).

---

## 3. Current-state architecture snapshot (from the 8-agent survey, corrected)

- **App ↔ daemon:** Unix-domain-socket JSON-RPC (~116 `AF_UNIX` sites), **not** XPC (XPC is only the privileged-input
  helper). Peer identity is **codesign/audit-token/`getpeereid`** (~85 sites), **bidirectional mutual attestation**,
  release-hardened (disable-env compiled out). → hardened named pipes (R16).
- **Local store:** GRDB + **SQLCipher (passphrase mode)**, **53 migrations** (`v1_initial`…`v53_memory_forget_outbox`),
  ~50 tables, **heavy FTS5**. Key = 256-bit AES in **Keychain** (`WhenUnlockedThisDeviceOnly`). **GRDB has no Windows
  support; the DB layer lives in `AgentLens/`, not Core** (R2, §9.3).
- **Cloud:** native FirebaseFirestore SDK (61 sites), FirebaseAuth (42, Google + Apple), **53 Functions callables**,
  Remote Config kill-switches, **App Check enforced fail-closed (Apple-only attestation — R14)**. E2EE via
  **Signal/HPKE CloudVault**.
- **E2EE/transport:** vendored **libsignal**, **Iroh** QUIC, **burnbar-remote** — all Rust/UniFFI, already building
  Apple xcframeworks **and** Android AARs (Windows = "add a third target"; UniFFI has no C# emitter → C-ABI shim).
- **Agent engine:** `CLIBridge` spawns local CLIs via `Process`. **16 log parsers**, **32 `AgentProvider` cases**,
  **20 quota adapters**, **11 `ChatBackendID`** engines. Quota via 4 mechanisms. Prompt-injection wrapping
  (`ContextBuilder.wrapUntrusted`, 22 sites) is a **hard invariant**.
- **Computer use:** `OpenBurnBarComputerUseCore` (37 Apple-only sites) + macOS glue. Capability tokens
  (Ed25519, attestation-bound), triple-independent kill-switch (hotkey + workspace + Remote Config), a **separate
  watchdog process**, a **red-team probe**.
- **UI:** ~118k LOC app + ~30.7k in-core. Highest risk: Theme (Liquid Glass + 30 substrates) and PetCompanion.
- **CI/release:** 47+ workflows; the **Android harness job is the second-platform template**. Release = Developer ID
  sign + notarize + staple + Ed25519 appcast + SBOM + Sigstore.
- **Tests:** ~4,500 app + ~1,860 Core + ~826 Daemon (XCTest). Cross-platform **KAT vector triplets** are the model to
  extend. **Gaps:** no portable parser fixtures, **no parser-output contract, no prompt-injection-wrapping contract**,
  CI-skipped snapshots, post-merge-only coverage.

### 3.1 Fact to confirm in Phase 0 (survey conflict)

Two survey passes disagreed on the updater: the release pipeline signs an Ed25519 `appcast.xml` via Sparkle's
`sign_update` and the Info.plist carries `SUFeedURL`/`SUPublicEDKey`, **but** the app ships a custom
`DirectDownloadUpdateService` and *no* `SPUUpdater` import. Interpretation: Sparkle at **release time for feed
signing**; **custom in-app updater**. Windows replicates the shipped Mac behavior; the Ed25519-signed feed + checksums
+ SBOM + Sigstore plumbing is reusable regardless (§12), and the Windows updater **must pin the Ed25519 feed key**
(R19).

---

## 4. The central decision: engine technology stack

The UI is a rewrite either way; the decision is **how much engine logic we reuse vs. reimplement** — and the
adversarial pass materially *lowered* Option A's reuse ceiling (in-core SwiftUI + DB-in-app + GRDB-no-Windows).

| Option | Engine | Reuse (corrected) | Risk |
|---|---|---|---|
| **A. Swift-on-Windows core + WinUI shell** | Split Core→`Engine` (no SwiftUI), compile on Swift-on-Windows; **extract** the DB layer from the app; swift-crypto (minus SecureEnclave); GRDB **or** raw-SQLCipher fallback | **~90k Core engine subset + extracted DataStore** (was overstated as 120k) | Swift-on-Windows maturity for Swift-6 strict concurrency; **GRDB-no-Windows**; Core/ComputeUseCore target-split cost; C-ABI ergonomics |
| **B. Rust core + WinUI shell** | Reimplement portable logic in Rust (extend crates), C#/C bindings | Contracts + Rust crates; **core logic rewritten** | Largest reimplementation; Rust↔C# volume |
| **C. Full C#/.NET** | Reimplement everything in C# | Contracts only | Best tooling, zero core reuse, highest LOC |
| **D. Electron + native** | Node/TS + Rust addons | Some web patterns | Weakest OS-native citizen; fights tray/overlay/computer-use |
| **E. Avalonia (.NET XAML)** | as A/B/C | Enables later Linux | Weaker Mica/Acrylic + Windows polish than WinUI |

**Recommendation (bound by Phase 0, not assumed): Option A primary, Option B fallback, WinUI 3 shell in all live
options.** Rationale unchanged — maximal reuse, single source of truth for portable layers, keep the Core test suite
protecting Windows — **but** the reuse premise now depends on three unproven things that Phase 0 must retire:

1. **0-a Core split + compile** — split `OpenBurnBarCore`→`Engine`/`UI` (and `ComputerUseCore`→policy/`Mac`), compile
   the Engine subset on Swift-on-Windows incl. swift-crypto (identify the SecureEnclave substitute). **Scope reality
   (Codex-verified):** this is **24 non-`Views/` files** with unguarded UI/Apple imports, not a move — the sharpest
   are `PretextEngine` (WebKit + `WKWebView` + OSLog), `PretextTypes` (CoreGraphics), `CloudVaultCrypto` (Security),
   plus feature-flag/app-state types; `ComputerUseCore` is 12 more Darwin/XPC/Keychain files. The spike must prove the
   split is *tractable*, not just started. **Swift-on-Windows is officially supported since 2020 but only got a
   governance Workgroup in Jan 2026 — treat maturity as an open question, which is exactly what this spike settles.**
2. **0-d DB byte-compat** — open a **real Mac SQLCipher DB** on Windows and prove parity concretely: **pin
   `PRAGMA cipher_compatibility`, `kdf_iter`, `cipher_page_size`** to the Mac's SQLCipher major version (byte-compat
   holds only *within* a major version), build with **`--enable-fts5`**, match the **`porter unicode61`** tokenizer,
   run an FTS5 `MATCH` with `bm25()`/`snippet()` returning an **identical row set**, migrate to **v53**, assert
   **schema hash == Mac**, write a row, reopen on Mac. The crypto provider may differ (Mac CommonCrypto vs. Windows
   OpenSSL/CNG) **iff algorithm params match** — so the spike also **adds explicit PRAGMA pins** (currently implicit
   in the Mac code — a latent risk on *both* platforms). **If GRDB won't build on Windows, prove the raw-SQLCipher-C
   fallback here.**
3. **0-e Firebase Auth + App Check** — interactive desktop OAuth (loopback redirect) → Firebase custom-token → an
   authenticated Firestore REST read/write, **and** prove the App Check custom-provider pipeline end-to-end: a
   Windows client mints a **TPM hardware-backed key attestation** (CNG `NCryptCreateClaim` / Windows Attestation
   APIs) → a **new Node Firebase-Admin backend** verifies it → `createToken` mints an App Check token → an enforced
   callable accepts it. **Validate the known Windows-11 Admin-SDK `App attestation failed` bug (firebase-admin-node
   #2308) does not block minting.** If the TPM pipeline can't be stood up in the spike window, **this PIVOTS the cloud
   strategy** (open decision #6: fund the backend, ship a weaker MSIX-identity signal, or ship local-only v1).

Plus 0-b (WinUI shell + tray + Mica + live CLI stream), 0-c (iroh/burnbar-remote → `x86_64-pc-windows-msvc` + call
from C# via `uniffi-bindgen-cs` round-tripping one async+callback+error interface), 0-f (ConPTY interactive +
named-pipe peer-auth handshake), 0-g (**ARM64 build-only** proof), 0-h (real **Claude Code Windows path encoding**).

**G0 exit is a written go/no-go with pre-registered abort conditions** (§7.3) — Option A aborts to B if, e.g., the
Engine subset can't compile clean, FTS5 returns a non-identical row set, or the DB can't open. **App Check with no
Windows story escalates to Alberto as a scope decision, not a silent Phase-3 surprise.**

---

## 5. Reuse ledger (corrected)

**Reusable as-is (language-neutral, CI-locked):** `packages/hermes-wire-protocol/protocol.json` (parity-locked),
`data-domains/registry.json`, `design-tokens` (+ WinUI emitter), `entitlements`; the Firebase backend + Cloud Run
relays (client-agnostic); `crates/project-code-static-parser` (pure Rust); Node tooling (`tools/openburnbar-mcp*`,
`extensions/openburnbar`); the KAT vectors (extend with a Windows copy).

**Portable-with-work:** `burnbar-remote` + `openburnbar-iroh` (Windows target + C-ABI/C# binding + Credential-Manager
backend behind a feature); **libsignal** (Windows binding); CloudVault crypto (reimplement vs. vectors);
**`ContextBuilder.wrapUntrusted`** — *move into Core* so Option A reuses it instead of rewriting (R18); `website/`
distribution (Windows section + non-Sparkle updater).

**Not reusable as code (reference-only):** `AgentLens/` SwiftUI + the **~30.7k in-core SwiftUI Views** + `OpenBurnBarMobile` + `android/app` Compose; `OpenBurnBarCore` under Option B/C; Python `gateway/` `__pycache__`.

**Requires extraction before reuse (new category the review surfaced):** the **DataStore/DB layer** (46 GRDB files in
`AgentLens/`); `wrapUntrusted`; the ComputerUseCore policy/crypto (split from Mac glue).

---

## 6. Parallelism model

The brief is **"extremely parallelism focused."** The plan is **12 workstreams** running concurrently within each
phase, synchronized at **rolling per-seam gates** (not fleet-wide barriers, except the two genuine cross-cutting ones:
stack-bind at G0, PAL contract at G1). Inside a workstream, work is a stream of small factory PRs.

### 6.1 The 12 workstreams

| # | Workstream | Owns | Critical path? |
|---|---|---|---|
| **W0** | **Distribution/identity procurement** (non-eng, calendar-bound) | Authenticode/EV or Azure Trusted Signing cert, Store account, winget publisher — **lead-time items agents can't parallelize away** | starts Phase 0 |
| **W1** | **Platform Abstraction Layer (PAL)** | FS paths, secret store, process/ConPTY, named-pipe IPC, toasts, tray, watchers, autolaunch, hotkey, single-instance, **mDNS/Bonjour**, self-signature check | **spine** |
| **W2** | **Native core / crypto / transport** | Core Engine/UI split, Rust Windows targets + bindings, libsignal-Windows, DB engine (SQLCipher+FTS5), swift-crypto/SecureEnclave substitute | **spine** |
| **W3** | **Data & sync** | 53-migration schema parity (extracted DataStore), Firestore REST gateway, **App Check custom provider**, CloudVault crypto, on-disk layout | **cloud blocked on R14** |
| **W4** | **Agent integration engine** | CLIBridge, 16 parsers + path remap, **all 20 quota adapters / 32 providers**, session ingestion, MCP/settings hooks, **ManagedAgentRuntime (Pi supervision + Redis)**, CursorConnector | no (after W1) |
| **W5** | **Computer use** | SendInput/UIA/WGC/ConPTY, capability tokens, audit chain, **watchdog process**, kill-switch (fail-closed-on-RC-error), ViGEm, daemon approval | no |
| **W6** | **UI shell + design system** | WinUI app, tray flyout, Mica/Acrylic glass, 30-substrate particle engine, theme tokens, Pretext markdown host | blocks W7 |
| **W7** | **UI surfaces** | Dashboard, Chat (+ **Elder Wand**), Insights (+ template gallery), Quota, SessionLogs, Settings (+ **Budget, Data Control Center, Switcher**), Onboarding, Memory, **Mission Control** | no (after W6) |
| **W8** | **PetCompanion** | glTF runtime, transparent click-through overlay, behavior graph, chat bubble | no |
| **W9** | **Integrations: Cast / HomeAssistant / SmartHub / Media-Mercury** | Google Cast (TLS+mDNS), Home Assistant, SmartHub bridge server, full Mercury pipeline (audio/mic/camera/VoIP/RFB/file-transfer) | no |
| **W10** | **CI / release / distribution** | Windows harness lane, Authenticode/Trusted Signing, MSIX + winget + Choco, update feed, ratchets/budgets (per-tree), diff-coverage on PRs | **enable Phase 0** |
| **W11** | **Verification / parity harness** | Portable parser fixtures, **parser-output contract**, **prompt-injection-wrap contract**, KAT triplet→Windows, DB-compat vector, e2e session-replay corpus, snapshot strategy | **enable Phase 0** |

(v1 had 10 workstreams; the review split out W0 procurement and W9 integrations, which were silently folded into
"UI surfaces" and hand-waved.)

### 6.2 Dependency graph and the anti-waterfall vertical slice

```
Phase 0 spikes ─► BIND STACK (G0) ─► Phase-1 WALKING SKELETON (one provider→parse→auth→one dashboard tile, e2e)
                                          │  (proves PAL/core/UI seams together BEFORE wide fan-out)
W1 PAL ───────────┬─► W4 Agent engine ──► functional peer
W2 Native core ───┼─► W3 Data & sync ───► persistence + cloud (blocked on R14 App Check)
                  ├─► W5 Computer use
                  └─► W8/W9 (transparent-window / capture PAL bits)
W6 UI shell+DS ──────► W7 UI surfaces
W10 CI  ── gates every PR from Phase 1     W11 Parity harness ── fixtures/vectors land Phase 1, assert from Phase 2
```

- **The walking skeleton is mandatory and comes before the fan-out.** v1's "headless engine (Phase 2) then UI
  (Phase 3), integrate late" was a big-bang trap — and its own G2 criterion (cloud sync) secretly needs interactive
  auth UI. The Phase-1 skeleton wires PAL + engine + a minimal auth flow + one live dashboard tile end-to-end so
  every critical seam has a real consumer **before** it's frozen.
- **PAL/core seams freeze per-seam on the *second real consumer*, under a semver contract** (additive-and-deprecate
  allowed; breaking changes gated) — **not** a calendar freeze at G1 with consumers that don't exist yet. Seam
  **stubs/mocks publish day one** so consumers build in parallel with the real impl.
- **W1/W2 are staffed as independent parallel sub-lanes** (path, secret store, process/PTY, IPC, watchers, mDNS each
  shippable independently) so the spine isn't a single convoy lane.
- **W3 cloud is gated on R14** (App Check). Local persistence proceeds; cloud sync waits on the attestation decision.
- **W10 + W11 enable at Phase 0** so every production PR is gated by the Windows CI lane and asserts against parity
  vectors from the first commit — no post-merge coverage theater.
- **Serialization predecessors (Codex-surfaced) that gate the "parallel" fan-out — these land in Phase 1 before the
  wide parallel work, or the parallelism is a lie:**
  1. **Core `Engine`/`UI` split** (24-file refactor) — nothing compiles on Windows until it lands (§9.2, R21).
  2. **`wrapUntrusted` extracted to Core + frozen** — W3 (cloud), W4 (agent), W7 (chat/UI) all route untrusted content
     through it; parallelizing them before it's extracted risks divergent security reimplementations (R18).
  3. **`Pretext` engine decision** (WebView2 vs. native) — chat surfaces (W7) depend on it (R22).
  4. **PAL seam stubs + DB engine open-path** — the walking skeleton needs these to exist as contracts.

### 6.3 Factory operating model (scaled for ~1,000+ PRs)

Per `docs/SOFTWARE_FACTORY_PR_LOOP.md`, **hardened for port scale** (v1 would have deadlocked on a single reviewer +
shared-file thrash):
- **New label `area: Windows`** + CODEOWNERS for the Windows tree.
- **Sharded review:** per-workstream reviewer identities (each an independent Codex instance with a scoped rubric); a
  single cross-cutting reviewer only for spine/shared-file PRs. A **merge queue** absorbs rebase churn.
- **Single-owned shared files:** only W10 edits `budgets/*`, the harness, `labels.yml`; **budget accounting is
  partitioned per-tree** (Windows counters can't collide with macOS or each other); design-tokens/bindings are
  **generated-and-owned-by-one-lane** to avoid nondeterministic regen diffs. Everyone else files a request.
- **Per-workstream integration branches** merge to `main` at gate boundaries; a **dependency tracker** links each
  `OPEN_WITH_NAMED_BLOCKER` PR to the seam that unblocks it; a coordinator drains the blocked pile each gate.
- **Rolling per-seam gates**, not hard phase barriers, wherever dependencies allow — a finished lane advances without
  waiting for the whole phase.
- **Ratchets scoped to include the Windows tree from commit #1.** Codex approves; branch protection merges;
  cross-agent receipts on every reaction. **No laundering unfinished work into main.**

---

## 7. Adversarial review protocol (between every phase)

The brief demands **adversarial review between phases** — and this document is itself the product of one (§0.1),
which is why the gates below are written to be **falsifiable**, not aspirational.

### 7.1 How a gate works

At each barrier, an **independent red-team** (agents that did **not** build the phase, judged against
**pre-registered** criteria) runs: **claim harvest → diverse-lens refutation (parallel) → verdict quorum →
synthesize GO/FIX/PIVOT**, mirroring the factory review workflow. Lenses: correctness, parity-gap, false-parallelism,
**security-regression**, Windows-idiom.

### 7.2 Gate independence (structural, not aspirational)

v1 asserted "critics that didn't build the phase" but couldn't guarantee it. v2 enforces: **pre-register pass/fail
criteria before the phase runs**; withhold the builders' rationale from at least one **cold** critic; require a
**written refutation attempt even on GO**; and **forbid any builder from reviewing an adjacent seam they consumed.**

### 7.3 Gate ledger — falsifiable exit criteria

Every criterion below is machine-checkable or has a named artifact + sign-off. (v1's vague "renders," "works
end-to-end," "visually reviewed" are replaced.)

| Gate | After | Exit criteria (all required) |
|---|---|---|
| **G0** | Phase 0 | Stack bound A/B against **pre-registered abort conditions**; 0-d opens a real Mac DB + FTS5 identical row set + migrate-to-v53 + schema-hash==Mac; **0-e resolves the App Check posture** (custom provider costed OR risk-accepted in writing OR PIVOT-to-Alberto); iroh/burnbar-remote round-trip a **byte-identical wire vector from C#**; a `claude --output-format stream-json` run yields N parsed events diffed vs. a Mac run; ARM64 builds; real Claude Code Windows path encoding captured as a fixture |
| **G1** | Phase 1 | **Walking skeleton runs end-to-end** (one provider → parse → interactive auth → one live dashboard tile); PAL seams under semver with ≥2 real consumers each; named-pipe IPC round-trips daemon JSON-RPC **with the hardened peer-auth handshake**; all 15 parser fixture-builders **extracted to on-disk files** with a Mac test proving identical output vs. the old inline builder; Windows CI lane **blocks a deliberately-red PR** |
| **G2** | Phase 2 | A recorded **multi-provider session corpus parses to byte-identical** token/cost/model output vs. a Mac golden (the headline); **prompt-injection-wrap contract vector passes**; quota works for **≥1 provider per mechanism (all 4)**, value-matched to Mac; cloud sync does a **cross-platform** E2EE round-trip on the **two hardest domains, both directions** (Windows-seal→Mac-open AND Mac-seal→Windows-open) — **or** App Check is formally deferred with the cloud criterion moved to Phase 3 |
| **G3** | Phase 3 | Each of the 12 view areas passes a **per-surface acceptance script** (empty/loading/error/populated + named interactions); **all 30 substrates + 3 glass modes** pass a pre-registered per-item rubric with **committed side-by-side capture artifacts + named human sign-off + written acceptable-drift note**; DPI matrix (100/125/150/200% + mixed) and **full keyboard-only traversal** and **ARM64 runs the whole functional suite** |
| **G4** | Phase 4 | Computer-use: kill-switch halts mid-action within a stated bound **across all three panic paths**, deny-regions enforced, **capability-token replay rejected**, **audit-chain tamper detected**; pet: named behavior-graph transitions fire on named chat events + **click-through verified by an input-passthrough test**; Mercury: a known frame sequence decodes within a latency bound |
| **G5** | Phase 5 | Signed MSIX installs + **auto-updates from the live Ed25519-pinned feed** (recorded); winget manifest merged; **every parity-matrix row (incl. Tier-C) green with committed evidence**; launch-evidence bundle contains signed-installer hash, update recording, full parity result set, KAT/DB/parser/wrap vector logs, SBOM/Sigstore attestation, crash-free session |

**No phase starts until the prior gate returns `GO`** (for the two hard barriers G0/G1); elsewhere, rolling per-seam
gates let finished lanes proceed. `FIX` loops within the phase; `PIVOT` escalates to Alberto with evidence.

---

## 8. Phase plan

Sizes are relative parallel-agent effort; §14 gives the order-of-magnitude envelope. The point is the **dependency
structure and gates** — velocity comes from width, but §14 also names the calendar-bound items width can't dissolve.

### Phase 0 — De-risk & bind · size **M** (was S) · gate **G0**
Nine spikes (§4: 0-a…0-h + Core/ComputeUseCore split feasibility), the empty Windows solution tree, `area: Windows`,
a **skeleton Windows CI job**, and **W0 procurement kicked off** (cert/Store/winget lead-times). **G0 is a genuine
go/no-go with Alberto**, because 0-d (DB) and 0-e (App Check) can invalidate the approach. *Exit:* per G0.

### Phase 1 — Foundation + walking skeleton · size L · gate **G1**
Parallel: **W1 PAL** (seams under semver, stubs day one), **W2 native core** (Core split, Rust artifacts, libsignal,
DB engine), **W3 (start)** schema parity + the **App Check custom provider** (if that path was chosen at G0),
**W10** full Windows PR lane + per-tree ratchets, **W11** extract parser fixtures + stand up the parser-output and
prompt-injection-wrap contract formats + the DB-compat vector. **The walking skeleton is the gating deliverable.**
*Exit:* per G1.

### Phase 2 — Engine parity · size XL · gate **G2**
Parallel: **W4** CLIBridge + 16 parsers (path-remapped) + all 20 quota adapters + ManagedAgentRuntime + CursorConnector;
**W3** DataStore + Firestore REST + CloudVault; **W2** finishes crypto/transport. Goal: a peer that ingests local
logs, aggregates usage/cost, and (if App Check resolved) syncs E2EE — provable against the W11 corpus. Auth UI from
the skeleton is reused, so cloud isn't secretly UI-blocked. *Exit:* per G2.

### Phase 3 — UI parity · size XL · gate **G3**
**W6** shell + design system + 30-substrate engine + Mica/Acrylic + Pretext (blocks W7); then **W7** surfaces fan out
— Settings/SessionLogs/Onboarding/Memory are high-parallelism, but **Budget, Data Control Center, Switcher, Elder
Wand, Mission Control, Insights templates are real feature work, not mechanical volume** (§10.1). *Exit:* per G3.

### Phase 4 — Advanced / high-risk · size L · gate **G4**
Parallel: **W5** computer use (SendInput/UIA/WGC/ConPTY + capability tokens + **watchdog process** + fail-closed
kill-switch + ViGEm), **W8** PetCompanion (glTF runtime sub-spike + transparent overlay + behavior graph),
**W9** Cast/HomeAssistant/SmartHub-bridge/**full Mercury** (audio/mic/camera/VoIP/RFB/file-transfer). Deepest OS
coupling, lowest inter-dependency. *Exit:* per G4.

### Phase 5 — Distribution & certification · size M · gate **G5**
**W10** Authenticode/Trusted Signing + MSIX + winget/Choco + update feed (Ed25519-pinned) + **DLL-load hardening** +
SBOM/Sigstore; **W11** full parity-matrix certification + launch-evidence bundle. **W0's cert/Store/winget external
lead-times must already be retired** (started Phase 0). *Exit:* per G5.

---

## 9. Workstream deep-dives

### 9.1 W1 — Platform Abstraction Layer (the spine)

Freeze **per-seam on the second consumer**, under semver; publish stubs day one.

| Seam | macOS source | Windows target |
|---|---|---|
| Path resolution | `~/Library/Application Support/…` | `%LOCALAPPDATA%\OpenBurnBar\`, `%APPDATA%\OpenBurnBar\`; watch `MAX_PATH` |
| Secret store | `SecItem*` (108 sites), 16 stores, `ThisDeviceOnly` + LAContext | **TPM/CNG NCRYPT KSP (non-exportable, Hello-gated) + DPAPI wrap**, split into device-bound/biometric/plain classes (R15) |
| Process spawn | `Process`/`posix_spawn`, SIGTERM, exit-15-clean | `CreateProcess` + Job Objects; `GenerateConsoleCtrlEvent`/`TerminateProcess`; **rewrite exit-code logic** |
| Interactive PTY | `openpty`, Terminal.app launch, `pgrep -P`/`kill -TERM` | **ConPTY**; `wt.exe`/`conhost`; `taskkill /T` or Job Objects |
| App↔daemon IPC | ~116 `AF_UNIX`, codesign peer gate (~85 sites), bidirectional | Named pipe + **SDDL DACL + `FIRST_PIPE_INSTANCE` + signed-nonce mutual handshake + loaded-module validation + release-hardened** (R16) |
| Executable discovery | PATH `:`, `/bin/zsh -lic`, exec bit | PATH `;`, `PATHEXT`, `where`/PowerShell, `%ProgramFiles%`, npm/volta/fnm Windows dirs |
| File watching | FSEvents (19) / DispatchSource (4) | `ReadDirectoryChangesW` / `FileSystemWatcher` |
| **Service discovery** | **Bonjour/mDNS `NWBrowser`/`NetService` (~168 sites: Cast, SmartHub, CursorConnector, gateway)** | **DNS-SD (Bonjour SDK) or managed mDNS — new seam v1 omitted** |
| Notifications | UserNotifications (7 files) | WinRT Toast |
| Tray + flyout | NSStatusItem + NSPopover | `Shell_NotifyIcon` + borderless top-most flyout |
| Autolaunch | `SMAppService.mainApp` | Run key / Startup / Task Scheduler |
| Privileged daemon | root LaunchDaemon + launchctl | Windows Service (SCM) |
| Global hotkey | Carbon `RegisterEventHotKey` | Win32 `RegisterHotKey` |
| **Global keystroke interception** | **CGEvent session tap (TextExpansion, swallows the trigger key)** | **`WH_KEYBOARD_LL` + `SendInput`** |
| Single instance | (implicit) | Named mutex |
| Self-signature check | `DaemonSelfCodeSignatureVerifier` (SecCode) | `WinVerifyTrust` **+ DLL-load hardening** (R19) |

### 9.2 W2 — Native core / crypto / transport

- **Core split first (bigger than a move — Codex-verified):** `OpenBurnBarCore` → `…Engine` (no SwiftUI/AppKit — the
  portable subset) + `…UI` (the 30.7k SwiftUI, reference-only). Beyond `Views/`, **24 non-UI files carry unguarded
  UI/Apple imports** and must be untangled or Mac-gated: `AgentProvider.swift` (SwiftUI), **`PretextEngine`/`PretextTypes`
  (WebKit + `WKWebView` + OSLog + CoreGraphics — see the Pretext port, §9.6/R22)**, `CloudVaultCrypto` (Security),
  and feature-flag/app-state types. `OpenBurnBarComputerUseCore` splits into policy/crypto + `Mac` glue, but that glue
  is **12 files** deep (`PrivilegedInputXPCClient` = Darwin/NSXPC/`audit_token_t`/Unix-socket; `ControllerKeyPinStore`
  = Keychain-backed production default). This is a **prerequisite refactor spanning rendering, crypto, and app state**,
  landed on macOS first (no behavior change) so the Mac build keeps protecting it — sized accordingly (R21).
- **Rust → Windows:** add `x86_64/aarch64-pc-windows-msvc` to `openburnbar-iroh` + `burnbar-remote`; build `.dll`/`.lib`
  (mirror the `-android-aar` scripts/workflows into `Vendor/`); Credential-Manager backend behind a feature; C-ABI
  shim consumed from C# (`uniffi-bindgen-cs` proven in 0-c). **libsignal** gets the same Windows binding.
- **DB engine:** SQLCipher **passphrase mode** (`usePassphrase` → PBKDF2, *not* raw-key) + **FTS5**, byte-compatible.
  Byte-compat holds only **within a SQLCipher major version**, so the port must **pin `cipher_compatibility`,
  `kdf_iter`, `cipher_page_size`** to the Mac's major version, build with `--enable-fts5`, and match the
  `porter unicode61` tokenizer + `bm25()`/`snippet()` query semantics. The crypto provider may differ (Mac
  CommonCrypto vs. Windows OpenSSL/CNG) **iff those params match**. These PRAGMAs are currently **implicit in the Mac
  code** (`DatabaseEncryptionService.usePassphrase`, no explicit compat/kdf pins) — a latent risk on both platforms;
  W2 **makes them explicit**. **GRDB-for-Windows is unproven (R2)** — primary path compiles the vendored GRDB;
  **fallback is raw SQLCipher-C + a thin data layer** reproducing the exact pinned config. Decided in 0-d.
- **Crypto shim:** swift-crypto covers AES-GCM/HKDF/SHA/P256; **SecureEnclave has no swift-crypto equivalent** →
  TPM/CNG-backed non-exportable key for the `PhoneControlAuthoritySigningKey` path, with a written downgrade note
  (R15).

### 9.3 W3 — Data & sync

- **Schema parity:** reproduce all **53 migrations** + ~50 tables incl. FTS5 virtual/shadow tables. **The DataStore
  (46 GRDB files) must be extracted from `AgentLens/` first** (it is not in Core). Verify by opening a real Mac DB +
  schema-hash + round-trip (the 0-d/G1 vector).
- **Firestore REST gateway:** implement `CloudSyncFirestoreGateway` against Firestore REST + **the 53 callables**;
  the `…FakeGateway` seam + 14 `OpenBurnBarFirestoreModels` types are the contract.
- **App Check (R14, the blocker) — the concrete pipeline:** the custom provider is the **documented, supported path
  for "desktop OSes"** (Firebase docs). The named attestation **signal** (this is the part Codex flagged as
  hand-waved, now resolved): the Windows client mints a **TPM hardware-backed key attestation** (Windows CNG
  `NCryptCreateClaim` / Windows Attestation APIs — hardware-rooted, not a bare bearer secret); a **new secure Node
  Firebase-Admin backend service** verifies the TPM claim (AIK/EK chain + nonce) and calls `createToken` to mint the
  App Check token; the client's `getToken()` returns it (TTL 30 min–7 day, default 1 h). **Validate firebase-admin-node
  #2308** (`App attestation failed` on Windows 11) in the 0-e spike. **Weaker fallbacks if the TPM path slips:** MSIX
  package-identity signal (weaker assurance, written risk acceptance) or Windows-local-only v1 (open decision #6).
  **High-risk computer-use callables** (`assertAppAttestBoundClaims`) bind the *Apple* App Attest app-id; do **not**
  relax that server gate for all platforms — either the Windows TPM attestation feeds an equivalent bound claim, or
  those specific callables are documented as server-refused on Windows.
- **CloudVault crypto:** reimplement P-256 ECDH + HKDF-SHA256 + AES-256-GCM vs. `apps/console/lib/escrow.ts` + the
  Swift/Kotlin vectors (cross-platform decrypt, both directions).
- **On-disk layout:** map every Application-Support subtree.

### 9.4 W4 — Agent integration engine (the product core)

- **CLIBridge:** port resolve→build-args→spawn→stream for all engines + HTTP gateways (SSE ports nearly unchanged).
  Exact CLI invocations are load-bearing. **`wrapUntrusted` prompt-injection wrapping must be preserved and
  contract-tested** (R18) — move it into Core.
- **16 parsers + path remap** (biggest Windows-specific task): remap every `logDirectory`/`filePattern`; handle
  Claude Code's **`C--Users-…` vs `-Users-…`** encoding (captured in 0-h).
- **All 20 quota adapters / 32 providers** (not a sample): the 4 mechanisms incl. the **Claude statusline hook**
  (`.cmd`/PowerShell wrapper + `FileSystemWatcher`) and `state.vscdb` scraping.
- **ManagedAgentRuntime:** Pi-agent **process supervision + Redis discovery** — *not* a stateless SSE client (v1
  mislabeled it "ports unchanged"). **CursorConnector:** log-stream + Bonjour secret broker.
- **MCP/settings hooks:** Node tools already run on Windows; the settings-writer Windows-path-escapes.

### 9.5 W5 — Computer use

Split `OpenBurnBarComputerUseCore` (policy/crypto ports; 37 Apple-only sites do not). CGEvent→`SendInput` (**advisory
for non-bypassable actions — route those through ViGEm/driver**, R17), AXUIElement→UIA, capture→WGC/DXGI, LAContext→
Hello (+ CNG key-release), virtual HID→ViGEm (secure-desktop = v1.1 signed driver). **Preserve the triple kill-switch
as a separate Windows watchdog process with a signed local kill channel independent of attestation-gated Remote
Config, carrying fail-closed-on-RC-error verbatim** (R17). Capability-token issuance/audit-chain/deny-regions/panic-
halt preserved; high-risk server gate ties to R14.

### 9.6 W6 — UI shell + design system

WinUI 3 shell, `Shell_NotifyIcon` tray + resizable/reorderable flyout, main window. **Glass:** the single
`Theme/LiquidGlass.swift` chokepoint → one Mica/Acrylic shim (Frosted↔System↔Clear + reduced-transparency).
**Particle engine:** reimplement `SwarmCanvasView` + `SwarmSubstrate.paint` (30 substrates, 6 families) on Win2D/
Composition — a real port. **Design tokens:** WinUI emitter added to `packages/design-tokens`. **Pretext** is **not** a plain markdown host: it is a
`WKWebView`-backed rendering engine (bundled JS, cached prepared-text handles) called directly by chat surfaces, so
the Windows port needs a **WebView2 + JS bridge** (reuse the same bundled JS) or a native text-layout replacement —
with its own parity tests (R22). This is real engine work, sized separately from the shell.

### 9.7 W7 — UI surfaces

Fan out across the 12 `Views/` areas + the in-core UI. **High-parallelism/low-risk:** Settings shell, SessionLogs,
Onboarding, Memory. **Real feature work (not "mechanical"):** Budget settings, Data Control Center (custom flip/basin/
inspector + callables), Switcher account UI, Elder Wand configurator, Mission Control console, Insights template
gallery. **Custom-canvas:** Dashboard (5 concepts + easter-egg physics), Chat (streaming state machine, tool cards,
atom-router), Quota (constellation orbs, arc dials).

### 9.8 W8 — PetCompanion (isolated, highest-effort)

glTF runtime sub-spike (WebView2+three.js vs. native D3D/Assimp); transparent click-through overlay
(`WS_EX_LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE` + per-pixel hit-test); behavior graph (portable logic); chat
bubble reuses ported `ChatSessionController`.

### 9.9 W9 — Integrations (Cast / HomeAssistant / SmartHub / Media-Mercury)

The subsystems v1 hid inside "UI surfaces":
- **Google Cast** (`Services/Cast/`, 12 files): Cast-over-TLS protocol + mDNS discovery + setup wizard.
- **Home Assistant** (`Services/HomeAssistant/`, 8 files): client, provisioner, blueprint installer, token store.
- **SmartHub bridge server**: embedded HTTP bridge + Bonjour advertiser + PixelClock/NestHub display config — a
  **backend**, not a XAML view.
- **Mercury media (`Services/Media/`, 19 files):** screen mirror **plus** audio/mic/camera capture + encoders
  (Media Foundation/WASAPI), **VoIP call trigger** (APNs-VoIP → Windows push substitute), **RFB/VNC client**, file
  transfer, consent + media-budget stores.

### 9.10 W10 — CI / release / distribution

Add a Windows harness job mirroring the **Android** pattern (build+lint+unit+**diff-coverage on PRs**+artifact),
registered in `platform-confidence-gate`; `pr-windows-fast.yml`; per-tree ratchets/budgets from commit #1;
`build-iroh-windows.yml` + `build-burnbar-remote-windows.yml`. **Signing:** Authenticode via **Azure Trusted
Signing** + **DLL-load hardening** so `WinVerifyTrust` gains a library-validation equivalent (R19). **Packaging:**
MSIX + portable zip; auto-update from the **Ed25519-pinned** feed; winget + Chocolatey. SBOM/OpenVEX/Sigstore over
Windows artifacts. Register Windows version surfaces in `verify-version-consistency.sh`.

### 9.11 W11 — Verification / parity harness

Close the gaps that make parity unmeasurable: **extract the 15 inline parser fixture builders to on-disk files**
(precondition for W4); build the **parser-output contract** (Swift↔Windows identical `TokenUsage`/session/cost/model
— does not exist on any platform pair yet); build the **prompt-injection-wrap contract vector** (embedded
`</UNTRUSTED_CONTENT>` + "ignore previous instructions" → byte-match incl. neutralization/re-seal/provenance — R18);
extend the **KAT triplet** to a Windows copy under the fail-closed check; the **DB-compat vector**; a
**multi-provider e2e replay corpus** with a Mac golden (G2 headline); a **Windows-native snapshot baseline** + a
manual design-review checkpoint vs. macOS goldens (they can't auto-gate cross-platform).

### 9.12 W0 — Distribution/identity procurement (non-engineering, calendar-bound)

Acquire the Authenticode/EV cert **or** Azure Trusted Signing tenant (identity-validation lead time), the Microsoft
Store publisher account (cert validation), and the winget publisher path (Microsoft-reviewed manifest PR). **These
gate G5 on external humans, not agents** — start them at Phase 0 (§14).

---

## 10. Parity matrix

### 10.1 Full subsystem inventory (completeness ledger)

Every shipping macOS subsystem, so nothing is silently dropped (the review found ~19 missing from v1). Tier per §2;
WS = owning workstream.

| Subsystem | macOS location | Windows approach | Tier | WS |
|---|---|---|---|---|
| Local encrypted store (53 migrations, FTS5) | `AgentLens/Services/DataStore/` (in app!) | Extract + SQLCipher/FTS5 byte-compat | A | W2/W3 |
| DB key + 16 secret stores | Keychain `ThisDeviceOnly` + LAContext | TPM/CNG KSP + DPAPI wrap (R15) | B | W1 |
| Agent-log ingestion (16 parsers) | `Services/LogParser/` | Path-remapped parsers | A(out)/B(paths) | W4 |
| Usage/cost aggregation | `Services/UsageAggregation/` | Port | A | W4 |
| **Quota (20 adapters, 4 mechanisms)** | `Services/ProviderQuota/` | All 20, Windows-pathed | B | W4 |
| Chat (11 backends, CLI + SSE) | `Services/CLIBridge/` | CreateProcess + SSE | B | W4 |
| **Prompt-injection wrapping** | `Services/ContextBuilder.swift` (22 sites) | Move to Core + contract vector | A | W4/W11 |
| **ManagedAgentRuntime (Pi + Redis)** | `Services/ManagedAgentRuntime/` | Process supervision + Redis | B | W4 |
| **CursorConnector** | `Services/CursorConnector/` | Log-stream + mDNS broker | B | W4 |
| **ProjectionPipeline (embeddings jobs)** | `Services/ProjectionPipeline/` | Port (rewrite under Option B) | A/B | W2/W4 |
| Cloud sync (E2EE) | `Services/CloudSync/` (33 files) | Firestore REST + CloudVault | A/B | W3 |
| **Firebase App Check attestation** | `OpenBurnBarAppCheckProviderFactory` | **Custom provider or risk-accept (R14)** | — | W3 |
| E2EE / Signal | libsignal + HPKE | libsignal-Windows + vectors | A | W2 |
| P2P relay (Iroh/burnbar-remote) | Rust crates | windows-msvc target | A | W2 |
| App↔daemon IPC | Unix socket + codesign gate | Hardened named pipe (R16) | B | W1 |
| Daemon lifecycle | LaunchAgent | Windows Service | B | W1 |
| Computer use | ComputerUseCore + Mac glue | SendInput/UIA/WGC/ViGEm (R17) | B (secure-desktop C) | W5 |
| **Budget rules / enforcement / notifications** | `DataStore/Budget*`, `Views/Settings/BudgetSettingsView` | Port (core product!) | A | W3/W7 |
| **Mission Control / MissionsLane** | `Views/Dashboard/Missions*`, `CloudSync/CLIAgentMission*` | Port + Firestore dispatch | A/B | W7 |
| **Switcher multi-account** | `Services/Switcher*`, `Views/Settings/AccountSwitcher/` | Port | B | W4/W7 |
| **Elder Wand configurator** | `Views/Chat/ElderWand/` | Port | B | W7 |
| **Data Control Center / privacy indexing** | `Views/Settings/DataControlCenter/`, callables | Port | B | W7 |
| **Insights (+ template gallery/canvas)** | `Views/Insights/` | Charts + canvas + templates | B | W7 |
| **Google Cast** | `Services/Cast/` (12 files) | Cast-TLS + mDNS | B | W9 |
| **Home Assistant** | `Services/HomeAssistant/` (8 files) | Port client | B | W9 |
| **SmartHub bridge server** | `Services/SmartHub/…BridgeServer` | HTTP bridge + Bonjour advertiser | B | W9 |
| **mDNS/Bonjour discovery (PAL seam)** | `NWBrowser`/`NetService` (~168 sites) | DNS-SD | B | W1 |
| **Mercury media (full)** | `Services/Media/` (19 files) | WGC + MediaFoundation + RFB + VoIP-sub | B | W9 |
| **TextExpansion (global keystroke intercept)** | `Services/TextExpansion/` | `WH_KEYBOARD_LL` hook | B | W1/W4 |
| **StoreKit Pro paywall / IAP** | `Views/Settings/CloudStoreSettingsView` | Stripe web / Store IAP | C | W3/W7 |
| **DailyDigest** | `Services/DailyDigestManager.swift` | Scheduled toast | B | W4 |
| **Pretext text-rendering engine** | `OpenBurnBarCore/.../Pretext/` (`WKWebView` + bundled JS) | WebView2 + JS bridge, or native text layout | B | W6 |
| Themes / Glass / 30 substrates | `Theme/` + Core `Views/` | Mica/Acrylic + Win2D particle | B | W6 |
| PetCompanion | `PetCompanion/` (115 glb) | glTF + layered click-through | B | W8 |
| Menu-bar UI | NSStatusItem + NSPopover | Tray + flyout | B | W6 |
| Notifications | UserNotifications | WinRT Toast | B | W1 |
| Auth (Google + Apple) | AccountManager | Google + MSA (+ Apple web) | B/C | W3 |
| Global hotkey / pet summon | Carbon | `RegisterHotKey` | B | W1 |
| Auto-update | Sparkle feed + custom updater | MSIX/WinSparkle + pinned Ed25519 (R19) | B | W10 |
| Distribution | DMG + Homebrew + notarize | MSIX + winget/Choco + Authenticode (R19) | B | W0/W10 |
| Sign in with Apple | ASAuthorization | MSA/Google/email | C | W3 |
| iCloud mirror | ubiquityContainerURL | OneDrive/Firestore-only | C | W3 |
| App Intents/Siri | AskAssistantIntent | Command palette + hotkey | C | W6 |

Each row's Verify criterion is defined by the G0–G5 rubric (§7.3). Tier-C rows require a "substitute works" test, not
a dash.

---

## 11. Verification & parity-certification strategy

Parity is only real if measured, and the repo's own gates have blind spots (post-merge coverage, CI-skipped
snapshots, **no parser-output or prompt-injection contract**). The Windows lane fixes these for itself from day one:

1. **Parser-output contract (new, most important).** Portable fixtures → parse on Mac (golden) + Windows → identical
   `TokenUsage`/session/model/cost. Required PR check.
2. **Prompt-injection-wrap contract (new).** Byte-match `wrapUntrusted` output incl. neutralization/truncation-reseal/
   provenance (R18). Required PR check.
3. **DB-compat vector.** A committed real-shaped SQLCipher DB + expected schema hash; Windows opens read-write + FTS5
   MATCH + migrates to v53.
4. **KAT triplet extension.** Windows joins the byte-identical Signal/HPKE/wire/CloudVault set under the fail-closed
   check.
5. **E2E replay corpus.** Multi-provider recording → Mac golden → Windows reproduces (G2 headline).
6. **Coverage gate on PRs** (not post-merge), scope-partitioned per tree.
7. **Windows snapshot baseline + design review** vs. macOS goldens at G3.
8. **Adversarial gates G0–G5** as the judgment layer over the automated checks.

---

## 12. CI / release / distribution lane

`area: Windows` label + CODEOWNERS; `pr-windows-fast.yml`; a `windows` job in `openburnbar-pr-harness.yml`
(mirrors `android`, registered in `platform-confidence-gate`); `build-iroh-windows.yml` +
`build-burnbar-remote-windows.yml`. **Signing:** Authenticode via Azure Trusted Signing + **DLL-load hardening**
(`/DEPENDENTLOADFLAG`, `SetDefaultDllDirectories`, non-first-party-DLL block) so the daemon self-check has a
library-validation equivalent (R19). **Packaging:** MSIX (+ portable zip); auto-update from the **Ed25519-pinned**
feed (pin the feed key independent of the Authenticode cert); winget + Chocolatey. **Note:** Authenticode has **no
notarization/staple analog** — state this honestly rather than claiming parity; keep **direct+winget primary** so
Store re-signing doesn't break the Sigstore provenance. Supply chain: SBOM (SPDX) + OpenVEX + Sigstore over Windows
artifacts. New secrets: `WINDOWS_CODESIGN_*`/Trusted-Signing creds, `WINDOWS_UPDATE_SIGNING_KEY`.

---

## 13. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Swift-on-Windows can't carry Swift-6 strict concurrency at prod quality | Med | High | Phase-0 0-a binds A/B; Option B ready fallback |
| R2 | **GRDB has no Windows support; SQLCipher/FTS5 byte-incompat → unreadable DBs/corrupt sync.** Byte-compat holds only within a SQLCipher major version; Mac uses passphrase mode with **implicit** cipher/kdf/page pins + `porter unicode61` FTS5 | Med-High | **Critical** | **Phase-0 0-d** opens a real Mac DB; **pin `cipher_compatibility`/`kdf_iter`/`cipher_page_size` explicitly** (make them explicit on Mac too), match tokenizer + `bm25()`/`snippet()`; raw-SQLCipher-C fallback proven there |
| R3 | Parser parity unverifiable (no portable fixtures) | High (today) | High | W11 extracts fixtures **before** W4; parser-output contract required |
| R4 | Firestore REST reimplements SDK offline/listener semantics with bugs | Med | High | `FakeGateway` seam + models; E2EE fails closed; explicit sync vectors |
| R5 | Claude Code Windows path encoding differs | High | Med | 0-h captures the real encoding; decoder handles both forms |
| R6 | Computer-use secure-desktop/UAC input | High | Med | ViGEm v1; signed-driver = v1.1 (§15.1), risk-registered |
| R7 | Liquid Glass has no true Windows analog → design drift | High | Med | Mica/Acrylic + G3 per-substrate rubric + goldens |
| R8 | PetCompanion 3D high effort | Med | Med | Isolated W8 + runtime sub-spike; v1.1 fallback named (§15.1) |
| R9 | UniFFI has no C# emitter | Med | Med | C-ABI shim + `uniffi-bindgen-cs` proven in 0-c |
| R10 | False parallelism — spine/seams thrash | Med | High | Per-seam semver freeze on 2nd consumer; stubs day one; false-parallelism lens |
| R11 | Windows lane inherits post-merge-coverage theater | Med | Med | Coverage + ratchets required **on PRs**, per-tree, from commit #1 |
| R12 | Auth: Apple Sign-In Windows web-only; MSA new | Low | Med | Google present; MSA/email; Apple via web |
| R13 | Scope illusion — "complete parity" narrows | Med | High | Tier contract + §10.1 full inventory + parity-gap lens |
| **R14** | **Firebase App Check lockout — Apple-only attestation, fail-closed, 52 function files + Firestore console tier + relay; a Windows client is rejected at the network boundary.** Solvable but a real workstream, not a config flag (Codex: "bearer-token vending machine" if the signal isn't named) | **High** | **Critical (existential for cloud)** | **Phase-0 0-e** proves the concrete pipeline: **TPM key attestation (CNG `NCryptCreateClaim`) → new Node Firebase-Admin backend verifies → `createToken`**; validate **firebase-admin-node #2308** (Win11 `App attestation failed`); fallbacks = MSIX-identity signal (weaker) or local-only v1; never relax the high-risk server gate for all platforms |
| **R15** | **DPAPI ≠ Keychain: no locked-when-locked release, no true device-binding (domain DPAPI backup key / roaming recover it), offline-extractable, Hello is consent-only (doesn't withhold key)** | **High** | **High** | **TPM/CNG NCRYPT KSP, non-exportable, Hello-gated *release*** + DPAPI outer wrap; split secret classes; parity assertion **fails on domain-joined roaming** |
| **R16** | **Named-pipe peer-auth weaker than codesign gate: PID reuse/TOCTOU, DLL injection into signed process passes Authenticode, pipe squatting, release env compile-out** | **Med-High** | **High** | Handle-validate the peer (or `ImpersonateNamedPipeClient` + SID); verify image **+ loaded modules**; `FIRST_PIPE_INSTANCE` + owner DACL + signed-nonce handshake; compile out disable-env in release; freeze into PAL before G1 |
| **R17** | **`SendInput` makes the capability-token gate advisory (any same-integrity process bypasses it); RC kill-switch may be App-Check-undeliverable; high-risk attestation binding has no Windows analog; UIPI forces whole-agent elevation** | **Med-High** | **High** | Route non-bypassable actions through ViGEm/driver; **watchdog process + signed local kill channel independent of RC**; carry fail-closed-on-RC-error; document which actions are advisory |
| **R18** | **Prompt-injection `wrapUntrusted` is a rewrite target (in app, not Core) with no contract vector AND a hidden serialization point — W3/W4/W7 can't safely parallelize until it's extracted + frozen (Codex)** | Med | High | **Move `wrapUntrusted` into Core as a Phase-1 predecessor** (Option A reuses it); add the **wrap contract vector** (delimiter-defang + truncation-reseal) as a required PR check before W3/W4/W7 fan out |
| **R19** | **Signing gaps: no notarization/staple analog; DLL sideload defeats Authenticode + `WinVerifyTrust` self-check; cert-rotation trust drift; MSIX Store re-sign breaks Sigstore provenance** | Med | High (for the sideload path) | DLL-load hardening (library-validation equivalent); **pin Ed25519 feed key** independent of the cert; **direct+winget primary**; state the missing staple honestly |
| R20 | External cert/Store/winget lead-times gate G5 regardless of fleet width | Med | Med | **W0 starts at Phase 0**; §14 flags these as calendar-bound |
| **R21** | **Option-A Core split is 24-file cross-cutting surgery, not a move (Codex): Pretext/WebKit, CloudVaultCrypto/Security, ComputerUseCore's 12 Darwin/XPC/Keychain files, feature-flag/app-state types** | Med-High | High (mis-sizes Option A) | **Phase-0 0-a proves the split is tractable**; size it as a real refactor spanning rendering/crypto/state; if intractable → Option B |
| **R22** | **Pretext is a `WKWebView`-backed engine (bundled JS) called by chat, not a markdown host — no Windows analog without a WebView2/JS bridge or native text-layout replacement** | Med | Med | Port to **WebView2 + the same bundled JS** (or native layout) with parity tests; sized in W6, decided as a Phase-1 predecessor |

---

## 14. Sizing & sequencing

Refusing a calendar date is fine; refusing a **magnitude** blocks Alberto's go/no-go. A defensible envelope from the
LOC counts:

- **New/ported Windows-specific surface — Option A:** UI rewrite ~118k app + ~30.7k in-core UI (SwiftUI→WinUI is
  reimplementation) + PAL/services/daemon-host glue + extracted DataStore + bindings/CI/harness/fixtures ≈
  **~200k LOC**. **Option B/C:** add the ~90k Core-engine rewrite ≈ **~290k+ LOC**.
- At the factory's "smallest reviewable coherent unit" (~200–300 net LOC/PR), +30–50% for tests/fixtures/CI/gate
  rework: **~1,000–1,300 PRs (Option A)**, **~1,600–2,000 (Option B/C)**.
- **Effort, not calendar:** net of the review/merge realities (even with the §6.3 sharding), realistic sustained
  *landed* throughput is tens of merged PRs/day → **order-of-magnitude a few agent-months of continuous factory
  operation**, dominated by the W1/W2 spine and the two XL phases.
- **Three swing factors** Alberto should weigh: **Option A vs B** (±50% LOC), **review parallelism** (single vs.
  sharded Codex — §6.3), and the **gate-rework rate** (how often G-gates return FIX/PIVOT).
- **Honesty note (Codex):** this envelope holds only if **rework stays low**, and rework concentrates on exactly the
  hardest areas — PAL, the DB byte-compat, the App Check backend, the security seams, and UI parity. If the Option-A
  Core split (R21), the Pretext WebView port (R22), or the App Check TPM backend (R14) run hot, expect the **upper end
  or beyond**. Treat ~1,000–1,300 PRs as a floor for Option A, not a midpoint.
- **Calendar-bound items width can't dissolve (W0):** Authenticode/EV or Trusted-Signing identity validation, Store
  cert validation, and the Microsoft-reviewed winget manifest PR. Start at Phase 0.

**Sequencing:** Phase 0 (bind stack, retire kill-risks) → Phase 1 (foundation + **walking skeleton**) → Phase 2
(engine parity) → Phase 3 (UI parity) → Phase 4 (computer-use + pet + integrations) → Phase 5 (signed distribution +
certification), gates G0–G5 between each.

---

## 15. Open decisions for Alberto

1. **Engine stack bias** — proceed with **Option A** (Swift-on-Windows core reuse) as the Phase-0 primary + Option B
   fallback, or start from **Option B/C**? *(Rec: A-primary, decided by G0 evidence.)*
2. **UI framework** — **WinUI 3** (best Windows citizen, no Linux path) vs. **Avalonia** (future Linux, weaker glass)?
   *(Rec: WinUI 3 for v1.)*
3. **Distribution primary** — **direct MSIX/zip + winget** (fewer computer-use/HID constraints; preserves Sigstore
   provenance) vs. **Microsoft Store** (identity/IAP but sandbox fights computer-use like MAS)? *(Rec: direct+winget
   primary, Store secondary.)*
4. **PetCompanion in v1** — full parity in Phase 4, or explicit **v1.1 non-goal** (§15.1)? *(Rec: keep in-scope;
   isolated, won't block launch.)*
5. **Secure-desktop input injection** — commit to a WHQL-signed virtual-HID driver now, or **ViGEm v1 + driver as an
   explicit v1.1 non-goal**? *(Rec: ViGEm v1, driver v1.1.)*
6. **⚠️ App Check / attestation (R14)** — this gates the *entire* cloud/sync/relay/high-risk-computer-use surface and
   has **no client-only fix**. The concrete pipeline is now known (§9.3): TPM key attestation → Node Firebase-Admin
   backend → `createToken`. Choose: **(a)** fund the **TPM-attestation custom-provider backend** (strongest; a real
   new service + TPM verification, with the Win11 Admin-SDK bug #2308 to clear); **(b)** ship a **weaker
   MSIX-package-identity signal** via the same custom-provider plumbing (faster, documented lower assurance, written
   risk acceptance); or **(c)** ship Windows as a **local-only peer for v1** (log ingestion + usage + local
   computer-use, **no cloud sync / no Hermes relay / no hosted Insights**) and add cloud when (a) lands. *(Rec:
   decide at G0 on 0-e evidence; (a) is the right long-term answer; (c) is the honest fast path to a shippable v1 if
   (a) is too heavy — but it means "complete parity" is explicitly phased, and that must be stated to users, not
   hidden.)*

### 15.1 Explicit v1.1 non-goals (no runtime trapdoors)

To honor the completion bar honestly, deferrals are named **now** with acceptance criteria, not decided under
schedule pressure at a gate:
- **Secure-desktop / lock-screen input injection** (WHQL-signed virtual-HID driver) — v1 ships ViGEm for the
  non-secure-desktop case. *v1.1 criterion:* signed driver injects at the Windows lock screen under the same
  capability-token + audit-chain gates.
- *(Only if Alberto picks 15.6(c))* **Cloud sync / Hermes relay / hosted Insights on Windows** — pending the App
  Check custom provider. *v1.1 criterion:* cross-platform E2EE round-trip (both directions) passes with a real
  Windows attestation.

Everything else in §10.1 is **v1 scope**.

---

## 16. External sources (v2.1 research)

Web research backing the v2.1 corrections:
- Swift on Windows status + Jan-2026 Windows Workgroup — [swift.org/blog/announcing-windows-workgroup](https://www.swift.org/blog/announcing-windows-workgroup/)
- Firebase App Check custom provider (the desktop/Windows path) — [firebase.google.com/docs/app-check/custom-provider](https://firebase.google.com/docs/app-check/custom-provider)
- Known Windows-11 Admin-SDK App Check bug — [firebase-admin-node #2308](https://github.com/firebase/firebase-admin-node/issues/2308)
- SQLCipher cross-platform compatibility + `cipher_compatibility` — [github.com/sqlcipher/sqlcipher](https://github.com/sqlcipher/sqlcipher), [zetetic.net SQLCipher API](https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_compatibility)

---

*This plan was produced by an 8-agent parallel codebase survey, synthesized, then hardened by a 4-lens adversarial
review (technical / parity-gap / process / security) that verified every claim against the codebase, then a
code-verified Codex second opinion + targeted web research (v2.1). It is intended to be executed by a parallel agent
fleet through the BurnBar software factory, with adversarial review gates between phases as the quality spine. Update
this file as gates return verdicts.*
