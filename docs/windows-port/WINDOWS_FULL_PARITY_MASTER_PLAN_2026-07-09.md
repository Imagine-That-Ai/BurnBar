# Windows Full Parity Master Plan

Date: 2026-07-09
Branch at scan: `windows/liquid-glass-kernel-reskin`
Scope: Windows port parity with the shipping macOS OpenBurnBar product.
Status: Consolidated plan after CMUX pane review, live ledger verification, code checks, and adversarial loophole loop.

## 0. Source of Truth and Scope

The status source of truth remains `docs/windows-port/WINDOWS_PARITY_LEDGER.yml`.
This file is the execution plan. It consolidates the current scan and strategy
documents without replacing the ledger or the accepted Windows platform
decisions.

Inputs used:

- `docs/windows-port/WINDOWS_PARITY_SCAN_AND_PLAN.md` - first broad scan and phased plan.
- `docs/windows-port/WINDOWS_FULL_PARITY_SCAN_2026-07-09.md` - expanded inventory and loophole fixes.
- `docs/windows-port/WINDOWS_PARITY_STRATEGY_V2.md` - adversarially hardened ordering.
- `docs/windows-port/decisions/0003-defer-project-code-static-parser-windows.md` - Projects depth boundary.
- `docs/windows-port/decisions/0006-windows-daemon-strategy.md` - daemon capability boundary.
- `docs/windows-port/decisions/0007-windows-app-backend.md` - in-process Windows app backend.
- `docs/windows-port/TONIGHT_PUNCHLIST.md` and `ALBERTO_PARITY_CHECKLIST.md` - human-gated hardware/account work.

### Achieved finish line (2026-07-09, post-remediation)

| Fact | Value | Verification |
|---|---:|---|
| Ledger rows | **46** | `bash scripts/ci/verify-windows-parity-ledger.sh` |
| `Real` rows | **46** | ledger script |
| `Substituted` rows | **0** | ledger script |
| `DeferredApproved` rows | **0** | ledger script |
| `Blocked` rows | **0** | ledger script |
| Finish line | **F2_True_1to1** | `WINDOWS_PARITY_LEDGER.yml` |
| 100% parity (ledger laws) | **YES** | never bare “100%” — always **F2 True 1:1** |

Operational residuals (not ledger failures): Authenticode private key, branch-protection
required-check flip for `pr-windows-full`, physical TPM claim on hardware.

### Historical scan baseline (plan authoring, pre-remediation)

| Fact | Value at plan write | Verification |
|---|---:|---|
| Ledger rows | 33 | then-current ledger script |
| `Real` rows | 5 | then-current |
| `Substituted` rows | 16 | then-current |
| `DeferredApproved` rows | 3 | then-current |
| `Blocked` rows | 9 | then-current |
| Missing macOS primary routes | `database`, `projects` | later closed Real (IA-2/IA-4) |
| Chat production default | `UnavailableChatStreamDriver` | later closed Real (CLI stream-json) |
| Insights silent sample risk | present | later closed (H0 honesty) |

The five foundation rows that were Real at plan write (not product-surface parity yet):

- `engine-parsers-g2`
- `storage-sqlcipher-byte-compat`
- `cloudvault-crypto-kat`
- `pal-ipc-named-pipe`
- `quota-portable-parsers`

The nine current `Blocked` rows are:

- `nav-chat`
- `nav-database`
- `nav-projects`
- `appcheck-tpm`
- `firebase-oauth-windows`
- `particles-gpu-60fps`
- `computer-use-loop`
- `dist-msix-signed`
- `ci-windows-full-gate`

## 1. Definitions: F1 vs F2

No strategy can be factually sound until "full parity" is split into two
finish lines.

### F1 - Ship Peer

F1 is the default launch target. It means Windows is a real local OpenBurnBar
desktop peer under accepted Windows Platform Decisions.

F1 includes:

- real log ingest, quota, budget, storage, session logs, dashboard, insights, memory, DCC, onboarding, switcher, tray/flyout, and settings surfaces;
- chat via real in-app Windows backends, not `UnavailableChatStreamDriver`;
- cloud sign-in, Firestore, App Check, CloudVault live round-trip, and trusted-device behavior;
- Computer Use desktop loop with Windows-native input/capture/audit/kill-switch path;
- pet, Mercury/media, and key integrations at least live-once on Windows;
- signed MSIX distribution, update round-trip, winget/Store-ready metadata, and a complete evidence bundle;
- explicit user-visible disclosure for WPD-approved deferred features.

F1 excludes only accepted Windows scope boundaries:

- WPD-0006 deferred daemon capabilities unless a revisit trigger fires;
- WPD-0003 full project-code static parser depth unless revived;
- platform-impossible Apple-only details with named Windows substitutes.

### F2 - True 1:1

F2 means Windows reaches Mac feature completeness, including everything F1
excludes:

- local HTTP gateway and Model Proxy as live Windows capabilities;
- provider-specific executors and proactive local-provider discovery;
- headless run service, local Mission Control DAG execution, planner, and policy engine;
- Pensieve watcher and full project-code static parser;
- browser Computer Use/Playwright path;
- Elder Wand fusion orchestration;
- connector plane, companion CLI, and any daemon-client surfaces users treat as core.

Rule: do not write "100% parity" without saying F1 or F2. The practical launch
target is F1. The literal full parity endpoint is F2.

## 2. Non-Negotiable Parity Laws

1. The ledger decides status. A route resolving, page compiling, or feature
   being authored is not parity.
2. `Real` requires production default code paths, evidence files, and tests. No
   `SampleData`, `DemoHost`, `Stub`, `SettingsPlaceholderPage`, or
   `Unavailable*` defaults on a `Real` row.
3. `DeferredApproved` requires a decision document and a revive trigger.
4. `Substituted` is honest only when the substitute works end to end and the
   UI says what differs from Mac.
5. Windows-host evidence is mandatory for XAML render, WinUI packaging,
   TPM/vTPM, GPU, E2EE live round-trip, Computer Use, FFI MSVC, and screenshots.
6. No composite percentage is allowed in PRs unless it names the denominator.
   Prefer counts: rows by status, sample call-site count, placeholder count,
   host-gated proof count.
7. Theme/chrome work must not gate data/product parity. The liquid-glass branch
   can improve feel, but F1 is won by production paths and evidence.

## 3. Dependency DAG

```text
H0 Honesty and Metrics
  -> H1 Human Gates
      -> H2 Windows Host Foundation
          -> H3 Chat F1
          -> H4 Cloud/Auth Real
              -> H5 Information Architecture: Database + Projects
              -> H6 Settings Placeholder Death
                  -> H7 Surface Real Conversion
                      -> H8 System Integrations
                          -> H9 F1 Ship
                              -> H10 F2 True 1:1
```

Illegal transitions:

- Do not claim Insights or Dashboard `Real` before H0 removes silent samples.
- Do not claim Chat `Real` because ConPTY exists; Chat needs an
  `IChatStreamDriver` production default.
- Do not claim Account/Cloud/Devices settings `Real` before OAuth and App Check.
- Do not claim Model Proxy `Real` under F1 unless it is an honest deferred page;
  live Model Proxy is F2 unless WPD-0006 row 1 is revived.
- Do not claim Mission Control local execution `Real` when Windows is only a
  dispatch client.
- Do not claim G5 without signed distribution and update proof.

## 4. Phase H0 - Honesty and Metrics

Time: 1-3 days.
Blocked by Alberto: no.
Primary goal: eliminate false-green paths before feature work accelerates.

Tasks:

1. Gate `CloudSyncInsightSource` sample fallback behind
   `RuntimeDataMode.SampleModeEnabled`; return honest empty/no-data widgets in
   production mode.
2. Audit every `InsightSampleData.ForKind`, `*SampleData`, `DemoHost`,
   `Scripted*Driver`, `StubCliStream`, and `Unavailable*` production call site.
3. Rename helper types whose behavior is honest empty state but whose name says
   `Sample`, starting with session-log empty sources if applicable.
4. Add tests that fail if production mode constructs non-KPI
   `InsightSampleData`.
5. Expand or annotate the ledger so every macOS-facing F1 surface has a row or
   a documented `DeferredApproved` boundary. The current 33-row ledger is
   internally honest but incomplete for full product management.
6. Add the F1/F2 scope table to the certification bundle and the Windows Engine
   Room or equivalent settings surface.

Exit criteria:

- `bash scripts/ci/verify-windows-parity-ledger.sh` passes.
- `InsightSampleData` is impossible on production paths unless sample mode is
  explicitly on.
- Every open parity PR uses row counts and named blockers instead of vague
  percent-complete language.
- No new docs call WPD-0006 deferred capabilities "done".

Validation:

- `bash scripts/ci/verify-windows-parity-ledger.sh`
- targeted C# tests for Insights production/no-data behavior
- grep/audit report for remaining sample/demo/stub/unavailable paths

## 5. Phase H1 - Human Gates

Time: calendar-bound, start immediately.
Blocked by Alberto: yes.
Primary goal: start all lead-time items before agents fan out on work that
cannot be verified.

Required inputs:

| Gate | Owner | Blocks |
|---|---|---|
| Win11 Pro ARM64 VM with SSH | Alberto | XAML compile/render, vTPM, GPU, Computer Use, C5, FFI MSVC, screenshots |
| Google Desktop OAuth client and Firebase Web API key | Alberto | real sign-in, Firestore, Account/Cloud/Devices settings, DCC, Memory |
| Azure Trusted Signing/AuthentiCode cert | Alberto | signed MSIX, update, G5 |
| Microsoft Partner Center/Store account | Alberto | Store/winget release path |
| `PR Windows Full Gate` required on `main` | Alberto/admin | trustworthy Windows CI gating |
| production env `v*` tag rule / factory key / App Check gcloud account | Alberto/admin | production release and factory lanes |
| F1 vs F2 decision | Alberto or goal-driver | gateway/Model Proxy/local execution workstream shape |

Exit criteria:

- VM reachable over SSH and `scripts/windows-port/vm-validate.ps1` can start.
- Desktop OAuth credentials exist in the expected secret/config path.
- Trusted Signing process is active or certificate is available.
- Required check is configured or a named admin blocker is recorded.
- F1 is the written default, or F2 has an explicit gateway/daemon workstream.

## 6. Phase H2 - Windows Host Foundation

Time: 1-2 weeks after VM access.
Blocked by Alberto: VM and credentials.
Primary goal: turn portable promises into Windows-host evidence.

Host proofs:

1. Full WinUI solution build and test on Windows.
2. XamlCompiler/MakePri proof for every existing WinUI page.
3. R14-A App Check: vTPM `NCryptCreateClaim` mint, backend token exchange, and
   enforced callable clearing Firebase Admin.
4. R14-B policy residual: physical TPM or Firebase acceptance caveat if vTPM is
   insufficient for production certification.
5. Real Desktop OAuth loopback with production client credentials.
6. ConPTY interactive CLI proof on Windows.
7. CloudVault live Windows-seal to Mac-open round-trip.
8. Rust/MSVC native FFI build and loopback tests.
9. Win2D/ARM64 60fps particle substrate spike.
10. Computer Use adapter smoke: SendInput, UIA, Windows Graphics Capture,
    kill-switch/watchdog path.

Exit criteria:

- Host evidence is committed under `docs/windows-port/evidence/` or linked from
  the certification bundle.
- Host-gated ledger rows either move to `Real` with evidence or stay `Blocked`
  with the exact failing proof.
- No plan item depends on "should work on Windows" without a runbook result.

Validation:

- `scripts/windows-port/vm-validate.ps1`
- `dotnet build OpenBurnBar.sln` on the VM
- `dotnet test` on the VM
- targeted TPM/OAuth/C5/FFI/Win2D/CU proof scripts

## 7. Phase H3 - Chat F1

Time: 1-3 weeks after H2 ConPTY proof.
Blocked by Alberto: VM for final proof, not for all authoring.
Primary goal: make Windows Chat useful and non-fake without requiring the full
daemon gateway.

Current facts:

- `ChatSurfaceViewModel` defaults to `UnavailableChatStreamDriver` when
  `RuntimeDataMode.SampleModeEnabled` is false.
- `ScriptedChatStreamDriver` is opt-in sample mode.
- `CliStreamFactory` and `ConPtyCliStream` currently feed CLI stream plumbing,
  not the Hermes atom chat surface.

Tasks:

1. Implement a production `IChatStreamDriver` adapter for at least one CLI
   backend using stream-json output.
2. Map backend events into `ChatStreamEvent.Text`, `ToolUse`, `ToolResult`,
   `Usage`, and failure states.
3. Add a Windows backend registry/picker for the F1-supported subset.
4. Wire the Chat composition root: configured CLI -> live driver;
   unconfigured host -> actionable unavailable state; sample mode -> scripted
   demo.
5. Add persistence/search/attachment parity slices only after streaming is
   real.
6. Add Pretext/WebView2 metric tolerance tests for chat layout.

Exit criteria:

- `nav-chat` is no longer `Blocked` only when a configured Windows host sends a
  real assistant stream through `ChatSurfaceViewModel`.
- ConPTY-only proof does not change ledger status by itself.
- Hermes/Pi gateway-backed chat is either an F2 workstream or explicitly
  deferred under WPD-0006.

## 8. Phase H4 - Cloud and Auth Real

Time: 3-5 weeks after OAuth/App Check credentials.
Blocked by Alberto: OAuth, Firebase API key, VM/vTPM.
Primary goal: make Windows a real trusted device in the cloud graph.

Tasks:

1. Replace paste-token/dev-token flows with `DesktopOAuthLoopbackFlow`.
2. Prove ID token refresh and Firestore snapshot listeners against production.
3. Wire App Check token acquisition into every protected callable path.
4. Implement DCC high-risk action envelopes: nonce, trusted device ID,
   action proof, and replay protection for export/revoke.
5. Wire Memory, DCC, Mission dispatch, Switcher cloud, Account, Cloud, and
   Devices settings to real authenticated stores.
6. Close C5 with live Windows-to-Mac CloudVault E2EE.
7. Add Remote Config polling parity for kill switches and feature flags.

Exit criteria:

- A Windows install signs in as a real user, syncs real data, and appears as a
  trusted device.
- Cloud-backed rows are not `Real` until App Check, OAuth, and live Firestore
  all pass.

## 9. Phase H5 - Database and Projects Information Architecture

Time: 2-5 weeks, sliced.
Blocked by Alberto: host proof for final render, not for route authoring.
Primary goal: close the two missing macOS primary routes without pretending the
deep Mac work is a one-PR port.

Slices:

| Slice | Deliverable | Parity level |
|---|---|---|
| IA-1 | Add `database` and `projects` keys to `NavCatalog`, `SurfacePageResolver`, command palette, and shortcuts | route parity |
| IA-2 | Database System mode over the existing SQLCipher seam | functional first slice |
| IA-3 | Database Story/Atlas modes | visual/product depth |
| IA-4 | Projects list/detail from usage DB and folder paths | list-level peer |
| IA-5 | Projects memory and static parse depth | requires WPD-0003 revive or lexical-only disclosure |

Exit criteria:

- `nav-database` and `nav-projects` leave `Blocked`.
- The UI clearly labels any lexical-only or deferred project-code depth.
- Mac primary route parity is true at the level claimed by the ledger row.

## 10. Phase H6 - Settings Placeholder Death

Time: 4-8 weeks, parallelizable after H0/H2.
Blocked by Alberto: VM for compile/render verification.
Primary goal: eliminate the most visible "still not ported" surface.

Current facts:

- Windows defines 16 `SettingsTab` values.
- `PageTypeForTab` routes only `General`, `Updates`, and `DataPrivacy` to real
  tab pages.
- `Appearance` is a real route-level page through `PageTypeForRoute`, not a tab
  default.
- The portable view-model catalog has 11 real view-model descriptors: 8 live,
  3 data-gated.

Settings tiers:

| Tier | Tabs/routes | Requirement |
|---|---|---|
| S0 | General, Updates, DataPrivacy, Appearance route | keep real and production-honest |
| S1 | Daemon, Alerts, Notifications, TextExpansion, Pets, ComputerUse policy | real XAML + portable VM, no deferred server dependency |
| S2 | Account, Cloud, DevicesAndSync | only after OAuth/App Check |
| S3a | Agents, Cursor connector subset | live without local gateway |
| S3b | ModelProxy | F1 deferred-disclosure page or F2 live gateway |
| S4 | Media | after Mercury live adapters |
| S5 | Settings Copilot / full provider-plan wizard | F1 optional, F2 polish |

Tasks:

1. Add one WinUI page per S1/S2/S3a/S4 tab in dependency order.
2. Replace `SettingsPlaceholderPage` default fallthrough with an explicit route
   map.
3. Make settings search honest: no indexed item without a real reachable target,
   unless the target is a deliberate deferred-disclosure page.
4. Add render smoke tests on the VM for every tab and high-value leaf route.

Exit criteria:

- No S0-S2 tab opens `SettingsPlaceholderPage`.
- S3b never implies a live local gateway under F1.
- All settings search items resolve to a real UI target or explicit deferred
  target.

## 11. Phase H7 - Surface Real Conversion

Time: 6-12 weeks.
Blocked by Alberto: H2/H4 for cloud and host proof.
Primary goal: burn down `Substituted` rows into production `Real` rows.

Surface conversion order:

1. Dashboard and flyout: production usage summary, provider/model drill-down,
   no default sample composition.
2. Quota: live Windows path discovery, watcher, hook installer, and cloud
   snapshot sync.
3. Insights: after H0, real rollups/no-data states for every widget kind.
4. Session Logs: configured SQLCipher source, search, reopen, and no misleading
   sample naming.
5. Memory: live CloudSync/local store, review inbox, consent, and empty states.
6. Mission Control: dispatch console only for F1; local execution stays F2.
7. Budget: live cloud budget rules and Windows toast proof.
8. DCC: live authenticated calls and high-risk envelope after H4.
9. Switcher: encrypted profile store and production empty states.
10. Onboarding: first-run proof on Windows with real prerequisites.
11. Elder Wand: F1 presets/judge config/persistence; fusion orchestration is F2.
12. Tray/flyout: real daemon/app health and quota metrics, not sample cards.

Exit criteria:

- No F1 nav row uses production-default sample/demo/unavailable paths.
- Every promoted row has evidence and tests.
- Any F2-only behavior is visible as deferred, not silently absent.

## 12. Phase H8 - System Integrations

Time: 6-12 weeks, overlaps H7 after H2/H4.
Blocked by Alberto: VM and device/account availability for live proof.
Primary goal: make the OS and ecosystem integrations real on Windows.

Workstreams:

1. Computer Use: SendInput, UIA, Windows Graphics Capture, ViGEm where needed,
   audit chain, approval UI, panic kill, watchdog process, and evidence
   recordings.
2. Mercury media: screen share, calls, file transfer, RFB, camera/mic capture,
   Media Foundation encoding, and permission UI.
3. Cast, SmartHub, Home Assistant: mDNS/DNS-SD or Windows PAL, pairing/setup
   wizards, live device actions, and recovery states.
4. Text Expansion: global keyboard hook, snippet runtime, `SendInput`, sync, and
   safety constraints.
5. CursorConnector/runtime: Windows proxy process, TCP/secret seams, routed
   config sync, and workspace trust behavior.
6. Pet companion: live overlay, WebView2 glTF host, vendoring, persistence, and
   summon behavior.
7. DailyDigest, notifications, launch-at-login, global hotkey, single-instance,
   conversation import/export, and Agent Watch HUD.

Exit criteria:

- Every integration has at least one live Windows proof with evidence.
- Hardware/account-limited integrations have named blockers, not green rows.
- No integration page displays controls for unsupported backends without an
  explicit capability-absent state.

## 13. Phase H9 - F1 Ship

Time: 2-4 weeks after H2-H8 evidence.
Blocked by Alberto: cert, Partner Center, release/admin gates.
Primary goal: ship a signed, installable, updating Windows F1 peer.

Tasks:

1. Build signed MSIX and portable zip in CI.
2. Generate hashes, SBOM, VEX, provenance, and signatures.
3. Prove WinSparkle or selected updater round-trip with Ed25519-pinned feed.
4. Prepare winget and Store metadata.
5. Replace all placeholder certification screenshots with real Win11 evidence.
6. Make `pr-windows-full` required and keep it green.
7. Run factory PR loop only on coherent lanes with evidence.

F1 done when:

- All F1-in-scope ledger rows are `Real` or `DeferredApproved` with accepted
  WPD revive triggers.
- `nav-chat`, `nav-database`, and `nav-projects` are no longer `Blocked`.
- Production mode has zero silent sample/default unavailable paths.
- Settings S0-S2 are real; S3b is honest under F1.
- OAuth, App Check R14-A, C5, FFI MSVC, GPU, CU loop, and cloud sync are proven
  on Windows or carry named residual blockers.
- Signed install and update proof exist.
- The certification bundle matches the actual evidence.

## 14. Phase H10 - F2 True 1:1

Time: explicit post-F1 program unless Alberto chooses F2 as the launch target.
Blocked by Alberto/product: F1/F2 decision and resource allocation.
Primary goal: remove every WPD-0006/WPD-0003 deferred Mac-peer gap.

F2 workstreams:

1. Local HTTP gateway as a Windows Service or in-process substitute with a real
   multi-client story.
2. Model catalog, health, route logging, cross-vendor degrade, and gateway
   metrics.
3. Codex/Factory CLI executors and proactive local-model discovery are closed by
   `docs/windows-port/evidence/f2/provider-cli-executors.md` and
   `docs/windows-port/evidence/f2/proactive-local-model-discovery.md`. The production
   authenticated gateway, provider-router scorecard, quota-drain core,
   failure-driven model health, opt-in cross-vendor degrade policy, and durable
   route/stream usage telemetry are closed, and OpenAI-compatible, Anthropic,
   and Ollama-native HTTP transports are closed by
   `docs/windows-port/evidence/f2/provider-router-scorecard.md` and
   `docs/windows-port/evidence/f2/gateway-model-health.md` and
   `docs/windows-port/evidence/f2/cross-vendor-degrade-policy.md` and
   `docs/windows-port/evidence/f2/gateway-route-telemetry.md` and
   `docs/windows-port/evidence/f2/ollama-native-provider-transport.md` and
   `docs/windows-port/evidence/f2/provider-cli-executors.md` and
   `docs/windows-port/evidence/f2/proactive-local-model-discovery.md`.
4. Headless run service, resume/recovery, protected checkpoints,
   metadata-only journal, approval, and companion tool dispatch are closed by
   `docs/windows-port/evidence/f2/headless-run-recovery.md`; Windows-host
   compile and lifecycle stress remain release evidence, not implementation.
5. Local Mission Control execution: DAG scheduler, journal repository,
   projection reducer, planner, and policy engine. Gateway token-bucket limiting
   is closed by `docs/windows-port/evidence/f2/gateway-rate-limiter.md`.
6. Pensieve knowledge watcher. The live repo-docs/notes/session-end watcher and
   sealed queue are closed by
   `docs/windows-port/evidence/f2/pensieve-knowledge-watcher.md`. The separate
   project-code memory store, embeddings, and full static parser are closed by
   `docs/windows-port/evidence/f2/project-code-memory-store.md`,
   `docs/windows-port/evidence/f2/live-lsp-parser-client.md`, and WPD-0003's
   revival addendum.
7. Browser Computer Use/Playwright lifecycle and browser target policy.
8. Elder Wand fusion orchestrator and tool loop.
9. Connector plane and any revived connector-specific broker/client surface.
   The standalone authenticated companion CLI and daemon-client core are closed
   by `docs/windows-port/evidence/f2/companion-cli-client.md`.

F2 done when:

- F1 is complete.
- All WPD-0006 `DEFER` rows are either implemented and evidenced on Windows or
  reclassified by a new accepted product decision.
- All F2 user-facing copy and settings surfaces are live, not disclosure pages.

## 15. Validation Matrix

Use targeted checks during normal PR work and host checks when a phase crosses
OS boundaries.

| Area | Local macOS check | Windows host check |
|---|---|---|
| Ledger/status | `bash scripts/ci/verify-windows-parity-ledger.sh` | same |
| C# portable tests | targeted `dotnet test` project | full `dotnet test` |
| WinUI pages | view-model/unit tests only | XamlCompiler, render smoke, screenshot |
| Chat | stream parser unit tests | real CLI stream through `ChatSurfaceViewModel` |
| Cloud/Auth | fake-server tests | real OAuth/App Check/Firestore |
| SQLCipher | portable seam tests | open Mac-produced DB and write/read rows |
| FFI | macOS loopback where applicable | MSVC build and loopback |
| GPU/particles | math/unit tests | 60fps ARM64 measurement |
| Computer Use | core policy/audit tests | SendInput/UIA/WGC/kill-switch loop |
| Distribution | packaging script dry run | signed install/update proof |

PR rule:

- Fast lane for narrow honesty, tests, ledger, docs, and leaf-page PRs.
- Structured large lane for atomic cross-cutting Chat, Cloud/Auth, CU, or
  distribution work.
- Draft spike for unknown host/hardware work until evidence exists.
- Reject lane for mixed goal, red-check, vague parity claims.

## 16. Adversarial Confidence Loop

The instruction was: "Are you 100% confident in this strategy? If not, find all
possible loopholes, suggest proper fixes and run this loop until you are
factually 100% confident in the new strategy."

The only defensible interpretation is factual confidence in the strategy's
current claims and ordering, not omniscience about future third-party behavior,
calendar, or unknown Mac features. The loop below is complete when every
material contradiction is either fixed in the strategy or moved to the residual
uncertainty register.

| Pass | Loophole found | Fix in this plan | Confidence state |
|---|---|---|---|
| 1 | "Full parity" hid WPD-0006 daemon deferrals | F1/F2 split; F2 owns deferred daemon work | closed |
| 2 | Chat `Real` was conflated with ConPTY | H3 requires production `IChatStreamDriver` into chat surface | closed |
| 3 | Settings "just bind VMs" ignored WinUI/XamlCompiler gate | H6 separates authoring from Windows render proof | closed |
| 4 | Settings count drift: 12 vs 13 placeholders | use factual code wording: 13 tab defaults placeholder; Appearance is route-level | closed |
| 5 | Model Proxy page can lie under F1 | S3b must be deferred-disclosure or F2 gateway | closed |
| 6 | Insights can silently fabricate samples | H0 sample gate before any `Real` claim | closed |
| 7 | Database/Projects were treated as simple route additions | H5 slices IA-1 through IA-5; WPD-0003 caveat | closed |
| 8 | Mission dispatch was conflated with local execution | H7 says dispatch is F1; local execution is F2 | closed |
| 9 | vTPM proof was treated as production App Check certainty | H2 splits R14-A from R14-B residual | closed |
| 10 | Percent-complete claims used unstable denominators | parity laws ban composite percent without denominator | closed |
| 11 | Branch/theme work could block product parity | U4 residual and law: theme does not gate data/product Real | closed |
| 12 | Elder Wand surface could imply fusion orchestration | F1 presets/config only; F2 fusion | closed |
| 13 | Session-log "SampleData" naming could create false scanner noise | H0 rename honest empty helpers | closed |
| 14 | Current `Real` rows were trusted without evidence shape | ledger script and evidence file list verified | closed |
| 15 | Unknown Mac-only features may still be untracked | U8 periodic inventory process | residual, named |

Stop condition reached: the strategy is factually confidence-complete for the
current checkout because every verified loophole has a concrete fix, phase, and
gate. The remaining uncertainty is not hidden; it is listed below.

## 17. Residual Uncertainty Register

| ID | Residual uncertainty | Closure path | Current rule |
|---|---|---|---|
| U1 | Firebase/App Check production acceptance of vTPM | R14-B physical/policy proof | keep production cloud certification blocked |
| U2 | WebView2 Pretext metric drift magnitude | corpus tolerance tests on Windows | do not claim exact layout parity |
| U3 | Win2D 60fps on target ARM GPU | H2.9 measurement | degrade visual fidelity honestly if needed |
| U4 | merge cost from `windows/liquid-glass-kernel-reskin` to current `main` | rebase early and isolate theme work | theme cannot block data Real |
| U5 | whether Alberto wants F2 in year-one launch | written F1/F2 decision | default F1 |
| U6 | DCC high-risk action envelope complexity | H4 spike after OAuth/App Check | keep export/revoke partial until proven |
| U7 | ViGEm/driver friction for Computer Use | H8 host pass | ship lower-privilege CU subset only if labeled |
| U8 | Mac-only features not yet represented in ledger | periodic `AgentLens/Views` and service inventory | add rows, do not absorb silently |

## 18. First 48 Hours

1. Create H0 honesty PR:
   - gate `CloudSyncInsightSource` and `InsightsBuiltInTemplates` sample paths;
   - add production no-sample tests;
   - audit sample/demo/stub/unavailable defaults;
   - update ledger docs with F1/F2 language.
2. Start H1 in parallel:
   - Win11 VM SSH;
   - Azure Trusted Signing;
   - Google Desktop OAuth/Firebase Web API key;
   - branch protection for `PR Windows Full Gate`;
   - written F1 default unless explicitly overridden.
3. Draft H3 Chat mapping table from Mac CLIBridge events to Windows
   `ChatStreamEvent`.
4. Prepare H2 VM validation runbook output directories before the VM is ready.
5. Do not start a broad Database/Projects megaport before H0/H3; IA-1 route
   scaffolding is fine.

## 19. Current Worktree Boundary

This plan was added as a new documentation file. It intentionally does not edit
the other generated parity reports or the unrelated Linux desktop work visible
in the current dirty worktree. Future implementation lanes should keep Windows
F1/F2 work separate from Linux desktop styling and packaging changes.
