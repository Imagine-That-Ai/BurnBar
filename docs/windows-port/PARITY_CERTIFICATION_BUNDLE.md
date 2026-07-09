# OpenBurnBar Windows — Parity Certification Bundle (G5 evidence)

**Status:** Living evidence ledger for Phase 5 gate **G5** (`docs/WINDOWS_PORT_MASTER_PLAN.md` §7.3).  
**Role:** Single source of truth for an independent reviewer to decide **GO / FIX** on launch certification — not the gate verdict itself.  
**Oracle:** macOS app (`AgentLens/`) + shared contracts (`packages/`, `AgentLensTests/Fixtures/`).  
**Windows tree:** `windows/` (WinUI shell, PAL, storage, cloudsync, tests, dist).  
**Related:** `docs/windows-port/HANDOFF.md`, `docs/windows-port/PHASE3_UI_PARITY_PLAN.md`, `docs/WINDOWS_PORT_MASTER_PLAN.md` §10.1.

> **How to use this doc.** Each row cites a **test**, **fixture**, **WPD/PR**, or **runbook** artifact. Screenshot cells awaiting Alberto’s **Win11 Pro validation pass** are marked `_(blocked — Win11 Pro pass pending)_` — never as invented image paths (Phase 0 ledger scanner rejects those). Cross-platform snapshot auto-gates are explicitly **not** claimed (`PHASE3_UI_PARITY_PLAN.md` §G3). Canonical production-parity status is [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml).

---

## 0. G5 exit rubric (from master plan §7.3)

| Criterion | Evidence location in this bundle |
|-----------|----------------------------------|
| Signed MSIX installs + auto-update from live **Ed25519-pinned** feed (recorded) | §3 Distribution; PR **#1255** (E2 MSIX) |
| winget manifest merged | §6 Open dependencies (W0) |
| Every parity-matrix row green with committed evidence | §1–§3 matrices + §5 checklist |
| Launch bundle: installer hash, update recording, parity results, KAT/DB/parser/wrap logs, SBOM/Sigstore, crash-free session | §5 + §3 |

---

## 1. Surface parity matrix (13 navigable destinations)

> **Status authority:** production-parity status is owned by
> [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml). The Status column below
> mirrors ledger vocabulary only (`Real` / `Substituted` / `DeferredApproved` /
> `Blocked`). **Authored is not a valid status.**

**Seams:** `NavCatalog` + `SurfacePageResolver` (`windows/app/OpenBurnBar.App/Shell/`).  
**Sidebar:** 12 rows in `NavCatalog.All`; **13th** navigable key = auxiliary `elderWand` (Command Palette only, macOS reachability parity per `ElderWandPage.xaml`).

| # | Nav key | macOS counterpart | Windows page / host | Primary tests | Data backend | Status (ledger) | Evidence / PR |
|---|---------|-------------------|---------------------|---------------|--------------|-----------------|----------------|
| 1 | `dashboard` | `DashboardMainRoute.overview` | `DashboardPage` | `OpenBurnBar.App.Dashboard.Tests` | SQLCipher when configured; empty-state / sample only under `OPENBURNBAR_SAMPLE_MODE` | **Substituted** (`nav-dashboard`) | ledger; **#1256** |
| 2 | `chat` | `DashboardMainRoute.chat` | `ChatHostPage` + Pretext host | `presentation/Chat/*Tests.cs` | Scripted/Unavailable drivers without live Hermes/ConPTY proof | **Blocked** (`nav-chat`) | design/0005; TONIGHT C1/C4 |
| 3 | `insights` | `DashboardMainRoute.insights` | `InsightsPage` | `presentation/Insights/*Tests.cs` | Empty KPI honest path; live rollup incomplete | **Substituted** (`nav-insights`) | ledger |
| 4 | `quota` | `DashboardMainRoute.quota` | `QuotaWorkspacePage` | `OpenBurnBar.App.Quota.Tests` + acquisition tests | Live coordinator preferred; parsers Real on separate row | **Substituted** (`nav-quota`); parsers **Real** (`quota-portable-parsers`) | evidence/quota; **#1250** |
| 5 | `sessionLogs` | `DashboardMainRoute.sessionLogs` | `SessionLogsHostPage` | presentation + storage tests | SQLCipher read seam; sample fallback still present in composition | **Substituted** (`nav-session-logs`) | evidence/storage; **#1267** |
| 6 | `memory` | `DashboardMainRoute.memoryReview` | `MemoryPage` | `MemoryReviewInboxModelTests.cs` | Cloud when credentials; App Check/OAuth still Blocked | **Substituted** (`nav-memory`) | ledger; **#1267** |
| 7 | `missionControl` | `DashboardMainRoute.missions` | `MissionControlPage` | `presentation/MissionControl/*Tests.cs` | Firestore host or empty host; DemoHost sample-only | **Substituted** (`nav-missions`) | WPD-0006 |
| 8 | `budget` | Settings Budget + `BudgetLedger` | `BudgetPage` | `presentation/Budget/*Tests.cs` | In-memory / SQLCipher stores; cloud budget incomplete | **Substituted** (`nav-budget`) | ledger |
| 9 | `dataControlCenter` | Data & Privacy workbench | `DataControlCenterPage` | DCC + `CloudSyncCallableHubTests` | 9 callables wired via injectable transport; live auth WS-D | **Substituted** (`nav-data-control-center`) | ledger |
| 10 | `switcher` | `AccountSwitcherSettingsView` | `SwitcherHostPage` | presentation + store round-trip | SqlCipher store proven; sample fallback must not be default | **Substituted** (`nav-switcher`) | evidence/storage |
| 11 | `onboarding` | Onboarding wizard | `OnboardingPage` | `OpenBurnBar.App.Onboarding.Tests` | Portable wizard + DB config; host proof outstanding | **Substituted** (`nav-onboarding`) | ledger |
| 12 | `settings` | Settings shell + tabs | `SettingsPage` tree | `OpenBurnBar.App.Settings.Tests` | Placeholder residual + DataGated OAuth tabs remain | **Substituted** (`nav-settings`) | ledger |
| 13 | `elderWand` | Analysis Models | `ElderWandPage` (palette) | `presentation/ElderWand*Tests.cs` | Empty without sample mode; drift D8 | **Substituted** (`nav-elder-wand`) | ledger |

**Resolver ground truth:** all 12 `NavCatalog.All` keys + 1 `NavCatalog.Auxiliary` key (elderWand) = **13/13** map to real `Page` types in `SurfacePageResolver.cs`.  is only the `_ ` catch-all for unknown keys (**#1267** integration).

---

## 2. Engine parity matrix

| Area | macOS / shared contract | Windows implementation | Harness / tests | Status | PR / doc |
|------|-------------------------|------------------------|-----------------|--------|----------|
| **Log parsers (15 corpus)** | `AgentLensTests/Fixtures/ParserContract/`, `PARSER_OUTPUT_CONTRACT.md` | Swift Core parsers (Option A) lifted into the Engine; `OpenBurnBarG2ParserParity` byte-diff runs in the Windows engine lane | `ParserOutputContractGoldenTests` (macOS); `OpenBurnBarG2ParserParity` vs `parser-output-golden.json` on native Windows CI (x64 + ARM64) | **PROVEN on Windows CI** — 15 providers / 26 fixtures byte-identical, both arches green (run [28775204323](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/28775204323) on PR **#1270**, merged `cc56024f07`) | **#1250** (CLEAN lift); **#1251** (SEAM + storage proof); `85b898255f` → `67de06b5c7` (G2 harness); **#1270** (green lane) |
| **Stream JSON** | `STREAM_JSON_MAC_GOLDEN.md`, `claude-stream-mac-golden.jsonl` | Replay through Windows stream parser port | `ClaudeStreamGoldenParseDiffTests` (macOS) | **Golden committed**; Windows replay G2 | **#1250** |
| **Prompt-injection wrap** | `LLMSafeContent.wrapUntrusted` in Core (#1181) | Must match delimiter-defang + truncation-reseal | Wrap vector corpus (C3) | **Vectors** committed; Windows consumer G2 | **#1254** (C3 wrap vectors); R18 |
| **Quota adapters (4 mechanisms: parse + acquisition)** | `Services/ProviderQuota/` | Portable C# parse core (`app/OpenBurnBar.App.Presentation/Quota/`) + acquisition halves (`app/OpenBurnBar.App.Quota.Acquisition` + `.Windows`) | `OpenBurnBar.App.Quota.Tests` (4 parsers + fixtures) + `OpenBurnBar.App.Quota.Acquisition.Tests` (57: sources, hook installer, coordinator, watcher) | **Acquisition built + tested on macOS** (statusline file+hook, Cursor `state.vscdb`, Codex `wham/usage`, Anthropic headers, coordinator); **live-host proof WS-D** (real `FileSystemWatcher`/`%APPDATA%`/hook + WinUI XAML build) | `windows/quota-acquisition-adapters` |
| **SQLite / SQLCipher seam (C4)** | GRDB + 53 migrations (`AgentLens/`) | `windows/storage/OpenBurnBar.Storage` + `Microsoft.Data.Sqlite` + `bundle_e_sqlcipher` — the **permanent** Windows storage owner per **WPD-0005** (Engine computes, shell persists) | `windows/storage/OpenBurnBar.Storage.Tests` (`DbByteCompatVectorTests`, 10/10 per WPD-0004) | **Byte-compat proven** (read seam); prune = architecture, gated by `verify-windows-storage-architecture.sh` | **#1251**; **WPD-0004**; **WPD-0005** |
| **CloudVault / E2EE** | `CloudVaultCrypto` (Swift) | `windows/cloudsync/OpenBurnBar.CloudSync.Crypto` | `windows/tests/cloudsync/*Crypto.Tests` + KAT `cloudvault-kat-vectors.json` | **KAT parity** on macOS host | **#1251**; shared KAT triplets |
| **Firestore REST + models** | Native Firebase SDK | `OpenBurnBar.CloudSync` gateway + model codecs | `OpenBurnBar.CloudSync.Tests` (`ModelParityTests`, REST fakes) | **Authored**; live TPM App Check pending | R14; `windows/cloudsync/appcheck/` |
| **App Check (R14)** | Apple App Attest | TPM `NCryptCreateClaim` + mint backend | `OpenBurnBar.CloudSync.AppCheck.Tests` | **Server half built**; Win11 Pro TPM pass **Alberto** | HANDOFF §R14; not **#1253** alone |
| **Rust transport** | `burnbar-remote`, `openburnbar-iroh` | `*-pc-windows-msvc` targets | `build-*-windows.yml` workflows | **Targets authored** | **WPD-0002**; **#1253** (A3 CI) |
| **Engine host (Option A)** | `OpenBurnBarCore` Engine subset | Swift-on-Windows compile + walking skeleton | `openburnbar-engine-windows.yml` | **Proven on dev host**; CI gate hardening | **#1252** (B0 ADR **WPD-0007** narrative); **#1257** (B0 spike) |
| **C-ABI engine binding** | In-process Swift | `@_cdecl` export (`obb_parse_cli_stdout`) + C# P/Invoke test (1/1 macOS) | Engine binding test project | **Proven on macOS**; Windows CI pending | **#1267** (integration) |
| **Computer Use core** | `OpenBurnBarComputerUseCore` | PAL input + policy tests | `OpenBurnBar.ComputerUse.Tests`, `OpenBurnBar.Pal.Input.Tests` | **Phase 4** (G4); not G5 blocker for local peer v1 | WS-D deferred render pass |

**G2 headline (PROVEN 2026-07-06):** multi-provider session corpus → **byte-identical** `ParserOutputContractRecord` vs Mac golden on Windows. `OpenBurnBarG2ParserParity` byte-diffs **15 providers / 26 fixtures** on native Windows CI, **x64 + ARM64 both green**: run [28775204323](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/28775204323) on PR **#1270** (head `bf38e3b2eb`, merged to `main` as `cc56024f07`). Harness landed in `85b898255f` (ClaudeCode + FactoryDroid lift + byte-diff gate) → `67de06b5c7` (Codex + Hermes via the read-only SQLite reader seam, "15/15 byte-identical"). Formerly tracked as FIX pending a green engine-lane run; PR #1270's swift-crypto Sendable fix unblocked the lane.

---

## 3. Infrastructure parity matrix

| Subsystem | Tier | macOS | Windows | Tests / workflow | Status | PR / WPD |
|-----------|------|-------|---------|------------------|--------|----------|
| **Storage** | A | GRDB + SQLCipher | C# SQLCipher seam — **permanent architecture** (WPD-0005): Windows Swift Engine is compute-only, `windows/storage/` owns persistence | `OpenBurnBar.Storage.Tests` | **Read path proven**; write/migration seam is the WPD-0004 follow-up | **WPD-0004**, **WPD-0005**, **#1251** |
| **Cloud sync** | A/B | Firestore SDK + CloudVault | REST gateway + crypto | `OpenBurnBar.CloudSync.Tests`, `CloudSync.Crypto.Tests` | **Codec parity**; live cloud gated on App Check | **#1251** |
| **PAL: IPC** | B | Unix socket + codesign | Named pipe + signed-nonce handshake | `OpenBurnBar.Pal.Ipc.Tests` (20/20 cited HANDOFF) | **Proven** | `design/0004-named-pipe-peer-auth.md`; B1 `windows/b1-conpty-cli-stream` |
| **PAL: ConPTY** | B | `openpty` | `ConPtySession` | IPC Windows project + runbook `CONPTY-019-dev-host-runbook.md` | **Harness built** | B1 in flight |
| **PAL: input / CU policy** | B | CGEvent / AX | `SendInput` + UIA (advisory per R17) | `OpenBurnBar.Pal.Input.Tests` | **Policy tests**; G4 for full loop | Phase 4 |
| **Distribution: MSIX** | B | DMG + notarize | MSIX + Authenticode | `openburnbar-release-windows.yml`, `pr-windows-dist.yml` | **Pipeline authored** | **#1255** (E2 MSIX) |
| **Distribution: update feed** | A | Ed25519 appcast | Pinned Ed25519 feed verifier | `OpenBurnBar.Updater.Tests`, `OpenBurnBar.Dist.Tests` | **Verifier tests green** | R19; dist tests |
| **Distribution: winget/choco** | B | Homebrew cask | winget + Chocolatey manifests | Release workflow + §6 W0 | **Pending** external publisher | W0 Alberto |
| **SBOM / Sigstore** | A | Release pipeline | Windows release job (keyless attest) | `release.yml` pattern / `openburnbar-release-windows.yml` | **Authored**; attach logs in §5 | G5 bundle |
| **Integrations: Cast** | B | `Services/Cast/` | `OpenBurnBar.Integrations.Cast.Tests` | Protocol + mDNS tests | **Unit parity** | W9 |
| **Integrations: Home Assistant** | B | `Services/HomeAssistant/` | `OpenBurnBar.Integrations.Tests` | Client + mapper tests | **Unit parity** | W9 |
| **Integrations: Mercury** | B | AVFoundation pipeline | RFB + media codec port | `OpenBurnBar.Integrations.Mercury.Tests` | **Protocol tests**; AV G4 | W9 |
| **Pet / glTF** | B | SceneKit + `.glb` | `WebView2PetGltfHost` + overlay | `OpenBurnBar.App.Pet.Tests` | **Behavior + overlay tests** | G4 |
| **Theme / glass** | B | `LiquidGlass.swift` | Mica/Acrylic shim | `OpenBurnBar.App.Theme.Tests` | **Transparency contract** | Accepted drift §4 R7 |
| **mDNS / SmartHub** | B | Bonjour | DNS-SD seam | `MdnsAdvertisementTests` in integrations | **Partial** | W1 PAL |
| **CI: Windows fast** | — | — | `pr-windows-fast.yml` + `pr-windows-gate` | Path-filtered aggregate | **Authored** | **#1253** (A3) |
| **CI: full XamlCompiler** | — | — | `pr-windows-full.yml` (Win11 `windows-latest`) | Full WinUI build | **Required on Windows**; macOS ceiling documented | Assignment A2 flip §6 |

---

## 4. Accepted-drift list (documented, not bugs)

These are **explicit** Tier-B/C substitutions or interim postures from the master plan, Phase 3 plan, and WPDs. A G5 reviewer treats them as **PASS with noted drift**, not open defects.

| ID | Topic | macOS | Windows | Why accepted | Sign-off criterion |
|----|-------|-------|---------|--------------|-------------------|
| D1 | **Liquid Glass / substrates** | `glassEffect`, content refraction, 30 substrates | Mica/Acrylic + Win2D; no glass-over-glass | R7: Acrylic blurs backdrop only | Per-surface rubric + macOS goldens + **written drift note** (`PHASE3_UI_PARITY_PLAN.md` §W6-DS-GLASS) |
| D2 | **TPM SKU gate (R14)** | App Attest | TPM attestation on **Win11 Pro** (physical or vTPM limits) | Cloud fail-closed without signal | Win11 Pro validation pass records mint→callable (**Alberto**) |
| D3 | **XamlCompiler** | Xcode | **Windows-only** full compile | `NETSDK1100` / XamlCompiler on macOS | `pr-windows-full.yml` green on `windows-latest` |
| D4 | **Claude statusline bridge** | `DispatchSource` / FSEvents | `FileSystemWatcher` / `ReadDirectoryChangesW` | Tier-B PAL mapping (`WINDOWS_PORT_MASTER_PLAN.md` §2) | Quota statusline parser tests + live file watch smoke |
| D5 | **Web login helpers** | `CursorLoginHelper` / `FactoryLoginHelper` (AppKit/WebKit) | Deferred; OAuth loopback + web views later | Not on critical path for local-peer v1 | Documented deferral; Switcher uses portable sample until B2 |
| D6 | **GRDB → SQLite seam** | GRDB API | C# `Microsoft.Data.Sqlite` + SQLCipher bundle | **Byte-identical file** per C4, not API-identical; **permanent** per WPD-0005 (Engine compute-only, shell persists) | `DbByteCompatVectorTests` + cross-open Mac DB on Windows host; `verify-windows-storage-architecture.sh` gate |
| D7 | **Engine binding** | In-process Swift | **Interim** `swift run` wrapper; UniFFI C# bindgen target | B0 spike proved path; full in-proc binding follows | **#1257** spike evidence; WPD-0001 tracks bindgen |
| D8 | **Elder Wand reachability** | Settings leaf + chat header | Command Palette auxiliary (not sidebar row) | Preserves 12-row + Ctrl+1..9 parity | `NavCatalog.Auxiliary` + `ElderWandPage` |
| D9 | **Sign in with Apple / IAP** | Apple / StoreKit | MSA/Google/email; Stripe or Store IAP | Tier C (`WINDOWS_PORT_MASTER_PLAN.md` §2) | Substitute checkout flow tested |
| D10 | **Notarization staple** | Stapled DMG | No Apple-style staple; Authenticode + Ed25519 feed pin | R19 honest gap | DLL-load hardening + pinned feed key tests |
| D11 | **SendInput capability gate** | CGEvent | Advisory `SendInput`; driver path for non-bypassable | R17 | Documented; ViGEm for secure-desktop v1.1 |
| D12 | **Pretext metrics** | WebKit | WebView2 + **same** `pretext.bundle.min.js` | R22 Chromium vs WebKit tolerance | `0005-pretext-webview2-metric-parity.md` corpus harness |
| D13 | **project-code-static-parser** | Rust helper on Mac | Deferred Windows target (lexical fallback) | WPD-0003 | No Windows v1 regression vs documented fallback |
| D14 | **Daemon (`OpenBurnBarDaemon`) — no monolithic port** | LaunchAgent daemon: HTTP gateway, provider router/executors, headless run/resume, Mission Control DAG execution, Pensieve watcher, planner, RPC server, companion CLI | Per-capability substitution in the WinUI app process + portable C# cores (`FirestoreMissionDispatchHost`, `ConPtyCliStream`, `TokenUsageWriteSeam`, `ComputerUse.Core`, toast seam); gateway / headless runs / local mission execution / Pensieve = named v1.1 deferrals with revive triggers | **WPD-0006** (34-row matrix); consistent with WPD-0007's no-service call; revive path = daemon Linux boundary build as a Windows Service | Each SUB-DONE row cites landed tests (bundle §1–§3); deferral revisit triggers named in WPD-0006; no daemon capability claimed as "parity" without a matrix row |

---

## 5. Launch evidence checklist (G5 artifact)

Each row: **(a)** screenshot — Win11 Pro pass; **(b)** test/command; **(c)** accepted drift §4 ID if any.

> **Honesty rule (Phase 0):** do **not** invent screenshot paths. Rows awaiting the Win11
> Pro validation pass use `_(blocked — Win11 Pro pass pending; TONIGHT_PUNCHLIST C7)_`.
> The parity ledger scanner (`scripts/ci/verify-windows-parity-ledger.py`) **fails** if this
> section reintroduces fake `screenshots/g5-*.png` path claims. Committed evidence for
> **Real** ledger rows lives under `docs/windows-port/evidence/` and in the
> [`WINDOWS_PARITY_LEDGER.yml`](WINDOWS_PARITY_LEDGER.yml).

| Flow / surface | Screenshot (Win11 Pro) | Automated evidence | Drift |
|----------------|------------------------|--------------------|-------|
| Cold install signed MSIX | _(blocked — Win11 Pro pass pending; also W0 signing cert)_ | `openburnbar-release-windows.yml` run ID + installer SHA256 in release notes | D10 |
| Auto-update from Ed25519 feed | _(blocked — Win11 Pro pass pending)_ | `OpenBurnBar.Updater.Tests` + recorded feed apply log | — |
| Tray → flyout → main window | _(blocked — Win11 Pro pass pending)_ | `DEV_HOST_RUNBOOK.md` / validation pass script | — |
| Dashboard populated | _(blocked — Win11 Pro pass pending)_ | `dotnet test windows/tests/dashboard` | D1 |
| Chat stream + Pretext bubble | _(blocked — Win11 Pro pass pending)_ | `presentation/Chat/*Tests` + Pretext metric harness | D12 |
| Quota workspace | _(blocked — Win11 Pro pass pending)_ | `OpenBurnBar.App.Quota.Tests` | — |
| Budget rules | _(blocked — Win11 Pro pass pending)_ | `presentation/Budget/*Tests` | — |
| Mission Control console | _(blocked — Win11 Pro pass pending)_ | `presentation/MissionControl/*Tests` | D1 |
| Data Control Center | _(blocked — Win11 Pro pass pending)_ | `DataControlCenter*Tests` | — |
| Switcher profiles | _(blocked — Win11 Pro pass pending)_ | `Switcher*Tests` | D5 |
| Session logs + live CLI | _(blocked — Win11 Pro pass pending)_ | `StorageSessionLogReadSourceTests` + ConPTY smoke (B1) | D4 |
| Settings search + leaf | _(blocked — Win11 Pro pass pending)_ | `OpenBurnBar.App.Settings.Tests` | — |
| Onboarding wizard | _(blocked — Win11 Pro pass pending)_ | `OpenBurnBar.App.Onboarding.Tests` | — |
| Command Palette → Elder Wand | _(blocked — Win11 Pro pass pending)_ | `ElderWand*Tests` | D8 |
| DB byte-compat vector | _(no screenshot)_ | `dotnet test windows/storage/OpenBurnBar.Storage.Tests` log archived; evidence `docs/windows-port/evidence/storage/sqlcipher-byte-compat.md` | D6 |
| Parser-output golden | _(no screenshot)_ | Mac `ParserOutputContractGoldenTests` + Windows `OpenBurnBarG2ParserParity` byte-diff **green** (15 providers / 26 fixtures, x64 + ARM64): run [28775204323](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/28775204323), PR #1270 → `cc56024f07`; evidence `docs/windows-port/evidence/engine/g2-parser-parity.md` | — |
| Wrap vector (C3) | _(no screenshot)_ | Committed corpus per **#1254** | — |
| CloudVault KAT | _(no screenshot)_ | `dotnet test windows/tests/cloudsync`; evidence `docs/windows-port/evidence/cloudsync/cloudvault-kat.md` | — |
| IPC handshake 20/20 | _(no screenshot)_ | `dotnet test windows/tests/ipc`; evidence `docs/windows-port/evidence/pal/ipc-handshake.md` | — |
| `pr-windows-full` green | _(CI link)_ | GitHub Actions run URL on `windows-latest` | D3 |
| SBOM + Sigstore attestation | _(artifact link)_ | Release workflow attestation bundle | D10 |
| Crash-free 30 min session | _(blocked — Win11 Pro pass pending)_ | ETW/WER-free session log from validation pass | — |
| TPM App Check E2E | _(blocked — Win11 Pro pass pending; R14 / TONIGHT_PUNCHLIST C2)_ | Callable success with minted token | D2 |

**Reviewer rule:** Any G5 screenshot cell still blocked without a linked CI log or test output → **FIX** for G5 ship claim; drift IDs alone do not excuse missing tests. Engine/storage/crypto/IPC rows with committed evidence under `docs/windows-port/evidence/` may be **Real** on the ledger without screenshots.

---

## 6. Open dependencies (Alberto-owned)

| Item | Blocks | Notes |
|------|--------|-------|
| **W0 Authenticode / Trusted Signing cert** | Signed MSIX in production | Calendar-bound; start Phase 0 (`HANDOFF.md` §W0) |
| **W0 Microsoft Store + winget publisher** | Store + manifest merge | External humans, not agents |
| **Win11 Pro validation pass** | §5 screenshots + D2 TPM proof | GPU fidelity = WS-D; this bundle only reserves paths |
| **CI required-gate flip (A2)** | `pr-windows-full.yml` blocking merge | After green history on `windows-latest` |
| **C5 / deferral call** | Project Code Memory Windows parser | WPD-0003 deferral; lexical fallback until lifted |
| ~~In-flight PRs (no number yet)~~ **RESOLVED 2026-07-06: all four already integrated** | B1 ConPTY, B2 persistence, B6 mission dispatch, C2 quota | git audit: every file the 4 branches add is on `main` (landed by #1267 `8092d19ea1`; B6 further hardened by #1272 `b0edba64c9`). The branch refs (`windows/b1-conpty-cli-stream`, `windows/b2-sqlcipher-persistence`, `windows/b6-mission-dispatch`, `windows/phase2-c2-quota-lift`) are STALE older drafts — **do not merge**: B6's draft would delete #1272's `running`/`claimed`/`in_progress` status polling and C2's would regress the public `ClaudeOAuthCredentials` API. Safe to delete the refs. |

---

## 7. Landed / cited PR map (burndown cross-reference)

| PR | Lane | What it proves for this bundle |
|----|------|--------------------------------|
| **#1250** | C — CLEAN parsers | Portable parser corpus + clean lift |
| **#1251** | C — SEAM parsers + **C4** | Storage/session seam + SQLCipher byte proof |
| **#1252** | B0 — architecture ADR | Option A / multi-target ADR (**WPD-0007** stack narrative) |
| **#1253** | A3 — CI | Windows CI workflows + aggregate gate pattern |
| **#1254** | C3 — wrap vectors | Prompt-injection wrap contract corpus |
| **#1255** | E2 — MSIX | Release + MSIX packaging step |
| **#1256** | B5 — nav pages | Real pages wired into `SurfacePageResolver` |
| **#1257** | B0 — spike | End-to-end `swift run` / engine path spike |

---

## 8. Independent reviewer decision guide

| Verdict | When |
|---------|------|
| **GO (G5)** | §5 has no missing **test/CI** rows; MSIX + feed verifiers green; §1–3 have no **undeclared** stub labeled “parity”; Alberto placeholders for screenshots/TPM are explicitly outstanding but **do not** block engine/distribution evidence already green |
| **FIX** | Any Tier-A row lacks committed vector/test; `pr-windows-full` red; App Check production path unproven **and** not covered by written risk acceptance; parity matrix row marked **Authored** without cited test project |
| **PIVOT** | SQLCipher byte-compat regresses; App Check TPM path fails on Win11 Pro with no approved cloud posture (`HANDOFF.md` open decision #6) |

---

*Bundle version: 2026-07-04 (updated for integration PR #1267) · Branch: `windows/integration-all-prs`*