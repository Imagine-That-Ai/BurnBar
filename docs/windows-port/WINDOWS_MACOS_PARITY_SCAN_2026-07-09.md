# Windows ↔ macOS full parity scan

**Date:** 2026-07-09  
**Branch context:** `windows/liquid-glass-kernel-reskin` (diverged from origin; ledger is the status authority)  
**Method:** Live inventory of `AgentLens/` + `windows/`, machine ledger `WINDOWS_PARITY_LEDGER.yml` (33 rows), shell/nav/settings code, WPD decisions, and prior remediation docs.  
**Authority:** Production-parity status is **only** the ledger (`Real` / `Substituted` / `DeferredApproved` / `Blocked`). **Authored / route-resolves is never parity.**

> **Strategy supersession:** The inventory in this file remains useful. **Phases, ordering, and “full parity” language in §6–7 are superseded** by the adversarially hardened plan in [`WINDOWS_PARITY_STRATEGY_V2.md`](WINDOWS_PARITY_STRATEGY_V2.md) (F1 Ship Peer vs F2 True 1:1, chat≠ConPTY, honesty H0, residual risks U1–U8).

---

## 1. Honest headline

| Layer | Honest estimate | What you feel in the app |
|---|---|---|
| **Portable logic** (parsers, crypto, state machines, storage seams, integrations cores) | **~80–85%** | Invisible — works in tests, not always wired into UI |
| **UI surfaces that exist as real Pages** | **~12 of ~14 top-level destinations** | Shell looks broad |
| **UI surfaces with production live data (no sample/stub default)** | **~0–2 of those** (onboarding/settings partial) | Almost everything empty, sample-gated, or placeholder |
| **Ledger-certified Real** | **5 / 33 rows** | Foundation only |
| **End-to-end on real Windows (cloud + GPU + CU + install)** | **~15%** | Needs VM + accounts |
| **Shippable signed installer** | **0%** | No Authenticode / Trusted Signing |

**Working total for “peer product parity” (what a Mac user expects when clicking around): ~50–55%.**  
Agent-only ceiling without VM/accounts: ~65%. Full G5 ship: remaining work is mostly **live composition + host proof + Alberto procurement**, not greenfield architecture.

### Ledger histogram (2026-07-09)

| Status | Count | Meaning |
|---|---:|---|
| **Real** | 5 | Production-proven |
| **Substituted** | 16 | Surface/core exists; not full peer data/behavior yet |
| **Blocked** | 9 | Missing route, external gate, or host-only proof |
| **DeferredApproved** | 3 | Named WPD / signed deferral with revive trigger |

**Real today:** `engine-parsers-g2`, `storage-sqlcipher-byte-compat`, `cloudvault-crypto-kat`, `pal-ipc-named-pipe`, `quota-portable-parsers`.

**Blocked today:** `nav-chat`, `nav-database`, `nav-projects`, `appcheck-tpm`, `firebase-oauth-windows`, `particles-gpu-60fps`, `computer-use-loop`, `dist-msix-signed`, `ci-windows-full-gate`.

---

## 2. Architecture already decided (do not re-litigate)

| Decision | Choice | Impact on parity |
|---|---|---|
| **WPD-0005** storage | C# SQLCipher seam permanent; Swift Engine compute-only on Windows | No GRDB port; Mac DB open is proven |
| **WPD-0006** daemon | No monolithic daemon port; per-capability Tier-C substitution | Gateway / Pensieve / many daemon duties = v1.1 named deferrals |
| **WPD-0007** process model | In-process facades, not a Windows Service for data lanes | Mission/CLI/usage live in the app process |
| **WPD-0003** project-code static parser | Deferred; lexical fallback | Projects/memory depth thinner than Mac |
| **WPD-0001** bindings | C# uniffi path for iroh + burnbar-remote | FFI msvc loopback still host-gated |
| **UI stack** | WinUI 3 + Mica/Acrylic (Liquid Glass ≈ Mica) | Accepted visual drift (D1) |
| **Engine stack** | Option A: Swift Engine subset on Windows MSVC | Storage / some Apple subsystems pruned by design |

Tier-C (not bugs): Sign in with Apple → MSA/Google/email; iCloud mirror → OneDrive/Firestore; App Intents/Siri → command palette + hotkeys; secure-desktop virtual HID → v1.1.

---

## 3. Navigation map: macOS vs Windows

### macOS primary Command Deck (`DashboardMainRoute.primarySections`)

1. **Chat**  
2. **Quota**  
3. **Database** ← **NO Windows nav key**  
4. **Projects** ← **NO Windows nav key**  
5. **Missions**  
6. **Session Logs**  
7. **Memory**

Plus peers: Overview, Insights, Settings, flyout/menu-bar, Budget, Elder Wand, provider/model drill-ins.

### Windows `NavCatalog` (12 sidebar + 1 auxiliary)

| Key | Page | Ledger | User-visible state when browsing |
|---|---|---|---|
| `dashboard` | `DashboardPage` + 6 layouts | Substituted | Can empty-state; live usage not default-proven |
| `chat` | `ChatHostPage` | **Blocked** | Default `UnavailableChatStreamDriver`; ConPTY not production-proven |
| `insights` | `InsightsPage` | Substituted | Charts exist; live rollups incomplete |
| `quota` | `QuotaWorkspacePage` | Substituted | Parsers Real; watchers/OAuth snapshots not full |
| `sessionLogs` | `SessionLogsHostPage` | Substituted | Storage path exists; sample fallback seams remain |
| `memory` | `MemoryPage` | Substituted | Cloud-backed only with creds; App Check/OAuth blocked |
| `missionControl` | `MissionControlPage` | Substituted | Firestore host real code; demo host sample-only |
| `budget` | `BudgetPage` | Substituted | Rules UI; live cloud budget incomplete |
| `dataControlCenter` | `DataControlCenterPage` | Substituted | Callables unit-tested; live auth + high-risk envelope blocked |
| `switcher` | `SwitcherHostPage` | Substituted | Encrypted store proven; must not default sample |
| `onboarding` | `OnboardingPage` | Substituted | Wizard present; full first-run Windows proof outstanding |
| `settings` | `SettingsPage` | Substituted | **Most tabs → `SettingsPlaceholderPage`** |
| `elderWand` (palette only) | `ElderWandPage` | Substituted | Reachability D8; live catalog empty without sample |
| **database** | — | **Blocked** | Missing route entirely |
| **projects** | — | **Blocked** | Not top-level; MC chips ≠ parity |

**Flyout/tray:** `FlyoutWindow` + tray — Substituted (sample tray under sample mode).

---

## 4. Full gap register (product → Windows)

Legend: **Done** / **Shell** (UI exists) / **Core** (logic/tests, thin UI) / **Missing** / **Host** (needs Windows VM) / **Alberto** (accounts/certs) / **v1.1**.

### A. Shell & navigation

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Menu bar + popover | Primary | Tray + flyout | Shell; live tray data Host |
| Command palette | Command Deck | `CommandPalette` | Recent sessions stub |
| Global hotkeys | Carbon | `GlobalHotkeyService` | Host proof |
| Section shortcuts ⌘1–7 | primarySections | Partial / different IA | **database/projects missing** |
| Liquid Glass | `glassEffect` | Mica/Acrylic | Substituted (D1); 60fps GPU Host |
| Kernel backdrops / particles | SceneKit/swarm | Win2D substrates | Core; **60fps ARM64 Blocked** |
| DPI / theme / high contrast | Full | Partial | Design polish |

### B. Dashboard & usage

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Overview + 6 layouts | Full | All 6 XAML layouts | Shell; live usage Host |
| Provider/model drill-in | Yes | Command sidebar partial | Depth |
| Burn hero / spend rail | Yes | `BurnHeroControl` | Live seams |
| Easter-egg physics | Yes | Host present | Host |
| Session ledger | Yes | Component present | Live data |

### C. Chat & agents

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Hermes full canvas | ~60 Swift files | ~16 XAML/cs | **Depth gap** |
| Streaming state machine | Full | Portable SM present | Wiring |
| Pretext layout engine | WKWebView | WebView2 host | Metric parity Host |
| ConPTY / interactive CLI | PTY | ConPTY + Stub default | **Blocked / Host** |
| Multi-pane workspace | PaneWorkspace | Missing | **Missing** |
| Elder Wand | Full configurator | Page + sections | Live models |
| Managed agent runtimes | Full | Pi adapter core | Composition |
| Cursor connector | Full | Core + tests | Live Windows paths |
| Atom chips / thinking UI | Full | Partial components | Depth |

### D. Quota, budget, parsers

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Log parsers (15+ providers) | Swift Engine | G2 byte-identical **Real** | — |
| Quota acquisition (statusline, vscdb, hooks) | Full | Portable + Windows host composition | Host live watch |
| Quota workspace UI | Full | Arc dial + constellation | Live default path |
| Full ~20 quota adapters / billing APIs | Broad | 4 portable parsers Real; rest thinner | Expand adapters |
| Budget rules / block / toast | Full | Page + chip + toast | Cloud budget |

### E. Data, memory, projects, database

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| SQLCipher schema / read | GRDB | C# seam **Real** | Write breadth follow-on |
| Session logs browser | Full | List-detail | Production composition |
| Memory review inbox | Full | Page + cloud store | OAuth / App Check |
| Memory search / vector | Full | Portable memory-search | Full product wiring |
| **Database workspace** (Atlas/Story/System) | Large multi-mode UI | **No route** | **Blocked — port or WPD** |
| **Projects** (folders, memory, sheets) | Full | **No top-level** | **Blocked — port or WPD** |
| Project-code static parser | Rust | Deferred WPD-0003 | v1.1 / revive |

### F. Mission Control & daemon duties

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Mission console UI | Full | Situation room / composer / FAB | Live dispatch Host |
| Firestore mission dispatch | Daemon/app | `FirestoreMissionDispatchHost` | Auth |
| HTTP local gateway | Daemon | **v1.1 deferral** (WPD-0006) | Named |
| Pensieve watcher | Daemon | **v1.1** | Named |
| Provider router headless | Daemon | Partial substitution | Matrix rows |
| Monolithic Windows Service | LaunchAgent | **Rejected for v1** | — |

### G. Cloud, identity, privacy

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Firebase Auth | Apple + OAuth | Desktop OAuth code ready | **Alberto OAuth client** |
| App Check | App Attest | TPM/CNG path | **Blocked R14 Host** |
| CloudVault crypto | Full | KAT **Real** | Live C5 Host (DeferredApproved) |
| DCC export/delete/recovery/revoke | Full | Callable hub unit-tested | Live + high-risk envelope |
| Trusted devices chain | Full | Partial / data-gated | App Check |
| Settings → Cloud / Account / Devices | Full UI | VMs portable; **pages mostly Placeholder** | XAML leaf pages |

### H. Settings (16 tabs — biggest click-around pain)

| Tab | Mac UI | Windows UI today | VM layer |
|---|---|---|---|
| Home | Full | Placeholder / thin | — |
| General | Full | **Real page** | — |
| Updates | Full | **Real page** | — |
| Appearance (route) | Full | **Real page** | — |
| Data & Privacy | Full | **Real page** (data source) | — |
| Daemon / Engine Room | Full | Placeholder UI | Live VM |
| Account | Full | Placeholder UI | DataGated VM |
| Cloud | Full | Placeholder UI | DataGated VM |
| Agents | Full + Connections wizard | Placeholder UI | Live VM |
| Model Proxy | Full | Placeholder UI | Live VM |
| Alerts | Full | Placeholder UI | Live VM |
| Notifications | Full | Placeholder UI | Live VM |
| Devices & Sync | Full + Smart Displays | Placeholder UI | DataGated VM |
| Text Expansion | Full + global hook | Placeholder UI + core | Live VM; hook Host |
| Media & Sharing | Full Mercury | **Placeholder only** | Mercury core Phase 4 |
| Computer Use | Full | Placeholder UI | Core + Windows adapters Host |
| Pets | Full | Placeholder UI | Pet core; overlay Host |
| Settings Copilot | Full | Missing | Missing |
| Connections / Provider Plan wizard | Large | Partial under Agents VM | Depth |
| Fusion Impact / Local Metrics | Present | Missing or thin | Depth |

`SettingsPage.xaml.cs` routes only General / Updates / DataPrivacy to real pages; **everything else → `SettingsPlaceholderPage`**. Portable VMs exist for 11 tabs but are not bound as production XAML leaves.

### I. Computer Use, Pet, integrations

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| CU policy/token/audit/kill-switch | Full | Core + tests | — |
| SendInput / UIA / WGC | Apple APIs | Windows adapters present | **Full loop Host Blocked** |
| ViGEm / secure desktop | Partial | Partial | v1.1 secure desktop |
| Pet companion | SceneKit + 100+ models | Behavior + WebView2 glTF shell | Live overlay Host |
| Cast | Full | Portable + Windows socket/mDNS | Live session Host |
| Home Assistant | Full | Portable REST | Live instance Host |
| SmartHub / Nest hub | Full | Portable bridge + mDNS | Live Host |
| Mercury media (calls/files/screen) | Full | Portable + Win capture adapters | Live cross-device Host |
| PixelClock / AWTRIX | Settings + firmware | Thin / absent UI | Missing product surface |

### J. Distribution & CI

| Capability | Mac | Windows | Gap |
|---|---|---|---|
| Signed install + update | Sparkle/DMG/Homebrew | MSIX manifests, WinSparkle verify | **Alberto cert** |
| winget / choco | cask | Manifests ready | After signed artifact |
| Store | MAS | Partner Center | Alberto |
| Windows full CI required | Strong | Workflow exists | **Alberto branch protection** |
| Parity ledger scanner | — | Phase 0 honesty gate | Live on PR |

---

## 5. Why the app still “feels unported”

Even where XAML pages exist, production composition often:

1. **Defaults to unavailable / stub** — e.g. chat `UnavailableChatStreamDriver`, CLI `StubCliStream` off Windows or forced.
2. **Keeps sample seams** — `*SampleData`, `MissionDispatchDemoHost`, sample tray (gated by `OPENBURNBAR_SAMPLE_MODE` in places, but not all surfaces are Real).
3. **Shows Settings placeholders** — majority of settings tabs.
4. **Omits whole Mac sections** — Database workspace, Projects.
5. **Blocks cloud** — no Desktop OAuth client + no TPM App Check proof → Memory, DCC, Mission dispatch, Account/Cloud/Devices stay hollow.
6. **Skips depth** — chat panes, Settings Copilot, Connections wizard, PixelClock UI, multi-provider quota adapters.

Foundation (parsers, DB open, CloudVault KAT, named-pipe auth) is strong; **product wiring and host proof are not**.

---

## 6. Plan to full parity

Aligned with master-plan gates G2→G5 and Waves 0–5. Sizing is PR-order-of-magnitude for factory execution.

### Phase 0 — Unblock human gates (parallel, calendar-bound)

**Owner: Alberto** (see `ALBERTO_PARITY_CHECKLIST.md`)

| # | Action | Unlocks |
|---|---|---|
| A | Win11 ARM64 VM + SSH + toolchain | C1–C7 host proofs |
| B | Azure Trusted Signing (start now) | Signed MSIX / G5 |
| C | Microsoft Partner Center | Store |
| D | Google Desktop OAuth client + Firebase Web API key secrets | Real sign-in |
| E | Require `PR Windows Full Gate` on main | CI trust |
| F | (optional) App Check smoke GCP SA | Ops |

**Exit:** Agents can drive VM over SSH; OAuth secrets named; cert validation in progress.

### Phase 1 — Close host-blocked Real rows (1–2 weeks after VM)

| Work | Ledger target | Evidence |
|---|---|---|
| `dotnet build/test` full solution on VM | — | C1 |
| ConPTY chat production driver as default on Windows | `nav-chat` → Substituted then Real | C1/C4 |
| TPM App Check mint → enforced callable | `appcheck-tpm` → Real | C2 |
| Desktop OAuth end-to-end | `firebase-oauth-windows` → Real | D4 + C1 |
| Win2D 60fps ARM64 | `particles-gpu-60fps` → Real | C3 |
| Computer-use full loop | `computer-use-loop` → Real | C4 |
| Windows-seal → Mac-open E2EE | `cloudvault-live-roundtrip` → Real | C5 |
| Native FFI msvc loopback | `native-ffi-msvc` → Real | C6 |
| Launch screenshots for bundle §5 | G5 prep | C7 |

**Exit:** No remaining **kill-risk** Blocked rows except dist/CI if cert still pending.

### Phase 2 — Navigation completeness (missing Mac primary sections)

| Work | Notes |
|---|---|
| Port **Database workspace** (or multi-mode subset: System + Story first) | New `NavCatalog` key `database` + `DatabaseWorkspacePage`; wire storage seams |
| Port **Projects** top-level | New `projects` key; project list + detail + memory attach |
| Reconcile Command Deck order with Mac primarySections | Shortcuts + palette parity |
| Command palette recents from storage (kill stub) | |

**Exit:** Ledger `nav-database` / `nav-projects` leave Blocked; primary IA matches Mac.

### Phase 3 — Settings leaf completion (highest UX ROI)

| Work | Notes |
|---|---|
| Bind existing VMs to real XAML pages (Daemon, Agents, ModelProxy, Alerts, Notifications, TextExpansion, ComputerUse, Pets) | Stop routing to `SettingsPlaceholderPage` |
| Account / Cloud / Devices pages on live OAuth | DataGated → Live |
| Media tab → Mercury settings surface | After Phase 4 live adapters or honest empty with deep-links |
| Settings Home health surface | |
| Settings Copilot (or explicit Tier-C “command palette only” if deferred with WPD) | |
| Connections / Provider Plan wizard depth | Under Agents |
| Smart Displays / PixelClock cards under Devices | Integrate SmartHub cores |

**Exit:** `nav-settings` can become Real (no production `SettingsPlaceholderPage` on route map).

### Phase 4 — Surface Real conversion (sample death)

For each Substituted nav row, force production composition:

1. Default path = live seams only (no SampleData types on cold start).  
2. Empty/loading/error/populated goldens.  
3. Automated test-shaped path + evidence under `docs/windows-port/evidence/`.  
4. Flip ledger row via scanner.

Priority order (user-visible):

1. Dashboard + flyout tray  
2. Quota + budget  
3. Session logs + memory  
4. Mission control + DCC  
5. Insights + Elder Wand  
6. Switcher + onboarding first-run  
7. Chat (after ConPTY Real)  
8. Pet overlay live  

**Exit:** Zero sample-default surfaces; majority of nav rows **Real**.

### Phase 5 — Chat depth + design system

| Work | Notes |
|---|---|
| Multi-pane chat workspace | Port PaneWorkspace concepts |
| Pretext metric parity within tolerance | design/0005 |
| Hermes atom completeness | Tools, citations, thinking |
| Managed runtimes + Cursor connector live paths | Windows profile paths |
| Liquid Glass polish pass vs Mac goldens | Accepted D1 drift list frozen |
| Particle substrate fidelity | After 60fps Real |

### Phase 6 — Integrations & Computer Use productization

| Work | Notes |
|---|---|
| CU session UI + approval + audit viewer | Settings + chat integration |
| Cast / HA / SmartHub live sessions | Evidence in bundle |
| Mercury file/screen/call Windows↔Mac | |
| Text expansion global `WH_KEYBOARD_LL` proof | Security review |

### Phase 7 — Ship (G5)

| Work | Notes |
|---|---|
| Signed MSIX + portable zip in release workflow | After Trusted Signing |
| Live update round-trip + downgrade block | |
| winget-pkgs PR + optional choco | |
| Store submission | Partner Center |
| Freeze `PARITY_CERTIFICATION_BUNDLE` | All PLACEHOLDERs replaced |
| `dist-msix-signed` + remaining ledger → Real | |

### Explicit v1.1 (not blocking “peer parity” if named)

- Secure-desktop / lock-screen virtual HID (WHQL).  
- Monolithic daemon-as-Service revive (WPD-0006 trigger).  
- Project-code static parser Windows msvc (WPD-0003).  
- Full Pensieve gateway / headless multi-client daemon duties.  
- MAS-only / Apple-only features (Tier-C already listed).

---

## 7. Recommended execution order (next 30 days)

```text
Week 0 (you):  A VM+SSH, B cert, D OAuth secrets, E CI required-check
Week 1:        Phase 1 host proofs C1–C6 in parallel lanes
Week 2:        Phase 2 Database + Projects routes (empty→storage-backed)
Week 2–3:      Phase 3 Settings leaf XAML bind (placeholder death)
Week 3–4:      Phase 4 sample-death for Dashboard/Quota/Logs/Memory/Missions
Ongoing:       Ledger flip per row; no “Authored” language
When cert lands: Phase 7 packaging
```

Factory lane: **structured large** for Database/Projects/Chat depth; **fast lane** for settings leaf binds and sample-path deletions. Every PR: `bash scripts/ci/verify-windows-parity-ledger.sh`.

---

## 8. Metrics of “done”

Full peer parity = all of:

1. Every Mac `primarySections` route has a Windows peer (or DeferredApproved WPD).  
2. Ledger: **0 Blocked** for product rows; Dist/CI Real; only intentional DeferredApproved remain.  
3. Cold-start production: no `SampleData` / `DemoHost` / `StubCli` / `SettingsPlaceholder` / `Unavailable*` on default paths.  
4. Real Firebase user on Windows syncs with Mac (App Check + OAuth + C5).  
5. Signed install + update works on clean Win11 x64 and ARM64.  
6. G3 visual review vs Mac goldens signed off (with D1 drift list).  
7. Computer-use and Pet demonstrated once on real Windows with evidence.

---

## 9. Source index

| Artifact | Role |
|---|---|
| `docs/windows-port/WINDOWS_PARITY_LEDGER.yml` | Machine SoT |
| `docs/windows-port/WINDOWS_PARITY_LEDGER.md` | Human rules |
| `docs/WINDOWS_PORT_MASTER_PLAN.md` | Spec v2.1 |
| `docs/windows-port/PARITY_100_REMEDIATION_PLAN.md` | Waves (partially stale numbers; ledger wins) |
| `docs/windows-port/PHASE3_UI_PARITY_PLAN.md` | UI PR budget |
| `docs/windows-port/ALBERTO_PARITY_CHECKLIST.md` | Human gates |
| `docs/windows-port/TONIGHT_PUNCHLIST.md` | VM C1–C7 |
| `docs/windows-port/decisions/0005–0006` | Storage + daemon |
| `windows/app/.../Shell/NavDestination.cs` | Live IA |
| `windows/app/.../Settings/SettingsPage.xaml.cs` | Placeholder map |

---

## 10. Scan method notes

- Counts from `WINDOWS_PARITY_LEDGER.yml` parse (33 rows).  
- Windows UI: ~105 XAML files under `OpenBurnBar.App`; ~150k C# LOC under `windows/` (excl. bin/obj).  
- macOS app: ~270k Swift LOC under `AgentLens/`.  
- Chat depth: Mac ~60 files vs Windows ~16.  
- Settings: 16 tabs mirrored in enum; 4 real WinUI pages; 11 portable VMs; 1 media-only placeholder strategy.  
- This scan does **not** claim G3/G4/G5 closed; it reconciles code + ledger against what a user sees when clicking through the shell.
