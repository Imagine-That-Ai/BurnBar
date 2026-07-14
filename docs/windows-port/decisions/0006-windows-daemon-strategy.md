# WPD-0006: Windows daemon strategy — per-capability Tier-C substitution, no monolithic daemon port for v1

- **Status:** Accepted (decision authority: Alberto deferred to the goal driver;
  recorded 2026-07-06)
- **Date:** 2026-07-06
- **Closes:** `docs/windows-port/PARITY_100_REMEDIATION_PLAN.md` Wave 4 item 3
  ("daemon strategy decision") and gap-register row #10 — the last unscoped
  parity item.
- **Scope:** What happens to every `OpenBurnBarDaemon/` capability (~54K LOC per
  the remediation-plan baseline; 31,984 LOC in the top-level daemon target
  alone) on Windows v1. This WPD is the per-capability disposition matrix the
  remediation plan asked for ("formally Tier-C-substitute per capability in the
  bundle").
- **Consistent with:** WPD-0007 (in-process Swift Engine + net8.0 facades, **no
  Windows service** for the data lanes) — 0006 extends that call from the
  data-wiring lanes to the entire daemon capability set. Also consistent with
  master plan §15.1 (named deferrals with criteria, no runtime trapdoors).
  WPD-0009 is the later authority for F2 promotions; promoted rows are amended
  here so the product-visible Engine Room does not report stale deferrals.

## Context

### What the daemon actually is on macOS

`OpenBurnBarDaemon/` is not one capability — it is a bundle of ~15 loosely
coupled services behind one LaunchAgent process plus six auxiliary executables
(`OpenBurnBarDaemon/Package.swift` products: daemon, CLI, remote-access agent,
virtual-HID bridge, privileged-input execution, red-team probe, kill-switch
watchdog). The macOS *app* talks to it over a Unix-socket JSON-RPC client
(`AgentLens/Services/OpenBurnBarDaemon/OpenBurnBarDaemonSocketClient.swift`,
lifecycle in `OpenBurnBarDaemonManager+Lifecycle.swift`), but most app surfaces
do not require the daemon to be running — the daemon exists for the local HTTP
gateway, headless agent runs, Mission Control execution, and the privileged
computer-use path.

### The Linux precedent (what a Swift daemon reuse would actually get)

`OpenBurnBarDaemon/Package.swift` already carries an off-macOS story: the
`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD=1` boundary build plus an
`#if os(Linux)` exclude list (`Package.swift` lines 37–62). The excludes tell
us exactly which daemon capabilities are **macOS-coupled even by the daemon's
own reckoning**:

- Excluded off-macOS (would need real porting): the entire HTTP gateway stack
  (`OpenBurnBarHTTPGatewayServer*.swift`, `Gateway*.swift`),
  `PensieveKnowledgeWatcher.swift`, `DaemonSelfCodeSignatureVerifier.swift`,
  `ElderWandFusionOrchestrator.swift`, `OpenBurnBarSwitcherShell.swift`,
  `PTYInteractiveSession.swift`, `BurnBarDaemonDatabaseCipher.swift`.
- Compiles off-macOS today (the Swift-engine-reuse candidates if ever revived):
  provider router/executors, run service + journal + recovery, RPC server,
  Mission Control (scheduler/journal/projection + Telegram bridge),
  project-code memory store, planner, policy engine, rate limiter, config
  store.

So even the "port the daemon" option was never a wholesale port — the gateway,
Pensieve, and the interactive-PTY pieces are excluded from the daemon's own
portable build.

### What Windows already substitutes (verified on `main`, 2026-07-06)

| Daemon duty | Windows substitute already landed |
|---|---|
| Mission dispatch (write `users/{uid}/cli_agent_mission_requests`) | `windows/app/OpenBurnBar.App/MissionControl/FirestoreMissionDispatchHost.cs` (+ `MissionDispatchHostFactory.cs`, `EmptyMissionDispatchHost.cs`; tests `windows/tests/missioncontrol/FirestoreMissionDispatchHostTests.cs`) — landed via #1267, hardened by #1272 |
| Interactive CLI execution (macOS `PTYInteractiveSession.swift` / `ClaudeInteractiveHandoffService.swift`) | `windows/app/OpenBurnBar.App/Cli/ConPtyCliStream.cs` over `windows/pal/ipc-windows/ConPtySession.cs` |
| Peer-authenticated IPC transport (macOS Unix socket + codesign gate) | `windows/pal/ipc-windows/NamedPipePeerAuthListener.cs` / `NamedPipePeerAuthConnector.cs` (signed-nonce handshake, `design/0004-named-pipe-peer-auth.md`, R16) |
| Usage recording (durable token-usage rows) | `windows/storage/OpenBurnBar.Storage/TokenUsageWriteSeam.cs` + `TokenUsageReadSeam.cs` (WPD-0004 byte-compat DB) |
| DB cipher (daemon-side SQLCipher open) | `windows/storage/OpenBurnBar.Storage/SqlCipherConnection.cs` + `SqlCipherParameters.cs` (WPD-0004) |
| Computer-use policy/capability/audit/kill-switch core | `windows/computeruse/OpenBurnBar.ComputerUse.Core/` (`Capability/`, `Gate/`, `Scope/`, `Audit/`, `KillSwitch/KillSwitch.cs`, `Watchdog/WatchdogProtocol.cs`) + adapters in `OpenBurnBar.ComputerUse.Windows/` (`SendInputInputSynthesizer.cs`, `UiaInspector.cs`, `WindowsGraphicsCaptureScreenCapturer.cs`, `NamedPipeDaemonApprovalChannel.cs`) |
| OS notification bridge (macOS `LocalNotificationBridge.swift`) | `windows/app/OpenBurnBar.App/Budget/BudgetToastNotifier.cs` (WinRT AppNotification seam — the pattern mission/budget notifications ride) |
| Self-integrity check (`DaemonSelfCodeSignatureVerifier.swift`) | `windows/dist/OpenBurnBar.Dist.Hardening/` + `windows/dist/DLL_HARDENING.md` (WinVerifyTrust + DLL-load hardening posture, R19/D10) |

### The three candidate strategies

1. **Port `OpenBurnBarDaemon` wholesale** (Swift-on-Windows Windows Service).
2. **Per-capability Tier-C substitution** — the WinUI app process + the
   portable C# cores absorb each daemon duty that Windows v1 actually needs;
   everything else is a named deferral with a revive path.
3. **Hybrid** — port only the "portable subset" (the Linux boundary build) as a
   service now.

## Decision

**Option 2 — no monolithic daemon port for v1. Per-capability Tier-C
substitution: the WinUI app process plus the portable C# cores absorb the
daemon duties Windows v1 needs; every remaining capability is a named v1.1
deferral (or explicitly not applicable), each with an owner and a revive
path.**

Why:

- **WPD-0007 already rejected the second process for the data lanes** — the
  IPC hop is a parity tax and the service lifecycle
  (install/start/stop/crash-recovery/upgrade) buys nothing while the app is
  the only client. The daemon capabilities Windows v1 needs (CLI execution,
  usage rows, mission dispatch, notifications, computer-use policy core) are
  **already substituted in-process** — see the table above.
- **The wholesale port is mostly dead weight for v1.** The gateway stack,
  Pensieve, switcher shell, and PTY session are excluded from the daemon's own
  off-macOS build; porting them means new engineering for capabilities no
  Windows v1 surface consumes (the remediation plan sized this at +100–200
  PRs).
- **The revive path is preserved, not burned.** The Linux boundary build
  (`OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD`) proves the
  router/run/Mission-Control/RPC core compiles off-macOS. If a revisit trigger
  fires, the shared Swift daemon revives through that boundary build as a
  Windows Service — additive, no re-architecture of the substituted lanes
  (same conclusion WPD-0007 reached for WS-D).

### Revisit triggers (any one revives the shared Swift daemon via the Linux boundary build)

1. **Headless / multi-client operation on Windows** becomes a requirement
   (agent runs that must survive app exit, or a second client — CLI, phone
   bridge, other apps — needs the same local endpoint).
2. **WS-D finds the privileged computer-use path needs process isolation**
   (the WPD-0007 clause) — the service then owns
   privileged-input/watchdog/approval, and the named-pipe handshake already
   landed for it.
3. **The BurnBar Gateway (local model proxy / cross-vendor degrade) is
   demanded on Windows** — the gateway is inherently a shared local endpoint
   and only makes sense daemon-hosted.

## The capability matrix

Dispositions: **SUB-DONE** = C#-substituted-already · **SUB-BUILD** =
C#-substitute-to-build (wave named) · **SWIFT-REUSE** = Swift-engine-reuse ·
**DEFER** = v1.1-deferred (named, with revive path) · **N/A** =
not-applicable-on-Windows.

All macOS paths are under `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/`
unless prefixed; all Windows paths under `windows/`.

| # | Daemon capability | macOS implementation | Windows v1 disposition | Rationale | Tracking |
|---|---|---|---|---|---|
| 1 | HTTP gateway server (routing pipeline, endpoints, transport, connection mgmt) | `OpenBurnBarHTTPGatewayServer.swift` + `+Endpoints/+RoutePipeline/+HTTPTransport/+Connection/+UsageLogging.swift`, `OpenBurnBarHTTPGatewayRequests.swift` | **DEFER** | No Windows v1 surface consumes the local proxy; excluded even from the daemon's Linux build. Revive trigger 3. | WPD-0006 deferral ledger; bundle drift D14 |
| 2 | Gateway model catalog + model health | `OpenBurnBarHTTPGatewayServer+ModelCatalog.swift`, `GatewayModelCatalogSource.swift`, `OpenBurnBarLiveModelCatalog.swift`, `BurnBarGatewayModelHealthStore.swift` | **DEFER** | Rides the gateway (row 1). | With row 1 |
| 3 | Cross-vendor degrade policy | `OpenBurnBarHTTPGatewayServer+CrossVendorDegrade.swift`, `BurnBarCrossVendorDegradePolicy.swift` | **DEFER** | Rides the gateway (row 1). | With row 1 |
| 4 | Gateway metrics / route logging / streaming usage accumulation | `BurnBarGatewayMetrics.swift`, `GatewayRouteLogging.swift`, `BurnBarProxyRouteLogStore.swift`, `GatewayStreamingUsageAccumulator.swift` | **DEFER** | Rides the gateway (row 1). | With row 1 |
| 5 | Usage recording (durable token-usage rows in the shared DB) | `OpenBurnBarUsageRecorder.swift` | **SUB-DONE** | `storage/OpenBurnBar.Storage/TokenUsageWriteSeam.cs` + `TokenUsageReadSeam.cs` write/read the same byte-compat DB (WPD-0004). | Landed (#1251/#1267) |
| 6 | Provider router (+ quota-drain ranking/metadata) | `OpenBurnBarProviderRouter.swift`, `+QuotaDrainRanking.swift`, `+QuotaDrainMetadata.swift`, `OpenBurnBarProviderCatalogSupport.swift` | **DEFER** (SWIFT-REUSE on revive) | Serves gateway + headless runs, neither in v1. Compiles off-macOS today — revives via the Linux boundary build. | Revisit triggers 1/3 |
| 7 | Provider executors (Anthropic, Codex, FactoryDroid, Ollama-native, OpenAI-compatible bridges) | `OpenBurnBarAnthropicProviderExecutor.swift`, `BurnBarCodexProviderExecutor.swift`, `FactoryDroidProviderExecutor.swift`, `OpenBurnBarProviderExecutor.swift` + `+AnthropicMessagesBridge/+OllamaNative/+ResponsesConversion.swift`, `OllamaCloudModelRoutingPolicy.swift`, `OpenBurnBarProviderCredentialNormalizer.swift` | **DEFER** (SWIFT-REUSE on revive) | Same as row 6. Windows v1 chat executes agent CLIs directly (row 9), not via daemon API executors. | Revisit triggers 1/3 |
| 8 | Headless run service: run/resume/recovery/journal, agent loop, tool dispatch | `OpenBurnBarRunService.swift`, `BurnBarRunService+Execution.swift`, `BurnBarRunService+Lifecycle.swift`, `BurnBarRunService+ToolDispatch.swift`, `BurnBarResumeService.swift`, `OpenBurnBarRecoveryEngine.swift`, `OpenBurnBarRunJournal.swift`, `OpenBurnBarAgentLoopService.swift` | **DEFER** (SWIFT-REUSE on revive) | Headless runs that outlive the app are exactly revisit trigger 1. In-app interactive sessions are covered (row 9). | Revisit trigger 1 |
| 9 | Interactive CLI/PTY session execution | `PTYInteractiveSession.swift`, `ClaudeInteractiveHandoffService.swift` | **SUB-DONE** | `app/OpenBurnBar.App/Cli/ConPtyCliStream.cs` over `pal/ipc-windows/ConPtySession.cs` (B1); live-host proof rides the WS-D pass. | Landed (#1267); live proof Wave 4 |
| 10 | RPC server (Unix-socket JSON-RPC, 13 capability extensions) | `RPC/BurnBarDaemonServer+RPC*.swift`, `OpenBurnBarDaemonServer.swift`, `BurnBarRPCCapability.swift`, `BurnBarDaemonSocketRPCCoverage.swift` | **N/A** | Single-process architecture (WPD-0007): the app calls engine/storage in-process; there is no second process to serve RPC to in v1. | Revives with any trigger |
| 11 | Peer-auth transport (codesign peer gate, token file, local auth proof) | `BurnBarDaemonPeerAuthenticator.swift`, `BurnBarDaemonTokenFile.swift`, `DaemonLocalAuthProofVerifier.swift`, `ConstantTimeCompare.swift` | **SUB-DONE** (transport primitive) | `pal/ipc-windows/NamedPipePeerAuthListener.cs`/`NamedPipePeerAuthConnector.cs` implement the hardened equivalent (R16, `design/0004-named-pipe-peer-auth.md`) — ready for the WS-D privileged process. | Landed; consumed at WS-D |
| 12 | Daemon self code-signature verifier | `DaemonSelfCodeSignatureVerifier.swift` | **SUB-DONE** (posture) | `dist/OpenBurnBar.Dist.Hardening/` + `dist/DLL_HARDENING.md` (WinVerifyTrust + DLL-load hardening, R19/D10). G5 proves it on a signed build. | Wave 5 (G5 evidence) |
| 13 | Mission dispatch client (write mission requests, status polling) | `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` (consumer side); envelope shared with daemon Mission Control | **SUB-DONE** | `app/OpenBurnBar.App/MissionControl/FirestoreMissionDispatchHost.cs` writes the same `cli_agent_mission_requests` envelope through `cloudsync/OpenBurnBar.CloudSync/Offline/OfflineWriteQueue.cs`; hardened status polling per #1272. Execution stays on the Mac host. | Landed (#1267 + #1272); surface → Real in Wave 3 |
| 14 | Mission Control execution: DAG scheduler, journal repository, projection reducer, state merger, store | `MissionControl/BurnBarParallelDAGScheduler.swift`, `MissionControlJournalRepository.swift`, `MissionControlProjectionReducer.swift`, `MissionControlMissionStateMerger.swift`, `MissionControlService.swift`, `MissionControlStore.swift` | **DEFER** (SWIFT-REUSE on revive) | Windows v1 is a dispatch + console client; local mission *execution* is a headless-daemon duty (revisit trigger 1). Whole module compiles off-macOS. | Revisit trigger 1 |
| 15 | Notification bridge: local notifications | `MissionControl/Bridges/LocalNotificationBridge.swift` | **SUB-DONE** (seam) | `app/OpenBurnBar.App/Budget/BudgetToastNotifier.cs` is the landed WinRT AppNotification seam; mission notifications ride it if/when local execution revives. | Landed; live toast proof Wave 4/5 pass |
| 16 | Notification bridge: Telegram | `MissionControl/Bridges/TelegramBotBridge.swift` | **DEFER** | Pure-HTTP portable code, but only fires from local mission execution (row 14). Deferred with it. | With row 14 |
| 17 | Notification bridge: EventKit (calendar/reminders) | `MissionControl/Bridges/EventKitBridge.swift` | **N/A** | EventKit is Apple-only; no Windows analog in scope (a Graph-calendar substitute would be a new feature, not parity). | Bundle drift D14 |
| 18 | Pensieve knowledge watcher | `PensieveKnowledgeWatcher.swift` | **DEFER** | Excluded even from the daemon's Linux build; the Windows memory surface already reads/writes `memory_facts` via `app/OpenBurnBar.App.CloudSync/CloudSyncMemoryStore.cs` (B4). Local knowledge *watching* is a v1.1 capability. | Bundle drift D14 |
| 19 | Project-code memory store + embeddings | `ProjectCodeMemory/BurnBarProjectCodeMemoryStore*.swift`, `ProjectCodeMemory/BurnBarCodeEmbedding.swift` | **DEFER** | Already governed by WPD-0003 (static parser deferred; lexical fallback = bundle drift D13). Store follows the parser. | WPD-0003; D13 |
| 20 | Planner service | `OpenBurnBarPlannerService.swift` | **DEFER** | Serves mission planning for daemon-executed runs (rows 8/14). The Mac-side listener (`AgentLens/Services/CloudSync/CLIAgentMissionRequestListener+Planner.swift`) keeps owning planning for dispatched missions. | With rows 8/14 |
| 21 | Policy engine (run/tool approval) | `OpenBurnBarPolicyEngine.swift` | **DEFER** | Gates daemon-executed runs (row 8). The *computer-use* policy core is separately substituted (row 24). | With row 8 |
| 22 | Rate limiter | `BurnBarRateLimiter.swift` | **DEFER** | Gateway-scoped (row 1). | With row 1 |
| 23 | Config store / daemon configuration | `OpenBurnBarConfigStore.swift`, `OpenBurnBarDaemonConfiguration.swift` | **SUB-DONE** (app-scoped) | `app/OpenBurnBar.App.Configuration/AppConfiguration.cs` owns Windows app/runtime config; daemon-endpoint config has no consumer without a daemon. | Landed; gateway config revives with row 1 |
| 24 | Computer-use policy/capability/audit core + service coordination | `ComputerUse/ComputerUseService.swift`, `ComputerUse/ComputerUseRunCoordinator.swift`, `ComputerUse/BurnBarCLIAuditVerify.swift` | **SUB-DONE** (core) / **SUB-BUILD** (full loop) | Core substituted: `computeruse/OpenBurnBar.ComputerUse.Core/` (Capability/Gate/Scope/Audit, ~100 tests) + Windows adapters (`SendInputInputSynthesizer.cs`, `UiaInspector.cs`, `WindowsGraphicsCaptureScreenCapturer.cs`, `NamedPipeDaemonApprovalChannel.cs`). Full loop on real hardware = **Wave 4 item 1** (G4). | Wave 4 item 1 |
| 25 | Browser tool service (Playwright driver/lifecycle, browser target policy) | `ComputerUse/OpenBurnBarPlaywrightDriver.swift`, `ComputerUse/OpenBurnBarPlaywrightLifecycle.swift`, `OpenBurnBarBrowserToolService.swift`, `OpenBurnBarBrowserTargetPolicy.swift` | **SUB-DONE** (managed browser lifecycle) | WPD-0009 fired the F2 revive trigger. The Windows app packages the reviewed Playwright bridge, composes its shell-free process lifecycle through the central child-process policy, exposes an explicit browser-runtime check, and retains the shared SSRF/DNS-rebinding target policy. | `docs/windows-port/evidence/f2/browser-computer-use-production-composition.md` |
| 26 | Privileged input execution + virtual HID bridge | `Sources/OpenBurnBarPrivilegedInputExecution/`, `Sources/OpenBurnBarVirtualHIDBridge/` | **SUB-BUILD** | Windows path = ViGEm + the watchdog process, **Wave 4 item 1** (R17/D11). Secure-desktop/lock-screen injection stays the §15.1 v1.1 non-goal (signed driver). | Wave 4 item 1; §15.1 |
| 27 | Kill-switch watchdog | `Sources/OpenBurnBarPrivilegedInputKillSwitchWatchdog/PrivilegedInputKillSwitchWatchdogMain.swift` | **SUB-DONE** (protocol) / **SUB-BUILD** (process) | Protocol/core landed (`computeruse/OpenBurnBar.ComputerUse.Core/KillSwitch/KillSwitch.cs`, `Watchdog/WatchdogProtocol.cs`); the independent watchdog *process* + signed local kill channel is **Wave 4 item 1** (R17). | Wave 4 item 1 |
| 28 | Remote access agent (+Core) and privileged-socket red-team probe | `Sources/OpenBurnBarRemoteAccessAgent/`, `Sources/OpenBurnBarRemoteAccessAgentCore/`, `Sources/OpenBurnBarPrivilegedSocketRedTeamProbe/` | **N/A** (as separate v1 processes) | Their duties (input/screen/attestation plumbing) are absorbed by the in-process computer-use adapters; a separate agent process only returns if WS-D demands isolation (trigger 2), at which point the red-team probe pattern is re-authored against named pipes. | Revisit trigger 2 |
| 29 | Companion CLI (`OpenBurnBarCLI`) | `Sources/OpenBurnBarCLI/OpenBurnBarCLIMain.swift`, `OpenBurnBarCLI.swift` | **DEFER** | The CLI is a daemon-socket client; with no daemon there is nothing to drive. Revives with trigger 1 (headless). | Revisit trigger 1 |
| 30 | Switcher shell (account-switched shells/profiles) | `OpenBurnBarSwitcherShell.swift` (`#if os(macOS)`, Linux-excluded) | **SUB-BUILD** | Profile persistence seam already landed (`storage/OpenBurnBar.Storage/SwitcherProfileWriteSeam.cs`); the switcher surface converts sample → Real in **Wave 3 item 1**, spawn path via CreateProcess/ConPTY. | Wave 3 item 1 |
| 31 | Indexed search service | `OpenBurnBarIndexedSearchService.swift` | **SUB-BUILD** | Windows search is app-side: `app/OpenBurnBar.App.Settings/SettingsSearchEngine.cs` (landed) + the command-palette stub search called out in **Wave 3 item 1**; session-log search rides the storage read seam. | Wave 3 item 1 |
| 32 | Elder Wand orchestration (fusion orchestrator, tool loop, web tools) | `ElderWandFusionOrchestrator.swift` (Linux-excluded), `ElderWandToolLoop.swift`, `ElderWandWebTools.swift` | **DEFER** | Orchestrated multi-model fusion is gateway/run-service-coupled. The Windows Elder Wand *surface* + preset persistence (`storage/OpenBurnBar.Storage/ElderWandPresetWriteSeam.cs`) convert in **Wave 3 item 1** (bundle D8 covers reachability drift). | Wave 3 (surface); orchestration with rows 1/8 |
| 33 | Connector plane + connector secret store; tooling proxy; workspace bridge broker; context selector | `OpenBurnBarConnectorPlaneService.swift`, `OpenBurnBarConnectorSecretStore.swift`, `OpenBurnBarToolingProxyService.swift`, `OpenBurnBarWorkspaceBridgeBroker.swift`, `OpenBurnBarContextSelector.swift` | **DEFER** | Adjuncts of the headless run/gateway plane (rows 1/8); no v1 consumer. | With rows 1/8 |
| 34 | Daemon lifecycle glue: heartbeat, client registry, logger, DB cipher bootstrap, Keychain interaction gate, phone-key pin store | `BurnBarDaemonHeartbeat.swift`, `OpenBurnBarClientRegistry.swift`, `OpenBurnBarDaemonLogger.swift`, `BurnBarDaemonDatabaseCipher.swift`, `SecKeychainInteractionGate.swift`, `DaemonPhoneKeyPinStore.swift` | **N/A** | Process-lifecycle plumbing for a process that doesn't exist on Windows v1. DB cipher duty is already served by the WPD-0004 seam (`storage/OpenBurnBar.Storage/SqlCipherConnection.cs`); secrets follow R15 (TPM/CNG, Wave 2), not Keychain semantics. | Revives with any trigger |

### Disposition summary

Counting each row by its current primary disposition (rows 24 and 27 count as
SUB-DONE core with a named SUB-BUILD remainder inside Wave 4 item 1; row 25 is
the WPD-0009 F2 promotion):

| Disposition | Rows | Count |
|---|---|---|
| C#-substituted-already (SUB-DONE) | 5, 9, 11, 12, 13, 15, 23, 24, 25, 27 | **10** |
| C#-substitute-to-build (SUB-BUILD) | 26 (Wave 4), 30 (Wave 3), 31 (Wave 3) | **3** |
| v1.1-deferred (DEFER; Swift-engine-reuse is the revive path for 6, 7, 8, 14) | 1, 2, 3, 4, 6, 7, 8, 14, 16, 18, 19, 20, 21, 22, 29, 32, 33 | **17** |
| Not-applicable-on-Windows (N/A) | 10, 17, 28, 34 | **4** |

Every SUB-BUILD row is owned by a named remediation-plan wave (Wave 3 item 1;
Wave 4 item 1). No row is unowned; no capability is silently dropped —
deferrals are recorded in the bundle as drift **D14** per the §15.1 no-trapdoor
discipline.

## Consequences

- `PARITY_100_REMEDIATION_PLAN.md` gap row #10 flips from "Unscoped — needs
  decision" to decided-per-WPD-0006; Wave 4 item 3 becomes "execute the
  matrix" (only rows 24/26/27 remain in Wave 4, and they were already Wave 4
  item 1 scope). The "+100–200 PRs if ported" sizing contingency is retired.
- `PARITY_CERTIFICATION_BUNDLE.md` gains accepted-drift row **D14** (daemon
  per-capability substitution) so a G5 reviewer treats the deferred daemon
  capabilities as documented drift, not missing parity.
- Master plan §10.1's "Daemon lifecycle → Windows Service (W1)" row is
  superseded for v1 by this WPD: **no Windows service ships in v1**; the
  Windows Service shape is the documented revive form. R16 (named-pipe
  peer-auth hardening) and R17 (watchdog process) remain fully in force — they
  gate the WS-D privileged path and the transport primitive that any revived
  daemon would use; no risk-register row weakens.
- If a revisit trigger fires, the revival is additive: boundary-build the
  Swift daemon (rows 6/7/8/14 compile off-macOS today), host it as a Windows
  Service, and connect it over the already-landed named-pipe handshake — the
  substituted C# lanes keep working unchanged.

## Evidence

- Daemon capability inventory: `OpenBurnBarDaemon/Sources/` tree +
  `OpenBurnBarDaemon/Package.swift` (products list; `#if os(Linux)` excludes,
  lines 37–62; `OPENBURNBAR_DAEMON_LINUX_BOUNDARY_BUILD` seam, line 11).
- Landed substitutes verified on `main` 2026-07-06 (file paths in the matrix;
  spot-checked by `ls`/`grep` — every cited path exists).
- Mission dispatch envelope parity: `FirestoreMissionDispatchHost.cs` doc
  comment ("the same envelope the phone writes") + #1272 status-polling
  hardening (bundle §6 note).
- Prior art: WPD-0007 "Why not a Windows service — the explicit rejection";
  master plan §2 tier contract; §15.1 named-deferral discipline.
