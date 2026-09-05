import Foundation

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
        // Memory Blind Sync PR-2: the inbox scope must be re-enforced the moment
        // the signed-in member changes, not on the next refresh tick (600 s by
        // default) — otherwise a sign-out leaves the daemon's consent marker
        // standing over the previous member's parked plaintext, and the daemon
        // outlives the app. Registering flips nothing on: the transition handler
        // only ever WITHDRAWS consent and deletes rows.
        cloudSyncDomain.startObservingAccountIdentity()

        return MemoryServices(store: store, service: service, engine: engine, cloudSyncDomain: cloudSyncDomain)
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
        services.engine.launchDrain()
    }
}
