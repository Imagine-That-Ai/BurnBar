import Foundation
import OpenBurnBarCore

// MARK: - Memory services wiring (PR-D3 app wiring)
//
// This extension owns the construction + start-up of the semantic-memory subsystem so
// `AgentLensApp.swift` stays at its ~2022-line baseline (the debt gate). It folds in the
// PR-D3 must-fixes of the memory-activation integrated build plan:
//
//   #1 ONE shared `ControlPlaneStore`. `makeMemoryServices` builds a single store over the
//      live db queue and hands the SAME instance to `OpenBurnBarMemoryService` (the
//      enqueue path) and to `MemoryExtractionEngine` (the drain loop). No second store, no
//      second scope over the same queue — the worker is the sole provenance authority.
//   #2 The transactional enqueue branch is used. `OpenBurnBarMemoryService` conforms to
//      `TransactionalMemoryExtractionServing` (a `nonisolated func enqueueExtraction(_:in:
//      Database)`), so `saveChatMessage` enqueues the outbox row INSIDE the chat-message
//      write transaction (atomic outbox; no dual-write window). This file only wires the
//      service in; the branch selection lives in `ConversationStore+Chat.saveChatMessage`.
//   #3 The architectural guard (the engine never calls `addChatMemoryAuthorityRecord`
//      directly — it only hands `MemoryAddRequest`s to the worker, whose preflight/quarantine
//      cannot be bypassed) is enforced by the `MemoryExtractionEngine` API surface (it has no
//      reference to the store's authority-write method) and asserted by the e2e test.
//   #4 Construction order: the engine is built BEFORE `ChatSessionController` and injected,
//      so a first-session terminal commit can schedule a drain immediately (no "drains only
//      on next foreground" gap).
//   #5 Cost/egress firm defaults: provider order is forced local-first (a v1 requirement,
//      in the engine's settings snapshot) and any cloud provider is gated by the separate
//      memory daily cap — because LLM egress + spend happen the instant
//      `memoryExtractionEnabled` flips, which is an EARLIER switch than authority-writes.
//
// The feature remains consent/fleet gated: `startMemoryExtractionIfNeeded` is a no-op
// whenever the combined gate `settingsManager.memoryExtractionEnabled` is false, and
// that gate includes G0 user consent (default FALSE). The authority-write default is now
// live, so opted-in users drain their local pending extraction queue.
extension OpenBurnBarApp {

    /// Bundle of the memory services that share one `ControlPlaneStore`. Built once in
    /// `makeRuntimeContext`, before the chat controller, so the engine can be injected.
    struct MemoryServices {
        let store: ControlPlaneStore
        let service: OpenBurnBarMemoryService
        let engine: MemoryExtractionEngine
        /// PR-E2 approved-memory cloud-replication scheduler over the SAME store.
        /// Ships DORMANT (default OFF); only constructed here so the refresh
        /// orchestrator can schedule it in the post-persistence cadence.
        let cloudSyncDomain: MemoryCloudSyncDomain
        /// PR6: the usage-memory Stage-1 sleep-time tick (session-log miner →
        /// batch assembly → engine drain) over the SAME store + engine. DORMANT
        /// by default — the tick's first act is the usage extraction gate check
        /// (consent OFF out of the box), and the miner + worker re-check the
        /// same gate boxes independently.
        let usageStage1Ticker: UsageMemoryStage1Ticker
        /// PR8: the Stage-3 zero-LLM consolidation worker (decay recompute →
        /// evict → candidate TTL → orphan purge) over the SAME store. DORMANT
        /// by default behind the same usage gate box as the Stage-1 ticker;
        /// its tick gate-checks FIRST, so a disabled feature does zero work.
        let consolidationWorker: MemoryConsolidationWorker
    }

    /// Construct the shared-store memory services (PR-D3 must-fix #1 + #4; PR-E2 domain).
    ///
    /// - Parameters:
    ///   - dataStore: the live coordinator; its db queue backs the single store, and its
    ///     spend reader feeds the engine's fail-closed cloud daily cap.
    ///   - settingsManager: the source of the combined kill switch + the (summary-derived,
    ///     local-first-forced) provider settings the extractor reads per drain, and the
    ///     `memoryApprovedCloudBackupEnabled` gate the cloud-sync domain honours.
    ///   - accountManager: the cloud-sync identity gate the PR-E2 domain reads (uid,
    ///     signed-in, cloud-sync-enabled) before any egress.
    @MainActor
    static func makeMemoryServices(
        dataStore: DataStoreCoordinator,
        settingsManager: SettingsManager,
        accountManager: any AccountManaging
    ) -> MemoryServices {
        // ONE store over the live queue, shared by the service and the engine (must-fix #1).
        let store = ControlPlaneStore(dbQueue: dataStore.actor.dbQueue)

        // The actor service wired through the TRANSACTIONAL slot (must-fix #2): because it
        // conforms to `TransactionalMemoryExtractionServing`, `saveChatMessage` enqueues the
        // outbox row inside the chat-message transaction. The service also binds caller
        // scopes to the current OpenBurnBar app/account boundary before touching memory rows.
        // Behavior stays gated by the G4 kill switch in the controller and the shared
        // authority-write default.
        let service = OpenBurnBarMemoryService(
            store: store,
            scopeAuthorizationProvider: {
                OpenBurnBarMemoryService.ScopeAuthorization(
                    userID: accountManager.currentUID
                )
            }
        )

        // The drain-loop scheduler over the SAME store (must-fix #1). Local-first provider
        // order + the separate memory daily cap are enforced inside the engine (must-fix #5).
        let engine = MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settingsManager
        )

        // PR-E2: the cloud-replication scheduler over the SAME store. DORMANT by default —
        // it replicates nothing unless the user opted in (`memoryApprovedCloudBackupEnabled`,
        // default OFF), the Remote Config fleet ceiling allows, and the account is
        // cloud-sync-ready. Constructing it flips nothing on.
        let cloudSyncDomain = MemoryCloudSyncDomain(
            store: store,
            accountManager: accountManager,
            settingsManager: settingsManager
        )

        // PR6: the Stage-0 session-log miner + the Stage-1 tick over the SAME
        // store/engine. The miner's dormancy gate is the engine's usage
        // extraction gate BOX (a Sendable atomic MemorySettings keeps current
        // via `UsageMemoryKillSwitchRegistry`), so a disabled miner performs
        // ZERO file and ZERO database work. Constructing it flips nothing on.
        let usageExtractionSwitch = engine.usageExtractionKillSwitch
        let miner = UsageSessionLogMiner(
            store: store,
            sessionsRootURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true),
            isEnabled: { usageExtractionSwitch.isAllowed() }
        )
        let usageStage1Ticker = UsageMemoryStage1Ticker(
            store: store,
            miner: miner,
            engine: engine,
            isEnabled: { usageExtractionSwitch.isAllowed() },
            mineAgentSessions: { settingsManager.usageMemorySourceAgentSessionsEnabled }
        )

        // PR8: the Stage-3 consolidation worker over the SAME store, behind the
        // SAME usage gate box as the Stage-1 ticker. Constructing it flips
        // nothing on — the tick's first act is this gate check.
        let consolidationWorker = MemoryConsolidationWorker(
            store: store,
            isEnabled: { usageExtractionSwitch.isAllowed() }
        )

        return MemoryServices(
            store: store,
            service: service,
            engine: engine,
            cloudSyncDomain: cloudSyncDomain,
            usageStage1Ticker: usageStage1Ticker,
            consolidationWorker: consolidationWorker
        )
    }

    /// Start the memory-extraction drain loop, if the gate currently allows. Called from
    /// `startLiveServicesIfNeeded` (already behind `shouldUseTestStubScene`, so it never
    /// runs under the test-stub scene). A no-op when the combined kill switch is off.
    /// `launchDrain()` itself re-reads the live gate and returns immediately when extraction
    /// is disabled, so this is safe to call unconditionally on startup.
    @MainActor
    func startMemoryExtractionIfNeeded(context: OpenBurnBarRuntimeContext) {
        guard let engine = context.memoryExtractionEngine else { return }
        // Mirror the latest gate + settings into the worker-visible boxes, then kick a
        // foreground drain. If the gate is off this returns without scheduling any work and
        // without any LLM egress or spend.
        engine.launchDrain()
        // PR6: register the usage-memory Stage-1 cadence. Registration alone is
        // inert — `isEnabled` stays false until the user grants usage consent,
        // and even then the tick only runs while the display sleeps or the user
        // has been idle ≥5 min. NEVER on any request hot path: the only trigger
        // is the coordinator's timer.
        if let ticker = context.usageMemoryStage1Ticker {
            Self.registerUsageMemoryStage1Cadence(ticker: ticker)
        }
        // PR8: register the Stage-3 consolidation cadence. Registration alone
        // is inert for the same reason as Stage-1 — the gate box stays closed
        // until the user grants usage consent, and the worker's tick checks it
        // FIRST before touching the database.
        if let worker = context.memoryConsolidationWorker {
            Self.registerUsageMemoryConsolidationCadence(
                worker: worker,
                usageSwitch: engine.usageExtractionKillSwitch
            )
        }
    }

    /// Register the sleep-time Stage-1 loop on the canonical timer surface
    /// (`docs/architecture/background-cadence.md`). Intervals per the Stage-1
    /// plan: display-asleep 45 min, app-background 2 h, foreground 4 h; no
    /// eager first fire. The idle predicate keeps foreground/background fires
    /// off active working sessions.
    @MainActor
    static func registerUsageMemoryStage1Cadence(ticker: UsageMemoryStage1Ticker) {
        let usageSwitch = ticker.usageExtractionSwitchForCadence
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "usage-memory-extraction",
                activeInterval: 4 * 3600,
                backgroundInterval: 2 * 3600,
                sleepInterval: 45 * 60,
                isEnabled: {
                    usageSwitch.isAllowed()
                        && (BackgroundCadenceCoordinator.shared.displayIsAwake == false
                            || UserIdleService.idleSeconds() >= 300)
                },
                fireImmediately: false,
                work: {
                    await ticker.tick()
                }
            )
        )
    }

    /// PR8: register the Stage-3 zero-LLM consolidation loop on the canonical
    /// timer surface. Intervals per the Stage-3 plan: display-asleep 6 h,
    /// app-background 12 h, foreground 24 h; no eager first fire. The gate is
    /// the SAME usage gate box as the Stage-1 cadence, and the worker's tick
    /// re-checks it before any database work.
    @MainActor
    static func registerUsageMemoryConsolidationCadence(
        worker: MemoryConsolidationWorker,
        usageSwitch: MemoryExtractionKillSwitch
    ) {
        BackgroundCadenceCoordinator.shared.register(
            BackgroundCadenceCoordinator.Cadence(
                id: "usage-memory-consolidation",
                activeInterval: 24 * 3600,
                backgroundInterval: 12 * 3600,
                sleepInterval: 6 * 3600,
                isEnabled: { usageSwitch.isAllowed() },
                fireImmediately: false,
                work: {
                    await worker.consolidationTick()
                }
            )
        )
    }
}

// MARK: - Usage-memory Stage-1 tick (PR6)

/// One sleep-time Stage-1 pass: mine session logs into the candidate spool,
/// assemble at most `policy.maxJobsPerTick` batch jobs from it, then kick the
/// extraction engine's drain. Every stage re-checks its own gate, but the tick
/// guards the usage extraction gate FIRST so a dormant feature performs zero
/// work (and tests can prove "gates off ⇒ the tick does nothing").
@MainActor
struct UsageMemoryStage1Ticker {
    private let store: ControlPlaneStore
    private let miner: UsageSessionLogMiner
    private let engine: MemoryExtractionEngine
    private let policy: UsageMemoryExtractionPolicy
    private let promptVersion: String
    private let scope: MemoryScope
    private let isEnabled: () -> Bool
    /// Source toggle (U1): mining agent-session logs is separately opt-out.
    /// Batch assembly + drain still run — PR5's Safari source spools through
    /// the same funnel.
    private let mineAgentSessions: () -> Bool

    init(
        store: ControlPlaneStore,
        miner: UsageSessionLogMiner,
        engine: MemoryExtractionEngine,
        policy: UsageMemoryExtractionPolicy = .default,
        promptVersion: String = UsageMemoryCurationPolicy.defaults.extractionPromptVersion,
        // The same user scope the chat extraction path stamps on its jobs
        // (`ChatSessionController.makeMemoryExtractionContext`).
        scope: MemoryScope = MemoryScope(appID: "openburnbar"),
        isEnabled: @escaping () -> Bool,
        mineAgentSessions: @escaping () -> Bool = { true }
    ) {
        self.store = store
        self.miner = miner
        self.engine = engine
        self.policy = policy
        self.promptVersion = promptVersion
        self.scope = scope
        self.isEnabled = isEnabled
        self.mineAgentSessions = mineAgentSessions
    }

    /// The cadence's `isEnabled` reads the same gate box the tick guards on.
    var usageExtractionSwitchForCadence: MemoryExtractionKillSwitch {
        engine.usageExtractionKillSwitch
    }

    /// Run one Stage-1 pass. Mining and assembly failures are logged and
    /// swallowed (the next tick retries from durable state); nothing here may
    /// fail a caller or block a request path.
    func tick(now: Date = Date()) async {
        guard isEnabled() else { return }
        if mineAgentSessions() {
            do {
                _ = try await miner.mineTick(now: now)
            } catch {
                AppLogger.dataStore.silentFailure("usage_memory_stage1_mine_failed", error: error, context: [:])
            }
        }
        do {
            _ = try await store.assembleUsageExtractionBatch(
                policy: policy,
                promptVersion: promptVersion,
                scope: scope,
                now: now
            )
        } catch {
            AppLogger.dataStore.silentFailure("usage_memory_stage1_assembly_failed", error: error, context: [:])
        }
        engine.launchDrain()
    }
}

// MARK: - Runtime-context memory wiring

extension OpenBurnBarRuntimeContext {
    /// Stash the constructed memory services on the context in one call, so the
    /// app-startup site does not grow line-by-line per field (`AgentLensApp.swift`
    /// is at its debt-gate baseline). Sets the shared store, the drain engine, and
    /// the PR-E2 cloud-sync domain, then kicks the local backlog. The engine re-reads
    /// the combined gate before doing work, so this flips nothing on when memory is
    /// disabled.
    func applyMemoryServices(_ services: OpenBurnBarApp.MemoryServices) {
        chatMemoryStore = services.store
        memoryExtractionEngine = services.engine
        memoryCloudSyncDomain = services.cloudSyncDomain
        usageMemoryStage1Ticker = services.usageStage1Ticker
        memoryConsolidationWorker = services.consolidationWorker
        services.engine.launchDrain()
    }
}
