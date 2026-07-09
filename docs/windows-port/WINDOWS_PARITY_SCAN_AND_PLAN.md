# OpenBurnBar Windows ↔ macOS Parity Scan & Plan

**Date:** 2026-07-09  
**Branch:** `windows/liquid-glass-kernel-reskin`  
**Scope:** macOS app (`AgentLens/` + `OpenBurnBarCore/` + `OpenBurnBarDaemon/`) vs Windows WinUI 3 app (`windows/app/OpenBurnBar.App/` + `windows/` portable cores)  
**Method:** `WINDOWS_PARITY_LEDGER` scan, `AgentLens/Views/` inventory, `windows/app/` inventory, `dotnet test` of every `net10.0` portable test project, `scripts/ci/verify-windows-parity-ledger.sh`, and `cargo build` + `check-csharp-binding-drift.sh` for the Rust FFI.

---

## 1. Honest summary

The Windows port is not a skeleton. It is a broad, well-tested set of portable C# cores that mirror the macOS engine, data, and service layers. The gap is **not** mostly missing code — the gap is the **last mile of production integration**: live Windows-hosted cloud auth, a real TPM App Check signal, the Windows UI XamlCompiler run, real GPU/Win2D proof, and a signed installable artifact.

Current state from the repo's authoritative ledger and from this scan:

| Source of truth | Result |
|---|---|
| `WINDOWS_PARITY_LEDGER.yml` rows | **33** (5 `Real`, 16 `Substituted`, 3 `DeferredApproved`, 9 `Blocked`) — scanner passes, no `Authored` statuses |
| Portable `windows/tests/` `net10.0` pass (this macOS host) | **2,889 / 2,889 tests** across 33 test projects |
| `scripts/ci/verify-windows-parity-ledger.sh` | `PASS` |
| `scripts/ci/verify-windows-parity-ledger.test.sh` | 31/31 cases passed |
| `cargo build` + `check-csharp-binding-drift.sh` | binding drift gate green; native FFI loopback now passes 25/25 on macOS |

Honest percentage: **~55–65% of the *portable* surface is built and tested**; **~15–20% of the *product* is proven Real** (production data, Windows hardware, installable artifact). The remaining 35–45% is a mix of live-cloud integration, Windows OS-specific validation, distribution, and the few genuinely missing UI routes (`database`, `projects`, and most Settings leaf pages).

---

## 2. What "full parity" means — macOS baseline

The macOS app exposes three layers the Windows app must match.

### 2.1 Primary routes (Command Deck / sidebar)

From `DashboardNavigationModel.swift`: <ref_snippet file="/Users/albertonunez/Documents/Developer/BurnBar/AgentLens/Views/Dashboard/DashboardNavigationModel.swift" lines="5-22" />

- `chat` (primary)
- `quota` (primary)
- `database` (primary)
- `projects` (primary)
- `missions` (primary)
- `sessionLogs` (primary)
- `memoryReview` (primary)
- `overview` (sidebar)
- `insights` (sidebar)
- `provider(...)` / `model(...)` (dynamic)

### 2.2 Settings hierarchy

From `SettingsTab.swift`: <ref_snippet file="/Users/albertonunez/Documents/Developer/BurnBar/AgentLens/Views/Settings/SettingsTab.swift" lines="7-24" />

16 top-level tabs: `home`, `general`, `updates`, `daemon`, `account`, `cloud`, `agents`, `modelProxy`, `alerts`, `notifications`, `devicesAndSync`, `textExpansion`, `media`, `dataPrivacy`, `computerUse`, `pets`.

And `SettingsPageRoute.cs` enumerates **~40 leaf/detail routes** (Appearance, OperatorModel, DefaultView, DataRefresh, Indexing, SessionSummaries, DaemonLifecycle, HttpGateway, ControllerRuntime, AgentsAccounts/CLIs/Runtimes/Models/Advanced, SmartDisplays, FusionImpact, etc.).

### 2.3 Cross-cutting feature planes

- **Chat / Hermes / Pretext** — streaming CLI, atom router, attachment/memory/extraction, analysis models (ElderWand).
- **Quota / Budget** — 15+ provider adapters, acquisition hooks, statusline watcher, spend rules, budget toasts.
- **Cloud sync / E2EE / App Check** — Firestore REST gateway, CloudVault crypto, OAuth/Sign-in, device attestation.
- **Data plane** — SQLCipher/GRDB, 53 migrations, session logs, memory review, search/reranker.
- **Daemon** — HTTP gateway, Mission Control DAG, provider routing, planner, headless runs.
- **Computer Use** — approval UI, scope editor, virtual HID, Agent Watch, audit chain.
- **Media / Mercury** — file transfer, screen share, calls, RFB/VNC, AV pipeline.
- **Smart Home / Integrations** — Cast, Home Assistant, SmartHub/Nest, AWTRIX/PixelClock.
- **Pet Companion** — behavior, rendering, overlay, glTF.
- **Distribution** — signed DMG, Sparkle, notarization.

---

## 3. Windows state vs macOS — per-surface gap register

### 3.1 Navigable surfaces (13 `NavCatalog` keys)

| # | macOS route | Windows key | Status | What exists | What is missing / blocking |
|---|---|---|---|---|---|
| 1 | `overview` | `dashboard` | Substituted | 6 layouts (`Atelier/Aurora/Classic/Cockpit/Constellation/Nebula`), `DashboardPage`, `CommandPalette`, `FlyoutWindow` | Real data path; sample-only when `OPENBURNBAR_SAMPLE_MODE`; missing `ConceptMoreDrawer`, `ProviderListPanel`, `SwarmRevealWindow` components |
| 2 | `chat` | `chat` | **Blocked** | `ChatHostPage`, `ChatSurfaceView`, `StreamingBubble`, `HermesAtomChip`, `HermesThinkingView`, `WebView2PretextHost` | Default driver is `UnavailableChatStreamDriver`; `ConPTY` / Hermes live stream not proven; Pretext metric drift vs WebKit unvalidated |
| 3 | `insights` | `insights` | Substituted | `InsightsPage`, `InsightWidgetTile`, `TemplateGalleryView`, `InsightChartCanvas` | Live rollup incomplete; most macOS `Insights*` views (audit, composer, inspector, workspace) not ported |
| 4 | `quota` | `quota` | Substituted | `QuotaWorkspacePage`, `QuotaArcDial`, `SubscriptionConstellationHero`, 4 parsers Real | `QuotaSampleData` fallback; live `FileSystemWatcher` / `%APPDATA%` / hook install not proven on Windows; cloud account mapper incomplete |
| 5 | `sessionLogs` | `sessionLogs` | Substituted | `SessionLogsHostPage`, `SessionLogDetailPane`, `SessionLogsView` | SQLCipher read seam proven; composition still defaults to sample data paths |
| 6 | `memoryReview` | `memory` | Substituted | `MemoryPage`, `MemoryReviewInboxView`, `MemoryConsentDialog` | Cloud-backed only when credentials; App Check/OAuth Blocked; live inbox proof incomplete |
| 7 | `missions` | `missionControl` | Substituted | `MissionControlPage`, `MissionComposerView`, `MissionConsoleHeroView`, `MissionSituationRoomView`, `FirestoreMissionDispatchHost` | `MissionDispatchDemoHost` is sample-only; real Windows dispatch proof pending |
| 8 | — | `budget` | Substituted | `BudgetPage`, `BudgetRuleEditorDialog`, `BurnRailBudgetChip`, `BudgetBlockedCard` | Cloud budget / live rule sync incomplete; dedicated Windows route exists, macOS budget lives in Settings |
| 9 | `dataPrivacy` | `dataControlCenter` | Substituted | `DataControlCenterPage`, 9 callables, `DomainInspectorView`, `RecoverySetupDialog`, `PanicRevokeDialog` | Live authenticated transport + high-risk owner-action envelope (nonce/trustedDeviceId) Blocked on App Check/Signal |
| 10 | `account` switcher | `switcher` | Substituted | `SwitcherHostPage`, `SwitcherSettingsView`, `ProfileFormDialog`, `AccountDestinationPickerDialog` | `SwitcherSampleData` fallback; sample must not be default |
| 11 | `onboarding` | `onboarding` | Substituted | `OnboardingPage`, 7-step wizard, `HermesSetupDialog` | First-run proof on Windows host outstanding |
| 12 | `settings` | `settings` | Substituted | `SettingsPage` shell, 11/16 real view-models, `SettingsPlaceholderPage` residual | Only `General`, `Updates`, `DataPrivacy`, and `Appearance` have real leaf pages; all other tabs and ~40 leaf routes fall through to `SettingsPlaceholderPage` |
| 13 | `.gatedFeature(.elderWand)` | `elderWand` (palette) | Substituted | `ElderWandPage`, `ElderWandConfiguratorView`, `Analysis/Judge/Preset` sections | Live model catalog empty without sample mode; reachability via Command Palette instead of sidebar |
| 14 | `database` | **none** | **Blocked** | No route key | Add `NavCatalog`/`SurfacePageResolver` mapping; port database browse view |
| 15 | `projects` | **none** | **Blocked** | Only `KnownProjects`/`RecentProjects` chips in Mission Control | Add `NavCatalog` key; port `AgentLens/Views/Dashboard/Projects/ProjectsModels.swift` |

### 3.2 Settings leaf-page gap (current router)

From `SettingsPage.xaml.cs`: <ref_snippet file="/Users/albertonunez/Documents/Developer/BurnBar/windows/app/OpenBurnBar.App/Settings/SettingsPage.xaml.cs" lines="153-171" />

Only `General`, `Updates`, `DataPrivacy`, and `Appearance` have real pages. The `SettingsTabViewModelCatalog` has 11 real view-models, but the WinUI XAML leaves do not yet exist for:

- `Daemon` (`DaemonSettingsViewModel` + `DaemonSubstitutionMatrix`)
- `Agents` (`AgentsSettingsViewModel`)
- `ModelProxy` (`ModelProxySettingsViewModel`)
- `Alerts` (`AlertsSettingsViewModel`)
- `Notifications` (`NotificationsSettingsViewModel`)
- `TextExpansion` (`TextExpansionSettingsViewModel`)
- `ComputerUse` (`ComputerUseSettingsViewModel`)
- `Pets` (`PetsSettingsViewModel`)
- `Account` / `Cloud` / `DevicesAndSync` (DataGated on OAuth, but pages still needed)
- `Media` (still a placeholder; Mercury core deferred)

Sub-routes (`OperatorModel`, `DefaultView`, `DataRefresh`, `Indexing`, `SessionSummaries`, `DaemonLifecycle`, `HttpGateway`, `ControllerRuntime`, `AgentsAccounts/CLIs/Runtimes/Models/Advanced`, `FusionImpact`, `AnalysisConfigurator`, etc.) are also unmapped to leaf pages.

### 3.3 Missing top-level view areas

| macOS view folder | Files | Windows equivalent | Status |
|---|---|---|---|
| `AgentLens/Views/ComputerUse/` | 7 | `ComputerUseSettingsViewModel` only; no UI | Gap |
| `AgentLens/Views/Media/` | 9 | `SettingsPlaceholderPage` (`Media` tab); no Mercury UI | Gap |
| `AgentLens/Views/SmartHub/` | 3 | `OpenBurnBar.Integrations.*` cores, no wizard UI | Gap |
| `AgentLens/Views/Popover/` | 8 | `FlyoutWindow` covers tray but lacks `HermesPopoverStrip`, `InsightCardView`, `MercuryTraySection`, `CloudWhisperStrip`, etc. | Gap |
| `AgentLens/Views/Dashboard/Projects/` | 1 | No route/page | Gap |
| `AgentLens/Views/Dashboard/Layouts/Components/` | 4 | Only `ConceptStatTile` ported | Partial |

### 3.4 Engine / data / platform rows from the ledger

| Row | macOS | Windows | Status | Gap |
|---|---|---|---|---|
| Engine log parsers (15 providers) | `OpenBurnBarCore` parsers | `OpenBurnBarG2ParserParity` byte-diff on Windows CI | **Real** | — |
| SQLCipher byte-compat | GRDB | `Microsoft.Data.Sqlite` + `e_sqlcipher` | **Real** | Write/migration breadth is follow-on |
| CloudVault crypto KAT | `CloudVaultCrypto` | `OpenBurnBar.CloudSync.Crypto` | **Real** | Live cross-machine round-trip deferred |
| Quota portable parsers | `ProviderQuota` | `OpenBurnBar.App.Presentation/Quota` | **Real** | Acquisition + live Windows host still open |
| PAL named-pipe peer auth | Unix socket + codesign | Named pipe + signed nonce | **Real** | CNG/TPM key material on real Windows pending |
| Chat streaming | `ChatSessionController` (2100 LOC) | `ChatSurfaceViewModel`, `UnavailableChatStreamDriver` default | Blocked | Hermes/ConPTY live driver |
| Quota acquisition | `DispatchSource`/FSEvents | `FileSystemWatcher` + `%APPDATA%` defaults | Substituted | Live Windows paths + hook install proof |
| Firestore REST + live auth | Native SDK | `OpenBurnBar.CloudSync` gateway + fake transport | Substituted | Live authenticated round-trip |
| App Check (R14) | Apple App Attest | TPM `NCryptCreateClaim` + mock for tests | Blocked | Real vTPM/TPM proof on Win11 |
| E2EE round-trip | Seal on Mac → open on Mac | Crypto KAT parity | DeferredApproved | Win11 ↔ Mac live round-trip |
| Native FFI | iroh/burnbar-remote dylibs | C# uniffi shim, macOS loopback green | Substituted | MSVC runtime loopback (FFI-008) |
| Computer Use full loop | CGEvent/AX/Playwright | `SendInput`/UIA/Graphics.Capture/ViGEm adapters | Blocked | Full desktop loop on real Windows |
| Particles / 30 substrates | `KernelBackdrop`, `SwarmCanvas` | CPU port; Win2D spike | Blocked | 60fps ARM64 GPU proof |
| Pet companion | SceneKit/SpriteKit | WebView2 glTF host + overlay | Substituted | Live Windows overlay + glTF vendoring |
| Distribution | DMG + Sparkle | MSIX + winget + Ed25519 feed | Blocked | Authenticode cert, Store account, signed build |
| CI required check | macOS gates | `pr-windows-full.yml` | Blocked | Branch-protection flip (WS-A2) |

---

## 4. Why the gap is not just "missing code"

A large share of the remaining work is **validation and account/hardware access**, not typing more C#:

1. **XamlCompiler is Windows-only** — `NETSDK1100` on macOS. The WinUI app cannot be fully compiled or rendered here. The `DEV_HOST_RUNBOOK.md`/`WINUI-017` proof is the gate.
2. **TPM App Check (R14)** is the last named kill-risk. It needs a Windows 11 Pro VM with vTPM (or real hardware) and a backend mint endpoint.
3. **Live cloud round-trips** need a real Google OAuth Desktop client, Firebase Web API key, and an authenticated Windows build.
4. **GPU/Win2D 60fps spike** needs real Windows ARM64 GPU access.
5. **Signed distribution** needs an Authenticode/Trusted Signing cert and a Microsoft Partner Center account.

These are documented in `TONIGHT_PUNCHLIST.md` (C1–C7 / D1–D4) and `ALBERTO_PARITY_CHECKLIST.md`.

---

## 5. Execution plan to reach full parity

The plan keeps the existing wave boundaries but updates the exit criteria and dependencies from the current code state. It is intentionally ordered by **unblock power**, not by effort.

### Wave 0 — Truth & CI foundation (1–2 weeks)

1. **Land the ledger-honesty posture** — `WINDOWS_PARITY_LEDGER.yml` is already the source of truth; `verify-windows-parity-ledger.sh` passes. Keep it that way.
2. **Fix the native FFI freshness gate** — make `pr-windows-full` (or a pre-step) build the Rust cdylibs and run `check-csharp-binding-drift.sh` so the `NativeFact` loopback tests do not fail on stale dylibs. The macOS loopback is now green after `cargo build`; Windows needs the same.
3. **Make `pr-windows-full` a required check** on `main` (Alberto E1 / WS-A2).
4. **Update `windows/README.md`** and `HANDOFF.md` to point new agents to `WINDOWS_PARITY_LEDGER.yml` and this scan.
5. **Run a Windows dev-host validation pass** (someone with a Windows 11 ARM64 VM): `DEV_HOST_RUNBOOK.md` §3–5, `run-route-smoke.ps1`, collect `docs/windows-port/evidence/winui-017/`.

**Exit:** `main` green, ledger scanner green, `pr-windows-full` required, native tests green on both macOS and Windows, WinUI app compiles and route-smokes on real Windows.

### Wave 1 — Design-system + platform engine seams (3–5 weeks)

This is the foundation for all UI parity. Do not fan out surfaces until this is frozen.

1. **Design tokens** — emit `dist/winui/PensieveTokens.xaml` + `.cs` from `packages/design-tokens/config.mjs`; replace hand-seeded `Theme/Tokens.xaml`; add Swift↔C# brand-color parity tests.
2. **Liquid Glass → Mica/Acrylic contract** — finalize `LiquidGlass.cs` semantics (transparency `t∈[-1,1]`, `reduceTransparency`, `contentSurfacesEnabled`); document per-surface drift rubric and macOS goldens.
3. **Swarm / particle engine** — mandatory **Win2D 60fps ARM64 sub-spike** before fanning out 30 substrates. Keep `SwarmSimulation` math in Swift Core; vend `SwarmSubstrateFrame` over FFI; reimplement renderer in C#/Win2D.
4. **Pretext** — host the same `pretext.bundle.min.js` in offscreen WebView2; commit a text-layout metric corpus and a Mac↔Windows tolerance test; pin fonts.
5. **Shell completion** — `NavigationView` frame, resizable/reorderable flyout, Command Palette, global hotkey, DPI/theme plumbing.

**Exit:** design-system seams version-frozen and have ≥2 consumers; WINUI-017 60fps sub-spike recorded; Pretext corpus test green; all shared components build on Windows.

### Wave 2 — Live cloud, auth, App Check, storage (3–5 weeks)

Blocked partly on Alberto-owned items (VM, OAuth client, cert). Start as soon as the VM is available.

1. **Win11 Pro VM + SSH** — run `scripts/windows-port/vm-validate.ps1`; install toolchain; collect baseline screenshots.
2. **Google OAuth Desktop client** — wire `DesktopOAuthLoopbackFlow` with real client secrets; retire dev-token path.
3. **Firebase auth + live Firestore** — replace `DataSourceSettingsPage` paste-token flow; real ID token / OAuth; snapshot listeners against production.
4. **TPM App Check (R14)** — prove `NCryptCreateClaim` vTPM mint → enforced callable clears `firebase-admin`; this is the single biggest unblocker.
5. **CloudVault E2EE round-trip** — seal on Windows VM, open on Mac; retire `c5-e2ee-round-trip-deferral.md`.
6. **Storage write/migration seam** — extend the C# SQLCipher seam to full read/write parity; verify against Mac-produced DB on Windows.

**Exit:** a Windows machine appears as a real trusted device syncing real data with the Mac; App Check enforced; R14 + C5 closed.

### Wave 3 — Surface Real-data conversion (6–10 weeks)

After Waves 1–2, convert each `Substituted` surface to `Real` and add the missing `NavCatalog` keys.

1. **Add missing routes** — `database` and `projects` must become `NavCatalog` keys with `SurfacePageResolver` pages, or be formally `DeferredApproved` with a WPD.
2. **Dashboard** — wire real `SQLCipher`/`usage` summary; remove default `QuotaSampleData`/`SampleData` paths; finish `ProviderListPanel`, `SwarmRevealWindow`, `ConceptMoreDrawer`.
3. **Quota** — live `WindowsQuotaAcquisitionHost` + `FileSystemWatcher` + hook installer; prove `state.vscdb` + `wham/usage` + statusline hook on real `%APPDATA%`.
4. **Chat** — switch default driver to live `ConPTY`/`Hermes` stream; port `ChatSessionController` features (search, attachments, memory extraction, text-expansion drafts, desktop control access).
5. **SessionLogs / Memory** — remove sample fallbacks; live `CloudSyncMemoryStore` / `StorageSessionLogReadSource` as default.
6. **MissionControl** — `FirestoreMissionDispatchHost` as default; remove `DemoHost` from production.
7. **Budget** — live cloud budget rules; toasts on Windows.
8. **Insights** — live rollup; port chart widgets and `InsightWidgetRenderer`.
9. **DataControlCenter** — high-risk owner-action envelope (nonce/trustedDeviceId/actionProof) for `exportUserData`/`revokeAllAccess`.
10. **Switcher / Onboarding / ElderWand / Flyout** — remove sample defaults; live data; production empty-state.

**Exit:** every `NavCatalog` key renders real data; no `SampleData`/`DemoHost`/`Placeholder` on production routes; `WINDOWS_PARITY_LEDGER` rows promoted to `Real` with evidence.

### Wave 4 — Settings UI completion (4–6 weeks)

Build the real WinUI leaf pages for the 11+ settings tabs that currently have view-models but no page.

1. **Settings leaf pages** — one page per `SettingsTab` and `SettingsPageRoute`; map them in `SettingsPage.xaml.cs` so `PageTypeForRoute` never returns `SettingsPlaceholderPage` for a real tab.
2. **Settings search** — every `SettingsManifest` anchor must point to a real scroll target; no indexed-but-unreachable items.
3. **Media tab** — if Mercury core is deferred, keep an honest `DeferredApproved` page; otherwise build `MediaPermissionsView`.

**Exit:** all 16 tabs and ~40 leaf routes have real, reachable UI; `SettingsPlaceholderPage` only for explicitly deferred v1.1 tabs.

### Wave 5 — Integrations & advanced features (4–8 weeks)

1. **Computer Use** — full loop: `SendInput`/UIA/Graphics.Capture/ViGEm, kill-switch, audit chain, approval UI.
2. **Media / Mercury** — screen share, calls, file transfer UI; Windows capture/WASAPI/MF adapters.
3. **SmartHub / HomeAssistant / Cast** — setup wizard UI, live device pairing, mDNS/DNS-SD host.
4. **Pet** — live overlay, WebView2 glTF host, automated glTF vendoring.
5. **Native FFI msvc** — add cargo build step to `pr-windows-full` and run loopback tests on Windows runner.

**Exit:** G4 integration evidence committed; every live adapter demonstrated on real Windows.

### Wave 6 — Distribution & G5 (2–4 weeks, Alberto-gated)

1. **Authenticode / Trusted Signing cert** (Alberto B).
2. **Microsoft Partner Center + winget** (Alberto C).
3. **Signed MSIX build** in `openburnbar-release-windows.yml`; SHA-256 hashes.
4. **WinSparkle update round-trip** with Ed25519-pinned feed.
5. **Launch evidence bundle** — replace every `PLACEHOLDER` screenshot in `PARITY_CERTIFICATION_BUNDLE.md` §5 with real Win11 evidence.
6. **Make `pr-windows-full` required** already done in Wave 0; verify it stays green.

**Exit:** a signed, installable, auto-updating OpenBurnBar for Windows with a complete G5 evidence bundle.

---

## 6. Alberto-owned blockers (cannot be closed by agents)

| Item | Why it blocks | Reference |
|---|---|---|
| **Win11 Pro ARM64 VM with SSH** | C1–C7 in `TONIGHT_PUNCHLIST.md` — XamlCompiler, TPM, GPU, E2EE, computer-use, FFI msvc, screenshots | `TONIGHT_PUNCHLIST.md` C1–C7 |
| **Azure Trusted Signing / Authenticode cert** | Wave 5: no signed MSIX, no installable app, no auto-update | `ALBERTO_PARITY_CHECKLIST.md` B |
| **Google Desktop OAuth client + Firebase Web API key** | Wave 2 real sign-in and live Firestore proof | `ALBERTO_PARITY_CHECKLIST.md` D |
| **Microsoft Partner Center / Store account** | Wave 6 Store submission | `ALBERTO_PARITY_CHECKLIST.md` C |
| **Flip `pr-windows-full` to required check** | Wave 0 CI trustworthiness | `ALBERTO_PARITY_CHECKLIST.md` E1 |
| **GitHub production env `v*` tag rule + factory API key + App Check gcloud account** | CI greenness and release pipeline | `ALBERTO_PARITY_CHECKLIST.md` E2–E4 |

---

## 7. Immediate next actions (this week)

1. **Set up the Win11 Pro ARM64 VM and SSH** — this unblocks every hardware-gated item at once.
2. **Start Azure Trusted Signing organization validation** — multi-day lead time; do it now.
3. **Create the Google Desktop OAuth client** — minutes, unblocks real sign-in.
4. **Flip `pr-windows-full` to required** — minutes, ends admin-merge era.
5. **Agent-executable (no Alberto):** rebuild Rust cdylibs and commit the evidence that `OpenBurnBar.Native.Tests` now passes 25/25 on macOS; update `pr-windows-full` to build Rust cdylibs so the Windows native loopback test runs.

---

## 8. Test evidence collected during this scan

All `net10.0` portable test projects were run on macOS (this host). Total: **2,889 tests passed, 0 failed**.

| Project | Passed |
|---|---|
| `OpenBurnBar.App.Presentation.Tests` | 706 |
| `OpenBurnBar.App.Components.Tests` | 181 |
| `OpenBurnBar.App.Settings.Tests` | 75 |
| `OpenBurnBar.App.Settings.ViewModels.Tests` | 127 |
| `OpenBurnBar.App.Dashboard.Tests` | 75 |
| `OpenBurnBar.App.Onboarding.Tests` | 77 |
| `OpenBurnBar.App.Pet.Tests` | 74 |
| `OpenBurnBar.App.Quota.Tests` | 21 |
| `OpenBurnBar.App.Quota.Acquisition.Tests` | 57 |
| `OpenBurnBar.App.Chat.Runtime.Tests` | 2 |
| `OpenBurnBar.App.MissionControl.Tests` | 4 |
| `OpenBurnBar.App.TextExpansion.Tests` | 82 |
| `OpenBurnBar.App.Theme.Tests` | 70 |
| `OpenBurnBar.App.Shell.Tests` | 20 |
| `OpenBurnBar.App.Configuration.Tests` | 14 |
| `OpenBurnBar.App.CloudSync.Tests` | 59 |
| `OpenBurnBar.App.ManagedAgentRuntime.Tests` | 97 |
| `OpenBurnBar.App.CursorConnector.Tests` | 94 |
| `OpenBurnBar.App.Storage.Tests` | 8 |
| `OpenBurnBar.ComputerUse.Tests` | 107 |
| `OpenBurnBar.Integrations.Tests` | 163 |
| `OpenBurnBar.Integrations.Cast.Tests` | 79 |
| `OpenBurnBar.Integrations.Mercury.Tests` | 152 |
| `OpenBurnBar.CloudSync.Crypto.Tests` | 43 |
| `OpenBurnBar.CloudSync.AppCheck.Tests` | 55 |
| `OpenBurnBar.Pal.Input.Tests` | 66 |
| `OpenBurnBar.Pal.Ipc.Tests` | 20 |
| `OpenBurnBar.Dist.Tests` | 97 |
| `OpenBurnBar.Updater.Tests` | 94 |
| `OpenBurnBar.EngineBinding.Tests` | 3 |
| `OpenBurnBar.App.MemorySearch.Tests` | 138 |
| `OpenBurnBar.Native.Tests` | 25 |
| `OpenBurnBar.B0Spike.Tests` | 4 |

**Total: 2,889.**

---

## 9. Files that should be the source of truth going forward

- `docs/windows-port/WINDOWS_PARITY_LEDGER.yml` — machine-readable parity status
- `docs/windows-port/WINDOWS_PARITY_LEDGER.md` — ledger rules and scanner
- `docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md` — G5 evidence narrative
- `docs/windows-port/PHASE3_UI_PARITY_PLAN.md` — UI parity workstream sizing
- `docs/windows-port/TONIGHT_PUNCHLIST.md` — hardware/account blockers
- `docs/windows-port/ALBERTO_PARITY_CHECKLIST.md` — Alberto-only actions
- `windows/app/OpenBurnBar.App/Shell/NavDestination.cs` — Windows route catalog
- `windows/app/OpenBurnBar.App/Shell/SurfacePageResolver.cs` — page-to-route mapping
- `windows/app/OpenBurnBar.App/Settings/SettingsPage.xaml.cs` — settings leaf-page router
- `AgentLens/Views/Dashboard/DashboardNavigationModel.swift` — macOS route ground truth
- `AgentLens/Views/Settings/SettingsTab.swift` — macOS settings ground truth

This scan is a snapshot as of 2026-07-09. It should be re-run after the Win11 VM pass and after each wave closes, updating the ledger and this plan with fresh evidence.
