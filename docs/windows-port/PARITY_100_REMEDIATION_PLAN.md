# Windows ↔ macOS Parity: Honest Assessment & 100% Remediation Plan

**Date:** 2026-07-05
**Author:** Claude (repo-wide audit: macOS feature inventory + Windows code audit + docs/git claims review, cross-checked)
**Companion docs:** `docs/WINDOWS_PORT_MASTER_PLAN.md` (phases/gates), `docs/windows-port/PARITY_CERTIFICATION_BUNDLE.md` (living G5 ledger), `docs/windows-port/HANDOFF.md` (partially stale, 2026-07-03)

---

## 1. TL;DR — the honest number

**The Windows app is roughly 40% of the way to true parity, not "almost done."**

Broken down honestly:

| Layer | Parity | Basis |
|---|---|---|
| Portable logic (parsers, crypto, state machines, protocol codecs) | ~65–70% | ~126K LOC C#, ~1,677 test methods, real x64+ARM64 CI (`pr-windows-full.yml`) |
| UI surfaces authored (XAML exists, navigable) | 13/13 destinations | But only **4/13 are "Real"** (live data); 9 run on sample/seeded data |
| End-to-end proven on real Windows (live data, live cloud, OS integration) | ~10–15% | Every OS boundary is dev-host-deferred; all launch evidence is PLACEHOLDER |
| Shippable artifact (signed installer a user can run) | 0% | No Authenticode cert (W0), MSIX never built/signed, updater round-trip never run |

The port's architecture is sound and deliberately staged (portable `net8.0` cores tested on macOS + thin deferred Windows adapters), so this is *honest scaffolding*, not fake work — but "authored and unit-tested" has been allowed to read as "done" in some docs. Gate status per the repo's own ledger: **G0 ✅ G1 ✅ G2 ❌ (headline PROVEN 2026-07-06 — Wave 1 item 1; remaining G2 items open) G3 ❌ G4 ❌ G5 ❌**.

---

## 2. Claims vs. reality (verified 2026-07-05)

| Claim (where) | Reality (verified) |
|---|---|
| "Phase 1 done, walking skeleton green" (HANDOFF §0) | TRUE — but the Windows Swift Engine lane compiles a **pruned subset** (GRDB storage, AgentInsights, TextExpansion, App Check contracts pruned). **Update 2026-07-06:** the *storage* half of that prune is now decided permanent architecture (**WPD-0005**, Engine compute-only + C# seam owns storage); the waiver is retired and the flag is gated by `verify-windows-storage-architecture.sh`. The non-storage pruned subsystems remain Phase-2+ gaps. |
| "All 17 parity-burndown PRs landed" (#1267, 2026-07-04) | TRUE they're on `main` — but per `PARITY_MERGE_RUNBOOK.md` they were **admin-merged past 9 red required checks**, and a same-day repair (`fbb601591f`, "restore Swift core validation") is still unmerged on `origin/fix/windows-signal-core-contract-leaf`. |
| "Byte-identical parser output" | Proven only via **macOS-host contract tests**. The G2 headline — Windows-side byte-identical diff in CI — is explicitly "tracked as FIX" (bundle §2). |
| "E2EE parity proven" | Vector/KAT parity is byte-identical C#↔Swift↔TS ✅. The **live** Windows-seal→Mac-open round-trip is Alberto-signed deferred (`c5-e2ee-round-trip-deferral.md`). |
| "13/13 surfaces resolve" (bundle) | TRUE — but only sessionLogs, memory, onboarding, settings are "Real". Dashboard, quota, chat, mission control, budget, DCC, insights, ElderWand, switcher run on sample/authored data. |
| "~2,545 test fixtures" (windows/README) | ~1,677 `[Fact]`/`[Theory]` methods visible in source; the larger number counts Windows-only theory expansions. Tests cover portable logic only — zero WinUI rendering, WebView2, input synthesis, TPM, live Firebase, or MSIX coverage. |
| `PARITY_BURNDOWN_PLAN.md` (cited by 2 docs) | **Does not exist anywhere in git history.** The WS-* lane definitions live only outside the repo. |

**Additional red flags:**
- ~~`windows/native/` is an **empty skeleton** — the Rust↔managed FFI shim (iroh, burnbar-remote) does not exist; crates build in CI but nothing binds them.~~ **CLOSED 2026-07-06 (Wave 1 item 4):** `windows/native/` now carries the real shim — `OpenBurnBar.Native` (hardened absolute-path loader + graceful `NativeShimUnavailableException`), `OpenBurnBar.Native.BurnBarRemote` + `OpenBurnBar.Native.Iroh` (availability-gated facades over the committed uniffi-bindgen-cs bindings for BOTH crates, per WPD-0001), `windows/tests/native` (25 tests: locator/surface/shape on any host + real-FFI loopback that ran green against cargo-built dylibs on macOS and skips when absent), and a codegen-drift gate (`scripts/windows-port/check-csharp-binding-drift.sh` + `csharp-binding-drift.yml`). The msvc-runtime execution of the same loopback (FFI-008) still needs a Windows-runner cargo step.
- ~~`CloudSyncCallableHub.cs:35–62`: **8 of 9 cloud callables throw `NotImplementedException`**~~ **RESOLVED 2026-07-06 (PR pending):** all 9 callables (exportUserData, deleteDomainData, listRecovery, setupRecovery, confirmRecovery, revokeAllAccess, getAuditLog, verifyAuditLog) are wired to the deployed Firebase Functions wire contract and covered by 32 `windows/tests/cloudsync-app/CloudSyncCallableHubTests.cs` tests (per-callable response decode + request-payload-shape + signed-out `NotSignedInException`) that drive the injectable transport seam with recorded responses. **Still WS-D-deferred:** the live authenticated round-trip (real Firebase tokens) and the high-risk-owner-action envelope (nonce / trustedDeviceId / actionProof) that the macOS caller layers on `exportUserData` + `revokeAllAccess` — that envelope needs the Windows Signal-identity + TPM path (R14, Wave 2 item 1).
- Engine binding is interim **`swift run`** (drift D7); UniFFI bindgen still open (WPD-0001).
- ~~1,288 compiled DLLs committed into the tree~~ **CORRECTED 2026-07-06:** those binaries are local `bin/`/`obj/` build outputs — all gitignored (root `.gitignore` `**/bin/`+`**/obj/`) and **untracked**; `git ls-tree origin/main -- windows/` is 100% text. The only real event (104 binaries, ~4.7 MB, commit `9e6912bc8d`) was removed the same day in PR #1190. Residual risk is only a future force-add — closed by a no-tracked-binaries tripwire in `scripts/debt/check-windows-tree-budget.sh`.
- `pr-windows-full.yml` is real (x64 + windows-11-arm dotnet build+test) but **not yet a required check** (WS-A2 pending Alberto).
- `windows/README.md` still opens with "No product code lives here yet" — stale and misleading.

---

## 3. Gap register (macOS feature → Windows state)

Baseline: macOS app = `AgentLens/` (~266K LOC) + `OpenBurnBarCore/` (~150K) + `OpenBurnBarDaemon/` (~54K). iOS-only (`OpenBurnBarWidget`, `OpenBurnBarKeyboard`) excluded.

| # | macOS feature | Windows state | Gap class |
|---|---|---|---|
| 1 | Menu-bar popover (primary surface) | Tray + FlyoutWindow authored | Real-data wiring |
| 2 | Dashboard + 6 layouts (Atelier/Aurora/Classic/Cockpit/Constellation/Nebula) | All 6 layouts authored | Sample data → live seams |
| 3 | Quota workspace; ~20 quota adapters, 30+ providers, billing APIs | 4 parsers ported (Claude statusline, Cursor, Codex, Anthropic headers); acquisition (statusline hook, `state.vscdb`, credential probes, file-watch) deferred | Major — "full 20 in flight" |
| 4 | 15 log parsers (Swift engine) | Via Swift-on-Windows engine subset; Windows-side byte-diff (G2 headline) unproven | G2 blocker |
| 5 | Session logs + SQLCipher DB | Read seam proven byte-compat ✅; **write path deferred**; engine CI lane still storage-pruned | Waivered gap |
| 6 | Chat (Hermes, ElderWand, panes, streaming) | Views + state machine authored; ConPTY path Windows-only, dev-host uses `StubCliStream` canned recording | Live proof |
| 7 | Cloud sync (10+ domain services, Firestore listeners) | REST gateway + offline queue + fail-closed guard authored; **live transport deferred**; ~~8/9 callables `NotImplementedException`~~ **all 9 DCC callables wired + tested (2026-07-06)** — live transport + high-risk envelope WS-D | Major |
| 8 | E2EE / CloudVault / escrow / trusted devices | Crypto KAT byte-parity ✅; live round-trip deferred (C5); recovery/revoke callables unimplemented | Major |
| 9 | App Check (device attestation) | Server half built; **Windows TPM/CNG client (R14) = last named kill-risk, unproven** | Kill-risk |
| 10 | Daemon (54K LOC: HTTP gateway, provider router, Mission Control DAG, Pensieve, planner) | **DECIDED 2026-07-06 — WPD-0006** (`docs/windows-port/decisions/0006-windows-daemon-strategy.md`): no monolithic port; per-capability Tier-C substitution (34-row matrix: 9 substituted-already incl. `FirestoreMissionDispatchHost`/ConPTY/usage seams, 3 to-build in Waves 3–4, 18 named v1.1 deferrals, 4 N/A). Revive path = daemon Linux boundary build as a Windows Service | Decided — executing per WPD-0006 matrix |
| 11 | Computer Use (full loop, Playwright, virtual HID, Agent Watch) | Core policy/token/audit code + 100 tests ✅; SendInput/UIA/capture/ViGEm adapters unproven; full loop = Phase 4 | Phase 4 |
| 12 | Pet companion (100+ models, SceneKit/SpriteKit) | Behavior core + WinUI shell + WebView2 three.js host authored; glTF vendoring is a manual dev step; never run on Windows | Live proof |
| 13 | Particles/backdrops (~30 substrates, KernelBackdrop) | 30 substrates ported (CPU); Win2D GPU render deferred; **60fps ARM64 spike (WINUI-017) mandatory, pending** | G3 blocker |
| 14 | Settings: 16 tabs, search, Copilot | 5 real pages + `SettingsPlaceholderPage` for the rest; search indexes tabs that have no UI | Major |
| 15 | Integrations: Cast, Home Assistant, SmartHub/Nest, AWTRIX/PixelClock, Mercury media | Portable cores + tests ✅ (Cast protobuf/mDNS, HA REST, RFB/VNC codecs); live sockets/capture deferred; AWTRIX/PixelClock absent | Phase 4 |
| 16 | Iroh P2P + BurnBarRemote (Rust) | Crates build in CI; `windows/native/` shim LANDED 2026-07-06 (loader + both uniffi C# bindings + facades + 25 tests incl. real macOS FFI loopback + drift gate); msvc-runtime loopback (FFI-008) pending a Windows-runner cargo step | Shim landed; FFI-008 pending |
| 17 | Updater (signed feed, channels) | Ed25519 feed verify + WinSparkle interop authored; live round-trip never run | G5 |
| 18 | Packaging/distribution (DMG/Homebrew/MAS ↔ MSIX/winget/choco/Store) | Manifests + verify kernels only; **no cert, no signed build, nothing installable** | G5 / Alberto-blocked |
| 19 | Onboarding (8 steps) | Ported ✅ (one of the 4 "Real" surfaces) | — |
| 20 | Memory/search (vector, reranker, extraction), Text Expansion, Managed runtimes, Cursor connector, account switcher store, Settings Copilot, analytics | Absent or sample-data-only on Windows; TextExpansion/AgentInsights pruned from engine lane | Long tail |

---

## 4. Remediation plan to 100%

Ordered waves; each has a hard exit criterion. Aligns with master-plan gates. Rough sizing uses the repo's own PR-count conventions (Phase 3 plan alone budgets ~370–540 PRs; master plan floor 1,000–1,300 total, of which roughly a third has landed).

### Wave 0 — Restore truth & foundation health (do first, ~1 week)
1. Land `fbb601591f` (restore Swift core validation) to `main`; confirm macOS build+tests green on `main`.
2. Burn down the 9 pre-existing red required checks on `main` (incl. "Windows dist verify" failing on clean main) — no more admin-merges.
3. Flip `pr-windows-full.yml` to a **required** check (WS-A2 — Alberto, branch protection).
4. Commit `PARITY_BURNDOWN_PLAN.md` (or rewrite the two dangling references) so WS-* lanes are defined in-repo.
5. Refresh `windows/README.md` ("no product code" line, "intentionally empty" sln line) and mark HANDOFF §2/§3/§6 superseded by the bundle.
6. ~~Purge committed build artifacts~~ **RESOLVED as misdiagnosis 2026-07-06** (see §2): tree verified clean at tip, ignore rules already complete; the remaining ask is the no-tracked-binaries tripwire (shipped separately), and no history rewrite (~4.7 MB of dead blobs is not worth `filter-repo` churn).
   **Exit:** `main` fully green; Windows CI blocking; docs match reality.

### Wave 1 — G2: Engine & data parity (the current gate)

> **Ground-truth revision 2026-07-06** (git audit): items 1 and 6 are further along than first assessed;
> item 2 is harder. The B1/B2/B6/C2 branches are **already integrated** on main (#1267 + #1272) — their
> refs are stale drafts, do-not-merge (see bundle §6).

1. **G2 headline — ✅ DONE (2026-07-06):** `OpenBurnBarG2ParserParity` byte-diffs **15 providers /
   26 fixtures** on x64 + ARM64 in `openburnbar-engine-windows.yml` (commits `85b898255f` →
   `67de06b5c7`, "15/15 byte-identical"; Codex + Hermes ride the SQLite reader seam). **PR #1270**
   fixed the pre-existing swift-crypto Sendable breakage and the lane ran **green** on it (run
   `28775204323`, both arches; merged to main as `cc56024f07`). The bundle's G2-headline row is
   flipped to proven.
2. **Storage architecture — ✅ DECIDED + EXECUTED (2026-07-06, option b):** Alberto deferred the call
   to the goal driver; **WPD-0005** (`decisions/0005-windows-storage-architecture.md`) formalizes the
   C# storage seam (`Microsoft.Data.Sqlite` + `e_sqlcipher`, drift D6, byte-compat proven
   `5c4fd006f8` / VAL-P0-DB-010) as the **permanent** Windows storage architecture: the Swift Engine
   on Windows is compute-only ("Engine computes, shell persists"). The boundary flag is documented
   architecture, `STORAGE_PRUNE_WAIVER.md` is deleted, R2 is retired-by-architecture, and the waiver
   gate is rewritten as `verify-windows-storage-architecture.sh` (fail-closed: flag-setting workflows
   must be named in WPD-0005's machine-read block + the C# storage tests must exist). Option (a),
   porting GRDB-SQLCipher to MSVC, was rejected — months of effort buying purity, not product.
3. Replace interim `swift run` engine binding with UniFFI bindgen (WPD-0001 / drift D7).
4. ~~Build the `windows/native/` FFI shim binding the already-built iroh + burnbar-remote crates.~~
   **DONE 2026-07-06:** `OpenBurnBar.Native{,.BurnBarRemote,.Iroh}` + `windows/tests/native` registered
   in the sln; iroh got its own committed uniffi-bindgen-cs binding
   (`crates/openburnbar-iroh/bindings/csharp/`) beside burnbar-remote's; both pinned to
   `uniffi-bindgen-cs v0.9.2+v0.28.3` and drift-gated
   (`scripts/windows-port/check-csharp-binding-drift.sh`, `.github/workflows/csharp-binding-drift.yml`).
   Real FFI loopback proven on macOS (25/25 with cargo-built dylibs; 12 pass + 13 skip without).
   Remaining slice: FFI-008 — run the same loopback on the msvc runtime by adding a cargo build step
   (or crate-artifact download) to a Windows lane.
5. ~~Complete quota **acquisition**~~ **BUILT + TESTED** (portable core): the `OpenBurnBar.App.Quota.Acquisition`
   project supplies every deferred adapter half behind portable seams (`IQuotaPayloadSource`,
   `IQuotaHttpTransport`, `IQuotaFileWatcher`, injectable `IQuotaAcquisitionClock`) — statusline snapshot
   file source + freshness gate, Cursor `state.vscdb` read (`Microsoft.Data.Sqlite`), Codex `wham/usage`
   HTTP, Anthropic rate-limit-header probe, the statusline `.cmd`/PS hook installer, and the
   `QuotaAcquisitionCoordinator` (fan-in → snapshots, Mac pacing constants, debounce/retry/error-tracking on
   the injectable clock). Proven by `windows/tests/quota-acquisition` (**57 tests green on macOS**, incl. the
   real `FileSystemWatcher` adapter contract). The `.Windows` sibling ships the real `FileSystemWatcher` +
   `%LOCALAPPDATA%/%APPDATA%` path defaults + the `WindowsQuotaAcquisitionHost` composition root. The
   `QuotaWorkspacePage` data path now **prefers the live coordinator** (`QuotaAccountsSource` →
   `QuotaLiveAccountMapper`) over B4 Firestore over `QuotaSampleData`, and `App.OnLaunched` configures the host.
   **Windows-runner-deferred (WS-D):** exercising the live `FileSystemWatcher` + real `%APPDATA%` paths on a
   Windows host, installing the hook against a real `~/.claude/settings.json`, and the WinUI XAML build of
   `QuotaWorkspacePage` (XamlCompiler is Windows-only — the C# data path is done and macOS-compiled).
6. ManagedAgentRuntime + CursorConnector ports. ~~ConPTY chat live (B1); land B6~~ — **on main already**;
   what remains is proving ConPTY + mission dispatch live on a real Windows host (WS-D pass).
   **Exit:** ~~#1270 landed + green engine run recorded (G2 headline); storage decision made and
   executed; waiver deleted (either path)~~ — **all three done 2026-07-06** (items 1–2 above);
   remaining: engine binding is production-shaped (item 3) + items 4–6.

### Wave 2 — Live cloud (unblocks most "Authored → Real")
1. **R14 kill-risk:** Windows CNG `NCryptCreateClaim` TPM client → real-TPM App Check mint → enforced callable, on Win11 Pro hardware.
2. Firebase auth on Windows: ID token/OAuth flows (replace "paste a dev-host token" in `DataSourceSettingsPage`), account sign-in.
3. Live Firestore transport behind the REST gateway; snapshot listeners against real backend.
4. ~~Implement the **8 `NotImplementedException` callables** in `CloudSyncCallableHub` (export, delete, recovery ×3, revoke, audit ×2).~~ **DONE 2026-07-06 (implemented + tested; live transport still WS-D):** all 8 wired to the deployed wire contract with 32 transport-seam tests (`CloudSyncCallableHubTests.cs`). Remaining for this item: the live authenticated round-trip + the high-risk-owner-action envelope (nonce / trustedDeviceId / actionProof) on export + revoke, which depend on item 1 (Signal-identity + TPM).
5. **C5 closure:** live Windows-seal → Mac-open E2EE round-trip (retire the deferral doc); device registry/trusted-device chain live.
   **Exit:** a Windows machine appears as a real trusted device syncing real data with the Mac; C5 + R14 retired.

### Wave 3 — G3: UI real-data conversion + visual parity
1. Convert the 9 "Authored" surfaces to "Real" (dashboard, quota, chat, mission control, budget, DCC, insights, ElderWand, switcher) — wire each to the live seams from Waves 1–2; replace `QuotaSampleData`, `SwitcherSampleData`, `MissionDispatchDemoHost`, command-palette stub search.
2. Settings parity: replace `SettingsPlaceholderPage` tabs until all applicable macOS tabs (per Tier-C substitution list) exist; make settings search honest.
3. Win2D GPU particle rendering + the **mandatory 60fps ARM64 sub-spike (WINUI-017)**; retire the dev-host frame generator.
4. Pretext WebView2 metric parity vs Mac golden within tolerance (D12); design-system completion (Mica/Acrylic per D1).
5. Pet overlay live on Windows (WebView2 glTF host, vendoring automated); budget toasts; global hotkey proven.
   **Exit:** G3 per `PHASE3_UI_PARITY_PLAN.md`; zero sample-data surfaces; bundle surface matrix reads 13/13 **Real**.

### Wave 4 — G4: System integration
1. Computer-use full loop on Windows: SendInput/UIA/Graphics.Capture/named-pipe + ViGEm, kill-switch + audit chain verified end-to-end.
2. Integrations live: Cast device session, Home Assistant against a real instance, SmartHub bridge, Mercury live capture/transfer between Windows↔Mac.
3. ~~Decide~~ **DECIDED 2026-07-06 (WPD-0006)** and execute the **daemon strategy** (gap #10): **per-capability
   Tier-C substitution — no monolithic `OpenBurnBarDaemon` port for v1.** The WinUI app process + portable C# cores
   absorb daemon duties (9 capabilities already substituted; deferrals recorded as bundle drift D14). What remains
   *executable* here is already Wave 4 item 1 scope (computer-use full loop: ViGEm + watchdog process) plus the two
   Wave 3 item 1 rows (switcher shell, indexed/palette search). Revisit triggers (headless/multi-client Windows,
   WS-D isolation, gateway demand) revive the shared Swift daemon via the Linux boundary build as a Windows Service.
   See the 34-row matrix in `docs/windows-port/decisions/0006-windows-daemon-strategy.md`.
   **Exit:** G4; every live adapter demonstrated on real Windows hardware with evidence in the bundle.

### Wave 5 — G5: Ship
1. **Alberto (blocking):** obtain Authenticode cert (W0); Store/winget publisher accounts.
2. Signed MSIX build in `openburnbar-release-windows.yml`; real artifact hashes; portable zip; choco/winget manifests submitted.
3. Live WinSparkle update round-trip recorded; downgrade-block proven.
4. **Win11 Pro validation pass (Alberto):** replace every PLACEHOLDER screenshot/recording in bundle §5 with real evidence.
5. Certify G5; freeze the bundle version.
   **Exit:** a signed, installable, auto-updating OpenBurnBar for Windows with a complete evidence bundle. That is 100%.

### Alberto-owned blockers (nothing else can close these)
| Item | Blocks |
|---|---|
| Authenticode cert (W0) | Wave 5 entirely |
| Win11 Pro hardware validation pass | R14 TPM proof (Wave 2), all §5 evidence (Wave 5) |
| Branch-protection flip for `pr-windows-full` (WS-A2) | Wave 0 §3 |
| Store/winget publisher accounts | Wave 5 §2 |
| ~~Daemon strategy decision (port vs. substitute)~~ **RESOLVED 2026-07-06** — Alberto deferred to the goal driver; WPD-0006 chose per-capability substitution | ~~Wave 4 §3 scope~~ closed |

### Rough sizing
Wave 0: ~5–10 PRs. Wave 1: ~60–100. Wave 2: ~40–70. Wave 3: ~200–350 (dominated by the Phase-3 plan). Wave 4: ~80–150 (daemon decision made — WPD-0006 substitution; the "+100–200 if ported" contingency is **retired**, daemon-attributed work folds into existing Wave 3/4 items). Wave 5: ~15–30. **Total remaining: roughly 400–700 PRs**, consistent with the master plan's 1,000–1,300 floor minus what's landed.

---

## 5. Standing rules while remediating
- Key all status claims off `PARITY_CERTIFICATION_BUNDLE.md` labels (Real / Authored / deferred), never off "done" phrasing in handoffs.
- No admin-merges into the parity lane once Wave 0 completes.
- Every deferral gets a doc with an expiry (the storage waiver pattern; that waiver itself was retired 2026-07-06 when WPD-0005 turned the gap into a decision) — and gets deleted when closed.
- "Parity" claims require Windows-runner or real-hardware evidence; macOS-host test parity is labeled as such.
