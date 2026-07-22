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
| 1 | HTTP gateway server (routing pipeline, endpoints, transport, connection mgmt) | `OpenBurnBarHTTPGatewayServer.swift` + `+Endpoints/+RoutePipeline/+HTTPTransport/+Connection/+UsageLogging.swift`, `OpenBurnBarHTTPGatewayRequests.swift` | **SUB-DONE** (authenticated local transport) | WPD-0009 fired the gateway trigger. `LocalHttpGatewayHost` is production-composed with bounded requests/responses, authenticated loopback transport, health/models/metrics/completions endpoints, listener lifecycle, provider routing, explicit unavailable behavior, and row 4 metadata-only route/usage telemetry. | `docs/windows-port/evidence/f2/model-proxy-settings-live-catalog.md` |
| 2 | Gateway model catalog + model health | `OpenBurnBarHTTPGatewayServer+ModelCatalog.swift`, `GatewayModelCatalogSource.swift`, `OpenBurnBarLiveModelCatalog.swift`, `BurnBarGatewayModelHealthStore.swift` | **SUB-DONE** (live health + local discovery) | The production catalog exposes route eligibility plus active health state. `ModelRouteHealthStore` applies the macOS cooldown policy. `GatewayLiveModelDiscovery` proactively refreshes bounded loopback Ollama `/api/tags`, OpenAI-compatible `/v1/models`, and protected Factory CLI catalogs; successful models become executable routes, configured routes win collisions, failures remove stale rows, and authenticated catalog responses expose source/status metadata. | `docs/windows-port/evidence/f2/gateway-model-health.md`; `docs/windows-port/evidence/f2/proactive-local-model-discovery.md` |
| 3 | Cross-vendor degrade policy | `OpenBurnBarHTTPGatewayServer+CrossVendorDegrade.swift`, `BurnBarCrossVendorDegradePolicy.swift` | **SUB-DONE** (opt-in bounded policy) | `CrossVendorDegradePolicy` is off by default, requires both operator enablement and per-request consent, restricts candidates to an allow-listed OpenAI-compatible vendor/model set, caps candidates, routes through the shared scorecard/health gates, and rewrites the upstream model. | `docs/windows-port/evidence/f2/cross-vendor-degrade-policy.md` |
| 4 | Gateway metrics / route logging / streaming usage accumulation | `BurnBarGatewayMetrics.swift`, `GatewayRouteLogging.swift`, `BurnBarProxyRouteLogStore.swift`, `GatewayStreamingUsageAccumulator.swift` | **SUB-DONE** (bounded durable telemetry) | `GatewayRouteTelemetryStore` persists at most 5,000 metadata-only JSONL route decisions, exposes bounded recent rows and aggregate counters, and parses OpenAI/Anthropic normal JSON or the final authoritative SSE usage event with cache-read, cache-creation, and reasoning-token separation. Corrupt, oversized, invalid, or unwritable telemetry fails open without failing the provider request. | `docs/windows-port/evidence/f2/gateway-route-telemetry.md` |
| 5 | Usage recording (durable token-usage rows in the shared DB) | `OpenBurnBarUsageRecorder.swift` | **SUB-DONE** | `storage/OpenBurnBar.Storage/TokenUsageWriteSeam.cs` + `TokenUsageReadSeam.cs` write/read the same byte-compat DB (WPD-0004). | Landed (#1251/#1267) |
| 6 | Provider router (+ quota-drain ranking/metadata) | `OpenBurnBarProviderRouter.swift`, `+QuotaDrainRanking.swift`, `+QuotaDrainMetadata.swift`, `OpenBurnBarProviderCatalogSupport.swift` | **SUB-DONE** (production scorecard) | WPD-0009 fired the gateway/headless triggers. `ModelProxyRouter` now consumes persisted non-secret route metadata through the same five-factor scorecard, strict per-provider/model quota-drain pools, cooldown/exhaustion policy, deterministic LRU/slot ties, row 2 health/discovery, and row 4 telemetry. | `docs/windows-port/evidence/f2/provider-router-scorecard.md` |
| 7 | Provider executors (Anthropic, Codex, FactoryDroid, Ollama-native, OpenAI-compatible bridges) | `OpenBurnBarAnthropicProviderExecutor.swift`, `BurnBarCodexProviderExecutor.swift`, `FactoryDroidProviderExecutor.swift`, `OpenBurnBarProviderExecutor.swift` + `+AnthropicMessagesBridge/+OllamaNative/+ResponsesConversion.swift`, `OllamaCloudModelRoutingPolicy.swift`, `OpenBurnBarProviderCredentialNormalizer.swift` | **SUB-DONE** (all configured transports) | `HttpModelCompletionExecutor` production-composes OpenAI-compatible and Anthropic Messages transports. `OllamaNativeProviderAdapter` adds native `/api/chat` conversion. `ProviderCliModelCompletionExecutor` and the protected, hash-verifying `WindowsProviderCliProcessRunner` compose guarded Codex and Factory Droid CLI execution with bounded output, process-tree cancellation, ephemeral prompt cleanup, and Standard-tier downgrade rejection. | `docs/windows-port/evidence/f2/ollama-native-provider-transport.md`; `docs/windows-port/evidence/f2/provider-cli-executors.md` |
| 8 | Headless run service: run/resume/recovery/journal, agent loop, tool dispatch | `OpenBurnBarRunService.swift`, `BurnBarRunService+Execution.swift`, `BurnBarRunService+Lifecycle.swift`, `BurnBarRunService+ToolDispatch.swift`, `BurnBarResumeService.swift`, `OpenBurnBarRecoveryEngine.swift`, `OpenBurnBarRunJournal.swift`, `OpenBurnBarAgentLoopService.swift` | **SUB-DONE** (accepted in-process runtime) | WPD-0009's live-run trigger fired. `HeadlessAgentRunService` owns model work independently of the requesting socket, stores full checkpoints in a bounded current-user-DPAPI payload store, keeps a metadata-only journal, recovers non-terminal work at startup, enforces run/tool approval, leases tool dispatch to the authenticated owning companion, and updates route health/telemetry across exact-model failover. | `docs/windows-port/evidence/f2/headless-run-recovery.md` |
| 9 | Interactive CLI/PTY session execution | `PTYInteractiveSession.swift`, `ClaudeInteractiveHandoffService.swift` | **SUB-DONE** | `app/OpenBurnBar.App/Cli/ConPtyCliStream.cs` over `pal/ipc-windows/ConPtySession.cs` (B1); live-host proof rides the WS-D pass. | Landed (#1267); live proof Wave 4 |
| 10 | RPC server (Unix-socket JSON-RPC, 13 capability extensions) | `RPC/BurnBarDaemonServer+RPC*.swift`, `OpenBurnBarDaemonServer.swift`, `BurnBarRPCCapability.swift`, `BurnBarDaemonSocketRPCCoverage.swift` | **N/A** | Single-process architecture (WPD-0007): the app calls engine/storage in-process; there is no second process to serve RPC to in v1. | Revives with any trigger |
| 11 | Peer-auth transport (codesign peer gate, token file, local auth proof) | `BurnBarDaemonPeerAuthenticator.swift`, `BurnBarDaemonTokenFile.swift`, `DaemonLocalAuthProofVerifier.swift`, `ConstantTimeCompare.swift` | **SUB-DONE** (transport primitive) | `pal/ipc-windows/NamedPipePeerAuthListener.cs`/`NamedPipePeerAuthConnector.cs` implement the hardened equivalent (R16, `design/0004-named-pipe-peer-auth.md`) — ready for the WS-D privileged process. | Landed; consumed at WS-D |
| 12 | Daemon self code-signature verifier | `DaemonSelfCodeSignatureVerifier.swift` | **SUB-DONE** (posture) | `dist/OpenBurnBar.Dist.Hardening/` + `dist/DLL_HARDENING.md` (WinVerifyTrust + DLL-load hardening, R19/D10). G5 proves it on a signed build. | Wave 5 (G5 evidence) |
| 13 | Mission dispatch client (write mission requests, status polling) | `AgentLens/Services/CloudSync/CLIAgentMissionRequestListener.swift` (consumer side); envelope shared with daemon Mission Control | **SUB-DONE** | `app/OpenBurnBar.App/MissionControl/FirestoreMissionDispatchHost.cs` writes the same `cli_agent_mission_requests` envelope through `cloudsync/OpenBurnBar.CloudSync/Offline/OfflineWriteQueue.cs`; hardened status polling per #1272. Execution stays on the Mac host. | Landed (#1267 + #1272); surface → Real in Wave 3 |
| 14 | Mission Control execution: DAG scheduler, journal repository, projection reducer, state merger, store | `MissionControl/BurnBarParallelDAGScheduler.swift`, `MissionControlJournalRepository.swift`, `MissionControlProjectionReducer.swift`, `MissionControlMissionStateMerger.swift`, `MissionControlService.swift`, `MissionControlStore.swift` | **SUB-DONE** (local DAG execution) | WPD-0009 fired the local-execution trigger. The authenticated companion plane composes `LocalMissionDagExecutor` with deterministic planning, bounded policy, shared rate limiting, metadata-only journaling, and resume/recovery. Broader intent planning and provider tools remain rows 20/21. | `docs/windows-port/evidence/f2/local-mission-production-composition.md` |
| 15 | Notification bridge: local notifications | `MissionControl/Bridges/LocalNotificationBridge.swift` | **SUB-DONE** (seam) | `app/OpenBurnBar.App/Budget/BudgetToastNotifier.cs` is the landed WinRT AppNotification seam; mission notifications ride it if/when local execution revives. | Landed; live toast proof Wave 4/5 pass |
| 16 | Notification bridge: Telegram | `MissionControl/Bridges/TelegramBotBridge.swift` | **SUB-DONE** (protected live command bridge) | The app lifecycle production-composes fixed-origin bounded send/getUpdates transport, durable ordered offsets, configured-chat isolation, due-followup delivery, the macOS command vocabulary, DPAPI-protected followup/question state, and real headless daily/weekly review launches. | `docs/windows-port/evidence/f2/telegram-bridge.md` |
| 17 | Notification bridge: EventKit (calendar/reminders) | `MissionControl/Bridges/EventKitBridge.swift` | **N/A** | EventKit is Apple-only; no Windows analog in scope (a Graph-calendar substitute would be a new feature, not parity). | Bundle drift D14 |
| 18 | Pensieve knowledge watcher | `PensieveKnowledgeWatcher.swift` | **SUB-DONE** (sealed live watcher) | The WinUI app lifecycle watches configured repo-docs/notes roots and the standard Claude session tree. It uses the same deterministic 384-dimension embedder, vault-key Householder cloak, keyed slug/dedup hashes, secret redaction, and CloudVault envelope as Swift/TS; writes atomic sealed batches plus metadata-only settled-session sentinels to the shared device queue; and fails closed without the protected vault key. | `docs/windows-port/evidence/f2/pensieve-knowledge-watcher.md` |
| 19 | Project-code memory store + embeddings | `ProjectCodeMemory/BurnBarProjectCodeMemoryStore*.swift`, `ProjectCodeMemory/BurnBarCodeEmbedding.swift` | **SUB-DONE** (durable source-free semantic store) | WPD-0003's parser trigger fired. `ProjectCodeMemoryStore` production-composes encrypted SQLite project/artifact/symbol/reference/call-edge/checkpoint metadata, bounded AST-aware chunks, versioned deterministic or protected OpenAI embeddings, restart hydration, call-graph traversal, and semantic search without persisting source text. | `docs/windows-port/evidence/f2/project-code-memory-store.md`; WPD-0003 revival addendum |
| 20 | Planner service | `OpenBurnBarPlannerService.swift` | **SUB-DONE** (intent normalization + outline) | WPD-0009 fired the planner trigger. The production authenticated companion plane exposes `planner.plan` with the same explicit-intent → workflow → tool → prompt → generic precedence, typed constraints/risk/desired outputs, exact three-step outlines, schema validation, bounded input, and no execution side effects. | `docs/windows-port/evidence/f2/planner-production-composition.md` |
| 21 | Policy engine (run/tool approval) | `OpenBurnBarPolicyEngine.swift` | **SUB-DONE** (decision + durable resolution) | The production authenticated companion plane exposes bounded, side-effect-free `policy.evaluate`; row 8 consumes the same risk matrix in durable run-level and per-tool approvals. `approval.respond` resolves the protected checkpoint, an approval can authorize exactly the next risky tool, and rejection/cancellation terminates without dispatch. Physical Computer Use approval UX remains a separate host gate. | `docs/windows-port/evidence/f2/policy-engine-production-composition.md`; `docs/windows-port/evidence/f2/headless-run-recovery.md` |
| 22 | Rate limiter | `BurnBarRateLimiter.swift` | **SUB-DONE** (per-client token bucket) | `LocalHttpGatewayHost` production-composes a thread-safe monotonic token bucket with macOS-matched 30/50 defaults, credential-digest isolation, five-minute idle pruning, bounded 429/`Retry-After`, and the stricter shared 5/30 unauthenticated-loopback ceiling. | `docs/windows-port/evidence/f2/gateway-rate-limiter.md` |
| 23 | Config store / daemon configuration | `OpenBurnBarConfigStore.swift`, `OpenBurnBarDaemonConfiguration.swift` | **SUB-DONE** (app-scoped) | `app/OpenBurnBar.App.Configuration/AppConfiguration.cs` owns Windows app/runtime config; daemon-endpoint config has no consumer without a daemon. | Landed; gateway config revives with row 1 |
| 24 | Computer-use policy/capability/audit core + service coordination | `ComputerUse/ComputerUseService.swift`, `ComputerUse/ComputerUseRunCoordinator.swift`, `ComputerUse/BurnBarCLIAuditVerify.swift` | **SUB-DONE** (approved input loop) | The durable headless run binds each risky tool to its exact approval, executes supported desktop actions through the isolated broker, reserves redacted tamper-evident audit state before dispatch, resumes only validated chains, and records panic termination. Browser and capture paths retain their own evidence rows; physical loop behavior remains a certification gate. | `docs/windows-port/evidence/f2/privileged-input-production-composition.md` |
| 25 | Browser tool service (Playwright driver/lifecycle, browser target policy) | `ComputerUse/OpenBurnBarPlaywrightDriver.swift`, `ComputerUse/OpenBurnBarPlaywrightLifecycle.swift`, `OpenBurnBarBrowserToolService.swift`, `OpenBurnBarBrowserTargetPolicy.swift` | **SUB-DONE** (managed browser lifecycle) | WPD-0009 fired the F2 revive trigger. The Windows app packages the reviewed Playwright bridge, composes its shell-free process lifecycle through the central child-process policy, exposes an explicit browser-runtime check, and retains the shared SSRF/DNS-rebinding target policy. | `docs/windows-port/evidence/f2/browser-computer-use-production-composition.md` |
| 26 | Privileged input execution + virtual HID bridge | `Sources/OpenBurnBarPrivilegedInputExecution/`, `Sources/OpenBurnBarVirtualHIDBridge/` | **SUB-DONE** (signed isolated broker) | Windows substitutes a signed, exact-publisher named-pipe broker around `SendInput` for the ordinary interactive desktop. It enforces UIA protected-target denies, a durable at-most-once receipt ledger, watchdog health, and leaf kill checks. ViGEm is not used because it emulates game controllers rather than keyboard/mouse. Secure-desktop, lock-screen, and cross-integrity injection remain explicit non-goals unless a purpose-built signed HID driver is separately certified. | `docs/windows-port/evidence/f2/privileged-input-production-composition.md`; R17/D11 |
| 27 | Kill-switch watchdog | `Sources/OpenBurnBarPrivilegedInputKillSwitchWatchdog/PrivilegedInputKillSwitchWatchdogMain.swift` | **SUB-DONE** (independent signed process) | The app production-composes the self-contained watchdog over exact-publisher authenticated named pipes. Ctrl+Alt+Win+Period, workstation lock, settings halt, and app exit activate its durable flag; a new session clears it only after the safety monitor and broker are ready. | `docs/windows-port/evidence/f2/privileged-input-watchdog-process.md` |
| 28 | Remote access agent (+Core) and privileged-socket red-team probe | `Sources/OpenBurnBarRemoteAccessAgent/`, `Sources/OpenBurnBarRemoteAccessAgentCore/`, `Sources/OpenBurnBarPrivilegedSocketRedTeamProbe/` | **N/A** (as separate v1 processes) | Their duties (input/screen/attestation plumbing) are absorbed by the in-process computer-use adapters; a separate agent process only returns if WS-D demands isolation (trigger 2), at which point the red-team probe pattern is re-authored against named pipes. | Revisit trigger 2 |
| 29 | Companion CLI (`OpenBurnBarCLI`) | `Sources/OpenBurnBarCLI/OpenBurnBarCLIMain.swift`, `OpenBurnBarCLI.swift` | **SUB-DONE** (authenticated standalone client) | WPD-0009's headless/multi-client trigger fired. `app/OpenBurnBar.Cli` drives the production companion plane over bounded loopback JSON lines, injects the gateway token only from current-user DPAPI storage, exposes typed run/mission/planner/policy/fusion/project operations, and is staged by the signed RID workflow with an MSIX `openburnbar.exe` alias. | `docs/windows-port/evidence/f2/companion-cli-client.md` |
| 30 | Switcher shell (account-switched shells/profiles) | `OpenBurnBarSwitcherShell.swift` (`#if os(macOS)`, Linux-excluded) | **SUB-DONE** (guarded ConPTY profile shell) | The production Switcher surface converts a persisted profile into a validated, shell-free launch plan. It selects a fixed executable by profile type, preserves argv through Windows `CreateProcessW` quoting, confines config/environment overrides, applies the central child-process policy, and embeds the real ConPTY stream with cancellation and visible failures. | [F2 switcher-shell evidence](../evidence/f2/switcher-shell-production-composition.md) |
| 31 | Indexed search service | `OpenBurnBarIndexedSearchService.swift` | **SUB-DONE** (app-side encrypted index) | `SettingsSearchEngine` provides weighted settings search. The command palette queries the encrypted conversation FTS index through `StorageSessionLogReadSource`, applies deterministic bounded metadata fallback in `SessionLogSearch`, cancels stale work, exposes loading/empty/error states, and deep-links the selected session. | [F2 indexed-search evidence](../evidence/f2/indexed-search-plane.md) |
| 32 | Elder Wand orchestration (fusion orchestrator, tool loop, web tools) | `ElderWandFusionOrchestrator.swift` (Linux-excluded), `ElderWandToolLoop.swift`, `ElderWandWebTools.swift` | **SUB-DONE** (parallel fusion pipeline) | The production gateway and authenticated companion plane compose the saved/explicit 1...8-model panel in parallel, partial-failure degradation, strict judge comparison, originating-model synthesis, bounded DNS-pinned web tools, recursion prevention, metadata/digest-only journaling, and route/token telemetry. | `docs/windows-port/evidence/f2/elder-wand-fusion.md` |
| 33 | Connector plane + connector secret store; tooling proxy; workspace bridge broker; context selector | `OpenBurnBarConnectorPlaneService.swift`, `OpenBurnBarConnectorSecretStore.swift`, `OpenBurnBarToolingProxyService.swift`, `OpenBurnBarWorkspaceBridgeBroker.swift`, `OpenBurnBarContextSelector.swift` | **SUB-DONE** (authenticated tooling plane) | The production app composes DPAPI-backed connector credentials, secret-free durable configuration, DNS-pinned HTTPS actions, the tooling facade, single-call workspace broker, and read-before-patch context selector. The authenticated companion plane is the concrete external consumer. | `docs/windows-port/evidence/f2/connector-tooling-plane.md` |
| 34 | Daemon lifecycle glue: heartbeat, client registry, logger, DB cipher bootstrap, Keychain interaction gate, phone-key pin store | `BurnBarDaemonHeartbeat.swift`, `OpenBurnBarClientRegistry.swift`, `OpenBurnBarDaemonLogger.swift`, `BurnBarDaemonDatabaseCipher.swift`, `SecKeychainInteractionGate.swift`, `DaemonPhoneKeyPinStore.swift` | **N/A** | Process-lifecycle plumbing for a process that doesn't exist on Windows v1. DB cipher duty is already served by the WPD-0004 seam (`storage/OpenBurnBar.Storage/SqlCipherConnection.cs`); secrets follow R15 (TPM/CNG, Wave 2), not Keychain semantics. | Revives with any trigger |

### Disposition summary

Counting each row by its current primary disposition (rows 1-4,
6-8, 14, 16, 18-22, 25, 29-33 are WPD-0009 F2 promotions):

| Disposition | Rows | Count |
|---|---|---|
| C#-substituted-already (SUB-DONE) | 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 29, 30, 31, 32, 33 | **30** |
| C#-substitute-to-build (SUB-BUILD) | - | **0** |
| v1.1-deferred (DEFER) | - | **0** |
| Not-applicable-on-Windows (N/A) | 10, 17, 28, 34 | **4** |

No primary row remains SUB-BUILD. Physical Windows behavior and signed-artifact
promotion remain certification evidence gates rather than hidden source rows.
No row is unowned; no capability is silently dropped —
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
