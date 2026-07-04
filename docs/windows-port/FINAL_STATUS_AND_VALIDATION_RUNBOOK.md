# Windows Port — Final Build Status + Windows-Validation Runbook (2026-07-04)

Honest end-of-build accounting for the macOS→Windows port, plus the turnkey runbook to flip it from
**built + logic-verified** to **Windows-runtime-validated** and **shipped**. Companion to
`docs/windows-port/HANDOFF.md` (superseded where they differ; this is newer).

---

## 1. What was built + landed on `main` (verified to the macOS ceiling)

**1,062 Windows files across 14 areas** landed on `main` via autonomous admin-merges of consolidated,
adversarially-verified waves. ~2,800 real portable unit tests across the waves. Every wave was built in
isolated worktrees, independently rebuilt by an adversarial verifier, consolidated, and merged.

| Phase | Landed | Evidence |
|---|---|---|
| **0 de-risk** | ✅ | All kill-risks answered on real Windows (dev host): Swift compiles, Mac SQLCipher DB opens, 20/20 handshake, WinUI builds+renders. |
| **1 Core split + G1** | ✅ | `OpenBurnBarCore` Engine subset compiles on `x86_64-unknown-windows-msvc`; walking skeleton runs green on Windows CI (run 28672100306). #1177-1183, #1190. |
| **3 UI parity** | ✅ | Foundation (tokens, Mica/Acrylic glass, 30-substrate Win2D particle engine, Pretext WebView2) + every surface: Settings/Onboarding/SessionLogs/Memory/shell/components + Budget/DataControlCenter/Switcher/ElderWand/MissionControl/Insights + Dashboard/Chat/Quota. #1205/#1211/#1215/#1226/#1243. ~1,800 tests. |
| **4 computer-use/pet/integrations** | ✅ | Computer-use (Ed25519 capability tokens, audit-chain tamper, triple kill-switch fail-closed), ViGEm, PetCompanion (behavior graph + click-through overlay + glTF), Google Cast, Home Assistant + SmartHub, Mercury (RFB/WGC/MediaFoundation). #1233. 641 tests. |
| **2 data & sync (cloud half)** | ✅ | Firestore REST gateway, CloudVault E2EE crypto (byte-parity BOTH directions vs the committed KAT vectors), App Check Windows client (triple-proven parity, fail-closed) + real TPM CNG producer behind a seam, quota-adapter parse. #1238. 216 tests. |
| **2 parser PATH-layer** | ✅ | Claude-Code path codec lifted to the Engine + Windows path-remap + 54-assertion harness + 16 tests + x64/ARM64 CI leg. #1244. |
| **5 distribution (authored)** | ✅ | MSIX/winget(1.6-schema-valid)/Choco manifests, Ed25519-**pinned** update feed + updater-core (fail-closed, key independent of the Authenticode cert), Azure Trusted Signing workflow + DLL-load hardening (verified-applied) + SBOM/OpenVEX/Sigstore. #1240-1243. ~200 tests. |

**"Verified to the macOS ceiling"** = the portable logic is real-unit-tested (crypto vector-parity, security
invariants, chart geometry, physics, protocol framing, update-feed signature pins) AND `dotnet build` reaches
the byte-identical Windows-only XamlCompiler gate with 0 earlier errors. It does **not** mean it has been run
on Windows — see §2.

---

## 2. What genuinely REMAINS (honestly, not relabeled done)

### 2a. The true G2 parser headline — NOT achieved (real remaining port work)
The byte-identical **16-parser token/cost/model/session** output vs the Mac golden — the product-core parity
claim — is **not done**. The parity agent found (correctly, refusing to fake it) that the 16 parsers live in
the macOS **app** layer (`AgentLens/Services/LogParser/`), NOT the Windows-buildable Engine, and
`HermesParser` links **GRDB** (pruned off-Windows). Achieving G2 requires **lifting the 16 parsers + the
parser-output contract/golden into the Engine and untangling HermesParser's GRDB dependency** — a substantial
separate port (board task #60; author a Phase-2b plan first). The path-layer contract they stand on IS landed
(#1244); the parsers themselves are not yet Windows-buildable.

### 2b. Windows-runtime validation — NOT run (needs the Windows environment)
Everything Windows-native is **authored + logic-verified but never executed on Windows**, because macOS
structurally can't: WinUI XAML render, Win2D GPU (30 substrates @60fps ARM64), WebView2 Pretext
metric-parity, SendInput/IUIAutomation/Windows.Graphics.Capture/MediaFoundation/WASAPI adapters, ViGEm, the
Win32 overlay, the named-pipe daemon channel, real Firestore/Hermes round-trips, and real TPM attestation.
Each PR flags exactly what. **This is the §3 runbook.**

### 2c. Signing + shipping — needs W0 procurement (Alberto, calendar-bound)
Real MSIX build + Authenticode sign + Store/winget/Choco submission + the launch-evidence bundle need the
**Azure Trusted Signing tenant / Authenticode cert + Microsoft Store publisher + winget publisher** (board
task #14). External-human lead-times — start now.

### 2d. R14 TPM cloud-login — dev-host proof pending
The server mint backend + Windows client are built + tested (mock + real-CNG-producer-behind-seam); the
end-to-end **real hardware TPM → createToken → enforced callable** proof needs a TPM 2.0 + Win11 machine (a
vTPM covers ~95%; final hardware-EK-chain wants a physical box). Board task #9.

### 2e. The adversarial G2–G5 gates
The master plan's between-phase adversarial red-team gates (G2 engine parity, G3 UI, G4 advanced, G5
certification) have NOT been run as formal gates — the per-wave adversarial verifiers are strong but are not
the same as the pre-registered G-gate red-team. Run them after Windows-runtime validation.

---

## 3. Windows-Validation Runbook (turnkey — free, $0)

Goal: execute everything on Windows and turn §1's "built" into "validated". **All free** (repo is public).

### Setup (once) — free Win11-ARM VM on your Mac (or any Windows box)
1. **VMware Fusion** (now free) + a **Windows 11 ARM64 ISO** (free from Microsoft via the CrystalFetch app;
   run unactivated). ~4 cores / 8 GB / 64 GB. Fusion auto-provisions a **vTPM 2.0**. (UTM is a free
   alternative.) Win11-ARM runs x64 tools via Prism, so one VM covers both arches.
2. In the VM install: **Git**, **.NET 10 SDK**, **Visual Studio 2022 BuildTools + WinUI/Windows App SDK
   workload**, the **Swift 6.3.2 Windows toolchain**, **sqlcipher** (scoop). (Toolchain recipe: HANDOFF §7.)
3. `git clone https://github.com/Imagine-That-Ai/BurnBar` (public).

### Also free, no VM — turn on the ARM64 CI leg
The `windows-11-arm` GitHub runners are free for this public repo. The x64 + ARM64 legs are already authored
(`.github/workflows/openburnbar-engine-windows.yml`, `pr-windows-*.yml`). Confirm they're green on `main` — that
alone validates: Engine compiles (x64+ARM64), walking skeleton runs, parser-path parity harness passes, Rust
crates build, the C#/dotnet test suites (~2,800 tests) run on real Windows.

### The runbook (in order — each step is a Droid/PowerShell one-liner set)
1. **Engine + skeleton (should already be green in CI):** `swift build --package-path OpenBurnBarCore` +
   `swift run OpenBurnBarWalkingSkeleton` + `swift run OpenBurnBarWindowsParserPathParity` → all exit 0.
2. **All C# portable tests on Windows:** `dotnet test` across `windows/**/*Tests*.csproj` → the ~2,800 tests
   that passed on macOS pass on Windows.
3. **DB open (already proven once):** open the committed Mac SQLCipher fixture via
   `windows/storage/` → schema-hash + FTS5 row-set match.
4. **Build + RUN the WinUI app:** open `windows/OpenBurnBar.sln` in VS 2022, build `OpenBurnBar.App` (x64 and
   ARM64), F5. **Validate visually:** shell + all nav surfaces render; Mica/Acrylic glass; the 30 particle
   substrates animate @60fps (check ARM64); Pretext chat text-layout; Dashboard easter-egg; Quota dials.
   Capture screenshots per surface (this is the G3 evidence).
5. **Computer-use + pet:** run the ViGEm/SendInput path (kill-switch halts within bound; capability-token
   gate); the pet overlay click-through passthrough.
6. **Cloud (needs the `burnbar` Firebase project):** desktop-OAuth → Firestore REST read/write; App Check
   token mint + attach; CloudVault cross-platform round-trip (Windows-seal → Mac-open + reverse).
7. **TPM (R14):** the real CNG `NCryptCreateClaim` producer → mint backend → enforced callable (vTPM for
   ~95%; note the #2308 status).
8. **Packaging:** build the MSIX (`OpenBurnBar.Packaging.wapproj`); portable zip; the update-feed
   sign/verify round-trip. (Signing needs the W0 cert.)

Each step that passes is real Windows evidence; failures feed fix-forward PRs (the autonomous loop handles them).

---

## 4. Honest one-paragraph summary
The Windows port is **code-complete for everything a Mac can build, and its logic is verified by ~2,800 real
tests** — the engine, storage, all UI, computer-use, integrations, cloud crypto, and distribution scaffolding
are on `main`. **It is not yet shippable or fully parity-certified:** the byte-identical 16-parser output
(true G2) still needs the parsers lifted into the Engine; nothing Windows-native has been *run* on Windows
(the §3 validation pass); signed artifacts need the W0 cert; and the adversarial G2–G5 gates haven't formally
run. The remaining work is well-scoped, mostly gated on the free Windows environment + the cert — not on
unknowns. Every kill-risk was retired early on real hardware, so what's left is execution + validation, not
discovery.
