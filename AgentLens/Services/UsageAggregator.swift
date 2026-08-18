import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Usage Aggregator

/// Thin `@Observable` facade that coordinates the refresh pipeline.
///
/// Heavy work (parsing 12+ providers, DB persistence, quota API calls,
/// conversation indexing, cloud sync) runs off the main thread via
/// `RefreshBackgroundWork`, a `nonisolated` namespace that runs off the main
/// actor when awaited (SE-0338).  Observable state updates
/// happen on the main actor at apply boundaries.
@Observable
@MainActor
final class UsageAggregator {
    private let dataStore: DataStore
    private let parsers: [AgentProvider: any OpenBurnBarCore.LogParser]
    private weak var cloudSync: CloudSyncService?
    private weak var cloudSyncCoordinator: CloudSyncCoordinator?
    private weak var sessionMirror: ICloudSessionMirrorService?
    private let settingsManager: SettingsManager
    private let providerAPIKeyStore: ProviderAPIKeyStore
    private(set) var usageAPIService: ProviderUsageAPIService?
    private let quotaService: ProviderQuotaService
    private let artifactDiscoveryService: ArtifactDiscoveryService
    private let projectionPipelineServiceOverride: ProjectionPipelineService?
    private let refreshOrchestrator: RefreshOrchestrator

    /// The auto-summary subsystem. Views can observe summary progress via
    /// this property (e.g. `aggregator.summaryEngine.isSummarizing`).
    let summaryEngine: AutoSummaryEngine

    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var errors: [AgentProvider: String] = [:]
    private(set) var parserImportError: String?
    private(set) var parserHealth: [AgentProvider: ParserHealth] = [:]
    /// Set when usage row persistence fails during refreshAll().
    /// Tests can read this to verify the guard condition was triggered.
    private(set) var persistenceErrorMessage: String?
    /// Typed counterpart to `persistenceErrorMessage` for metrics and structured logging.
    private(set) var typedPersistenceError: OpenBurnBarError?
    /// Usage records fetched from provider billing APIs (separate from log-parsed data).
    private(set) var apiUsages: [ProviderUsageRecord] = []
    private var projectionWorkerTask: Task<Void, Never>?
    private var projectionWorkerWakeTask: Task<Void, Never>?
    private var projectionWorkerWakeAt: Date?
    private var conversationIndexingTask: Task<Void, Never>?
    private var projectionSweepRequested = false
    private var lastProjectionInsightRefreshAt: Date?
    /// Set by `MemoryFootprintWatchdog` when the process footprint crosses
    /// the critical threshold; suppresses new conversation-indexing passes
    /// until the watchdog observes recovery.
    private(set) var memoryPressureSheddingActive = false

    // MARK: - Forwarded Summary State (observation convenience)

    /// Convenience forwarding so existing view code that reads
    /// `aggregator.isSummarizing` continues to work without changes.
    var isSummarizing: Bool { summaryEngine.isSummarizing }
    var summaryProgressDone: Int { summaryEngine.summaryProgressDone }
    var summaryProgressTotal: Int { summaryEngine.summaryProgressTotal }
    var summaryCurrentTitle: String { summaryEngine.summaryCurrentTitle }
    var summaryQueue: [SummaryQueueItem] { summaryEngine.summaryQueue }
    var summaryTimeRemaining: TimeInterval? { summaryEngine.summaryTimeRemaining }

    // MARK: - Init

    init(
        dataStore: DataStore,
        cloudSync: CloudSyncService? = nil,
        cloudSyncCoordinator: CloudSyncCoordinator? = nil,
        sessionMirror: ICloudSessionMirrorService? = nil,
        settingsManager: SettingsManager = .shared,
        usageAPIService: ProviderUsageAPIService? = nil,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        quotaService: ProviderQuotaService = .shared,
        artifactDiscoveryService: ArtifactDiscoveryService? = nil,
        projectionPipelineService: ProjectionPipelineService? = nil,
        parserOverrides: [AgentProvider: any OpenBurnBarCore.LogParser]? = nil,
        summaryEngine: AutoSummaryEngine? = nil,
        memoryCloudSyncDomain: MemoryCloudSyncDomain? = nil
    ) {
        self.dataStore = dataStore
        self.cloudSync = cloudSync
        self.cloudSyncCoordinator = cloudSyncCoordinator
        self.sessionMirror = sessionMirror
        self.settingsManager = settingsManager
        self.usageAPIService = usageAPIService ?? ProviderUsageAPIService(keyStore: providerAPIKeyStore)
        self.providerAPIKeyStore = providerAPIKeyStore
        self.quotaService = quotaService
        self.artifactDiscoveryService = artifactDiscoveryService
            ?? ArtifactDiscoveryService(dataStore: dataStore, settingsProvider: settingsManager)
        self.projectionPipelineServiceOverride = projectionPipelineService
        self.parsers = parserOverrides ?? ParserRegistry.defaultParsers()
        self.refreshOrchestrator = RefreshOrchestrator(
            dataStore: dataStore,
            settingsManager: settingsManager,
            cloudSyncCoordinator: cloudSyncCoordinator,
            cloudSync: cloudSync,
            sessionMirror: sessionMirror,
            quotaService: quotaService,
            usageAPIService: usageAPIService,
            memoryCloudSyncDomain: memoryCloudSyncDomain
        )
        self.summaryEngine = summaryEngine ?? AutoSummaryEngine(
            dataStore: dataStore,
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )
        self.summaryEngine.onRequestProjectionSweep = { [weak self] in
            self?.requestProjectionSweep()
        }
        self.quotaService.onSnapshotsPersistedForCloudSync = { [weak self] snapshots in
            Task {
                await MainActor.run { [weak self] in
                    Task { await self?.publishQuotaSnapshotsForIOS(snapshots) }
                }
            }
        }
        Task {
            await MainActor.run { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let pendingProjectionJobs = (try? await self.dataStore.countProjectionJobs(statuses: [.queued, .failed, .leased, .running])) ?? 0 // try?-ok(opportunistic sweep gate)
                    if pendingProjectionJobs > 0 {
                        self.requestProjectionSweep()
                    }
                }
            }
        }
    }

    // MARK: - Refresh All

    private func publishQuotaSnapshotsForIOS(_ snapshots: [ProviderQuotaSnapshot]) async {
        if let coordinator = cloudSyncCoordinator {
            await coordinator.syncProviderAccounts()
            await coordinator.syncQuotaSnapshots(snapshots)
        } else if let cloudSync {
            await cloudSync.uploadProviderAccountsForIOS()
            await cloudSync.uploadQuotaSnapshotsForIOS(snapshots)
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errors = [:]
        parserImportError = nil
        parserHealth = [:]
        persistenceErrorMessage = nil
        typedPersistenceError = nil

        // VAL-TOKEN-008: Set fallback estimator based on user flag before parsing.
        OpenBurnBarCore.TokenExtractionUtility.fallbackEstimator = settingsManager.tokenizerAssistedFallbackEnabled
            ? .tokenizerAssisted
            : .characterRatio

        // Snapshot main-actor state before entering background.
        let settings = RefreshSettingsSnapshot(
            conversationIndexingEnabled: settingsManager.conversationIndexingEnabled,
            snapshotAPIs: usageAPIService?.snapshotAPIs() ?? []
        )
        let parsers = self.parsers
        let dataStore = self.dataStore
        let orchestrator = self.refreshOrchestrator

        let refreshStartedAt = Date()

        // Data retention: purge expired rows once per launch.
        await orchestrator.runRetentionPurgeIfNeeded()

        // ── Heavy work runs entirely off the main thread ─────────────
        // `RefreshBackgroundWork` is a `nonisolated` namespace, so awaiting it
        // from this `@MainActor` method runs it off the main actor (SE-0338).
        let result: FullRefreshResult
        do {
            result = try await RefreshBackgroundWork.runFullRefresh(
                parsers: parsers,
                dataStore: dataStore,
                orchestrator: orchestrator,
                settings: settings
            )
        } catch is CancellationError {
            return
        } catch {
            // runFullRefresh only throws CancellationError; any other error is unexpected.
            return
        }

        // ── Apply results back on the main actor ─────────────────────────
        parserHealth = result.parserHealth
        errors = result.errors

        // Reload from DB so the in-memory array stays canonical — but ONLY
        // when the usage table content actually changed (write marker) or a
        // rendered time-window boundary passed. An idle tick previously
        // refetched + re-sorted + re-aggregated the entire usage history
        // here before the fingerprint gate could discard it; now it costs
        // one actor hop. See docs/architecture/macos-performance.md §18.
        await dataStore.reloadUsagesIfChanged()
        lastRefresh = Date()

        persistenceErrorMessage = result.persistenceErrorMessage
        typedPersistenceError = result.typedPersistenceError
        if let healthError = result.healthWriteError, parserImportError == nil {
            parserImportError = healthError
        }

        isRefreshing = false

        let postResult = result.postPersistence
        apiUsages = postResult.apiUsages
        if let postError = postResult.parserImportError, parserImportError == nil {
            parserImportError = postError
        }

        let pendingProjectionJobs = postResult.pendingProjectionJobs
        launchArtifactDiscoverySweep()
        if result.indexedConversationChanges > 0,
           pendingProjectionJobs < AutoSummaryPolicy.pauseWhenProjectionQueueExceeds {
            summaryEngine.launchAutoSummarySweep(indexedAfter: refreshStartedAt)
        }
        if result.indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
            launchProjectionSweep()
        }

        scheduleConversationIndexingIfNeeded(
            parsers: parsers,
            orchestrator: orchestrator,
            indexingEnabled: settings.conversationIndexingEnabled,
            indexedAfter: refreshStartedAt
        )

        let totalDuration = Date().timeIntervalSince(refreshStartedAt)
        AppLogger.parser.info(
            "usage_refresh_timing",
            metadata: [
                "parse_ms": Self.formatMilliseconds(result.parsePhaseDuration),
                "persist_ms": Self.formatMilliseconds(result.persistencePhaseDuration),
                "post_persist_ms": Self.formatMilliseconds(postResult.postPersistencePhaseDuration),
                "total_ms": Self.formatMilliseconds(totalDuration),
                "providers_scanned": String(parsers.count),
                "usage_rows": String(result.allUsages.count),
                "indexed_changes": String(result.indexedConversationChanges),
                "api_supplemental_rows": String(postResult.supplementalUsageCount),
                // No silent caps: how much new log content this pass read and
                // how many files the byte budget pushed to the next tick.
                "parse_new_content_mb": String(result.parseConsumedByteCount / (1024 * 1024)),
                "parse_deferred_files": String(result.parseDeferredFileCount)
            ]
        )
    }

    /// Memory-watchdog escape hatch: cancels the heavy optional background
    /// work and surfaces the condition in parser health (visible in the UI)
    /// instead of only in Activity Monitor.
    func shedBackgroundWorkForMemoryPressure(footprintMB: Int64) {
        memoryPressureSheddingActive = true
        conversationIndexingTask?.cancel()
        conversationIndexingTask = nil
        if parserImportError == nil {
            parserImportError = "Background parsing paused: memory footprint reached \(footprintMB)MB. It resumes automatically once memory recovers."
        }
    }

    /// Called by the watchdog once the footprint falls back under the re-arm
    /// threshold.
    func memoryPressureRecovered() {
        memoryPressureSheddingActive = false
    }

    private static func formatMilliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds * 1_000)
    }

    // MARK: - Test Helpers

    /// Test helper: computes supplemental usages for given API records and existing local usages.
    internal func computeSupplementalUsages(
        from records: [ProviderUsageRecord],
        existingUsages: [TokenUsage]
    ) -> [TokenUsage] {
        BillingUsageReconciliation.supplementalUsages(from: records, existingUsages: existingUsages)
    }

    /// Test helper: checks if a cost delta exceeds the epsilon threshold.
    internal static func costDeltaExceedsEpsilon(localCost: Double, apiCost: Double) -> Bool {
        let missingCost = max(apiCost - localCost, 0)
        let costEpsilon = 1e-9
        return missingCost > costEpsilon
    }

    /// Clears local usage rows so the dashboard resets immediately, then re-parses all providers.
    func recountAll() async {
        guard !isRefreshing else { return }
        // Demote any already-armed cloud reconciliation before touching the
        // table: from here until the rebuild verifiably commits, the local
        // usage table may be partially populated, and orphan cleanup must
        // never run against it. Durable, so an app death mid-recount keeps
        // cleanup blocked after relaunch.
        UsageSyncService.beginOrphanReconciliationRecount()
        var clearSucceeded = true
        do {
            try await dataStore.deleteAll()
        } catch {
            clearSucceeded = false
            let typed = OpenBurnBarError.database(
                "recount_clear_failed",
                message: "Failed to clear usage rows before recount.",
                underlying: error
            )
            parserImportError = typed.message
            typedPersistenceError = typed
            do {
                try await upsertParserImportHealth(importedUsageCount: 0, persistenceError: typed.message)
            } catch {
                let healthTyped = OpenBurnBarError.database(
                    "parser_health_persist_failed",
                    message: "Failed to persist parser/import health.",
                    underlying: error
                )
                parserImportError = healthTyped.message
                typedPersistenceError = healthTyped
            }
        }
        let recountStartedAt = Date()
        await refreshAll()
        // Tell the usage sync domain to reconcile now-orphaned cloud docs on
        // its next pass — a durable state (not a notification) because the
        // sync service is constructed fresh per upload and would miss an
        // in-memory signal — but ONLY when this rebuild verifiably committed:
        // the clear succeeded, the refresh actually applied its results
        // (`lastRefresh` advanced; a cancelled or short-circuited refresh
        // leaves it stale), and persistence reported no error. A recount whose
        // persist failed partway leaves a non-empty-but-INCOMPLETE table, and
        // reconciling against it would delete cloud docs for rows that were
        // never re-persisted. On failure the request stays pending
        // (`awaitingRecountCompletion`) and a successful retry re-arms it.
        let refreshApplied = (lastRefresh ?? .distantPast) >= recountStartedAt
        if Self.recountRebuildCommitted(
            clearSucceeded: clearSucceeded,
            refreshApplied: refreshApplied,
            typedPersistenceError: typedPersistenceError
        ) {
            UsageSyncService.requestOrphanReconciliation()
        }
    }

    /// Completion gate for `recountAll`'s one-shot cloud orphan reconciliation:
    /// the rebuild counts as committed only when the table clear succeeded, the
    /// refresh ran to completion and applied its results, and usage persistence
    /// reported no error. Anything less can leave a partially populated local
    /// table, which must never be used as the deletion baseline for cloud docs.
    internal static func recountRebuildCommitted(
        clearSucceeded: Bool,
        refreshApplied: Bool,
        typedPersistenceError: OpenBurnBarError?
    ) -> Bool {
        clearSucceeded && refreshApplied && typedPersistenceError == nil
    }

    // MARK: - Refresh Single Provider

    func refresh(provider: AgentProvider) async {
        guard let parser = parsers[provider] else { return }

        // VAL-TOKEN-008: Set fallback estimator based on user flag before parsing.
        OpenBurnBarCore.TokenExtractionUtility.fallbackEstimator = settingsManager.tokenizerAssistedFallbackEnabled
            ? .tokenizerAssisted
            : .characterRatio

        // Snapshot main-actor state before entering background.
        let settings = RefreshSettingsSnapshot(
            conversationIndexingEnabled: settingsManager.conversationIndexingEnabled,
            snapshotAPIs: usageAPIService?.snapshotAPIs() ?? []
        )
        let dataStore = self.dataStore

        let refreshStartedAt = Date()

        // ── Heavy work runs entirely off the main thread ─────────────
        // `RefreshBackgroundWork` is a `nonisolated` namespace, so awaiting it
        // from this `@MainActor` method runs it off the main actor (SE-0338).
        let result = await RefreshBackgroundWork.runSingleProviderRefresh(
            provider: provider,
            parser: parser,
            dataStore: dataStore,
            settings: settings
        )

        // ── Apply results back on the main actor ─────────────────────────
        parserHealth[provider] = result.health

        if let error = result.error {
            errors[provider] = error
            parserImportError = error
        } else {
            errors.removeValue(forKey: provider)
        }

        // Same marker-gated reload as refreshAll(): skips the full refetch
        // when this provider's parse changed nothing.
        await dataStore.reloadUsagesIfChanged()

        do {
            try await upsertParserImportHealth(
                importedUsageCount: result.usages.count,
                persistenceError: result.error
            )
        } catch {
            let typed = OpenBurnBarError.database(
                "parser_health_persist_failed",
                message: "Failed to persist parser/import health.",
                underlying: error
            )
            parserImportError = typed.message
            typedPersistenceError = typed
        }

        let pendingProjectionJobs = (try? await dataStore.countProjectionJobs(statuses: [.queued, .failed, .leased, .running])) ?? 0 // try?-ok(opportunistic sweep gate)
        launchArtifactDiscoverySweep()
        if result.indexedConversationChanges > 0 {
            summaryEngine.launchAutoSummarySweep(indexedAfter: refreshStartedAt)
        }
        if result.indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
            launchProjectionSweep()
        }
        scheduleConversationIndexingIfNeeded(
            parsers: [provider: parser],
            orchestrator: refreshOrchestrator,
            indexingEnabled: settings.conversationIndexingEnabled,
            indexedAfter: refreshStartedAt
        )
        if ProviderQuotaService.supportedProviders.contains(provider) {
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        }
    }
}

// MARK: - Private Helpers

private extension UsageAggregator {
    func scheduleConversationIndexingIfNeeded(
        parsers: [AgentProvider: any OpenBurnBarCore.LogParser],
        orchestrator: RefreshOrchestrator,
        indexingEnabled: Bool,
        indexedAfter: Date
    ) {
        if !indexingEnabled {
            conversationIndexingTask?.cancel()
            return
        }
        // Watchdog shedding: no new indexing passes while the process
        // footprint is critical; the periodic refresh keeps calling here, so
        // indexing resumes on the first tick after recovery.
        guard !memoryPressureSheddingActive else { return }
        guard conversationIndexingTask == nil else { return }

        let dataStore = self.dataStore
        conversationIndexingTask = Task(priority: .utility) { [weak self] in
            defer { self?.conversationIndexingTask = nil }

            let result = await RefreshBackgroundWork.runConversationIndexing(
                parsers: parsers,
                dataStore: dataStore,
                orchestrator: orchestrator,
                indexingEnabled: indexingEnabled
            )
            guard !Task.isCancelled, let self else { return }

            if !result.errors.isEmpty {
                for (provider, error) in result.errors {
                    AppLogger.parser.error(
                        "conversation_indexing_failed",
                        metadata: [
                            "provider": provider.rawValue,
                            "error": error
                        ]
                    )
                }
            }

            if result.indexedConversationChanges > 0 {
                let pendingProjectionJobs = (try? await self.dataStore.countProjectionJobs( // try?-ok(opportunistic sweep gate)
                    statuses: [.queued, .leased, .running]
                )) ?? 0
                if pendingProjectionJobs < AutoSummaryPolicy.pauseWhenProjectionQueueExceeds {
                    self.summaryEngine.launchAutoSummarySweep(indexedAfter: indexedAfter)
                }
                self.launchProjectionSweep()
            }

            AppLogger.parser.info(
                "conversation_indexing_timing",
                metadata: [
                    "duration_ms": Self.formatMilliseconds(result.duration),
                    "indexed_changes": String(result.indexedConversationChanges),
                    "provider_errors": String(result.errors.count),
                    "read_content_mb": String(result.consumedByteCount / (1024 * 1024)),
                    "deferred_files": String(result.deferredFileCount)
                ]
            )
        }
    }

    func upsertParserImportHealth(importedUsageCount: Int, persistenceError: String?) async throws {
        let providers = parsers.keys.sorted { $0.rawValue < $1.rawValue }
        let providerStates = providers.map { provider -> ParserImportHealthProviderState in
            let health = parserHealth[provider] ?? .notConfigured
            return ParserImportHealthProviderState(
                provider: provider.rawValue,
                status: health.statusLabel,
                sessionCount: health.sessionCount,
                errorMessage: health.errorMessage
            )
        }

        let healthyCount = providerStates.filter { $0.status == "healthy" }.count
        let emptyCount = providerStates.filter { $0.status == "empty" }.count
        let degradedCount = providerStates.filter { $0.status == "degraded" }.count
        let failedCount = providerStates.filter { $0.status == "failed" }.count

        let status: RetrievalHealthStatus
        let errorCode: String?
        let errorMessage: String?

        if let persistenceError, persistenceError.isEmpty == false {
            status = .failed
            errorCode = "PARSER_IMPORT_PERSISTENCE_FAILED"
            errorMessage = persistenceError
        } else if failedCount > 0 && failedCount == providerStates.count {
            status = .failed
            errorCode = "PARSER_IMPORT_ALL_PROVIDERS_FAILED"
            errorMessage = "All parser imports failed during the latest refresh."
        } else if failedCount > 0 || degradedCount > 0 {
            status = .degraded
            errorCode = "PARSER_IMPORT_PARTIAL_FAILURE"
            errorMessage = "Parser import completed with partial failures."
        } else {
            status = .healthy
            errorCode = nil
            errorMessage = nil
        }

        let details = ParserImportHealthDetails(
            scannedProviders: providerStates.count,
            importedUsageCount: max(0, importedUsageCount),
            healthyProviders: healthyCount,
            emptyProviders: emptyCount,
            degradedProviders: degradedCount,
            failedProviders: failedCount,
            conversationIndexingEnabled: settingsManager.conversationIndexingEnabled,
            providerStates: providerStates
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)
        let now = Date()
        try await dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .parserImport,
                status: status,
                errorCode: errorCode,
                errorMessage: errorMessage,
                detailsJSON: detailsJSON,
                observedAt: now,
                updatedAt: now
            )
        )

        if status == .healthy {
            parserImportError = nil
        } else if let errorMessage {
            parserImportError = errorMessage
        }
    }

    func launchArtifactDiscoverySweep() {
        guard settingsManager.artifactDiscoveryEnabled else { return }

        Task(priority: .utility) { [weak self] in
            await self?.runArtifactDiscoverySweep()
        }
    }

    func launchProjectionSweep() {
        requestProjectionSweep()
    }

    func makeProjectionPipelineService() -> ProjectionPipelineService {
        projectionPipelineServiceOverride
            ?? ProjectionPipelineService.makeConfigured(
                dataStore: dataStore,
                settingsManager: settingsManager,
                providerAPIKeyStore: providerAPIKeyStore
            )
    }

    func runArtifactDiscoverySweep() async {
        do {
            _ = try await artifactDiscoveryService.discoverAndIngest()
        } catch {
            let now = Date()
            do {
                try await dataStore.upsertRetrievalHealth(
                    RetrievalHealthRecord(
                        subsystem: .discovery,
                        status: .failed,
                        errorCode: "DISCOVERY_RUNTIME_ERROR",
                        errorMessage: error.localizedDescription,
                        detailsJSON: nil,
                        observedAt: now,
                        updatedAt: now
                    )
                )
            } catch {
                AppLogger.search.silentFailure( // cov:ignore -- nonfatal-log
                    "discovery_health_write_failed", // cov:ignore -- nonfatal-log
                    error: error, // cov:ignore -- nonfatal-log
                    context: ["subsystem": RetrievalSubsystem.discovery.rawValue] // cov:ignore -- nonfatal-log
                ) // cov:ignore -- nonfatal-log
            }
        }
        requestProjectionSweep()
    }

    @discardableResult
    func runProjectionSweep() async -> Bool {
        do {
            let queueDepthBeforeSweep = try await dataStore.countProjectionJobs(statuses: [.queued, .failed, .leased, .running])
            let maxJobs = queueDepthBeforeSweep >= ProjectionWorkerPolicy.backlogCompactionThreshold
                ? ProjectionWorkerPolicy.catchUpMaxJobsPerPass
                : ProjectionWorkerPolicy.maxJobsPerPass
            let report = try await makeProjectionPipelineService().runSweep(
                maxJobs: maxJobs
            )
            // Only a full pass proves there may be more work available now.
            // Future `availableAt` rows are handled by one scheduled wake below;
            // treating their mere existence as immediate backlog caused a 20ms
            // polling loop while a delayed re-embed waited.
            let hasBacklog = report.leasedJobs >= maxJobs

            if shouldRefreshProjectionInsights(report: report, hasBacklog: hasBacklog) {
                _ = await WorkflowInsightRollupService(dataStore: dataStore).snapshotAsync(refreshIfStale: true)
                lastProjectionInsightRefreshAt = Date()
            }
            return hasBacklog
        } catch is CancellationError {
            return false
        } catch {
            let now = Date()
            do {
                try await dataStore.upsertRetrievalHealth(
                    RetrievalHealthRecord(
                        subsystem: .projection,
                        status: .failed,
                        errorCode: "PROJECTION_RUNTIME_ERROR",
                        errorMessage: error.localizedDescription,
                        detailsJSON: nil,
                        observedAt: now,
                        updatedAt: now
                    )
                )
            } catch {
                AppLogger.search.silentFailure( // cov:ignore -- nonfatal-log
                    "projection_health_write_failed", // cov:ignore -- nonfatal-log
                    error: error, // cov:ignore -- nonfatal-log
                    context: ["subsystem": RetrievalSubsystem.projection.rawValue] // cov:ignore -- nonfatal-log
                ) // cov:ignore -- nonfatal-log
            }
            return false
        }
    }

    func requestProjectionSweep() {
        projectionWorkerWakeTask?.cancel()
        projectionWorkerWakeTask = nil
        projectionWorkerWakeAt = nil
        projectionSweepRequested = true
        guard projectionWorkerTask == nil else { return }

        projectionWorkerTask = Task(priority: .background) { [weak self] in
            await self?.runProjectionWorkerLoop()
        }
    }

    func runProjectionWorkerLoop() async {
        defer { projectionWorkerTask = nil }

        var continuousBacklogPasses = 0
        while !Task.isCancelled {
            guard projectionSweepRequested else { break }
            projectionSweepRequested = false

            let hasBacklog = await runProjectionSweep()
            if hasBacklog {
                continuousBacklogPasses += 1
                guard ProjectionWorkerPolicy.shouldContinueBacklogProcessing(
                    afterCompletedPasses: continuousBacklogPasses
                ) else {
                    projectionSweepRequested = false
                    break
                }
                projectionSweepRequested = true
                try? await Task.sleep(nanoseconds: ProjectionWorkerPolicy.backlogDelayNanoseconds) // try?-ok(cancellation only)
            } else if projectionSweepRequested {
                continuousBacklogPasses = 0
                try? await Task.sleep(nanoseconds: ProjectionWorkerPolicy.coalesceDelayNanoseconds) // try?-ok(cancellation only)
            } else {
                continuousBacklogPasses = 0
                await scheduleNextProjectionSweepIfNeeded()
            }
        }
    }

    func scheduleNextProjectionSweepIfNeeded() async {
        // try?-ok(lease probe is best-effort; a failed read skips this sweep, next projection request retries)
        guard let nextAvailableAt = try? await dataStore.nextProjectionJobLeaseOpportunity() else {
            return
        }
        let delay = nextAvailableAt.timeIntervalSinceNow
        guard delay > 0 else {
            projectionSweepRequested = true
            return
        }
        scheduleProjectionSweep(at: nextAvailableAt)
    }

    func scheduleProjectionSweep(at availableAt: Date) {
        if let projectionWorkerWakeAt, projectionWorkerWakeAt <= availableAt {
            return
        }

        projectionWorkerWakeTask?.cancel()
        projectionWorkerWakeAt = availableAt
        let delaySeconds = max(0, availableAt.timeIntervalSinceNow)
        let delayNanoseconds = UInt64(
            min(delaySeconds * 1_000_000_000, Double(UInt64.max))
        )
        projectionWorkerWakeTask = Task(priority: .background) { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, Task.isCancelled == false else { return }
            self.projectionWorkerWakeTask = nil
            self.projectionWorkerWakeAt = nil
            self.requestProjectionSweep()
        }
    }

    func shouldRefreshProjectionInsights(
        report: ProjectionSweepReport,
        hasBacklog: Bool
    ) -> Bool {
        guard report.completedJobs > 0 else { return false }
        if hasBacklog == false { return true }
        guard let lastProjectionInsightRefreshAt else { return true }
        return Date().timeIntervalSince(lastProjectionInsightRefreshAt) >= ProjectionWorkerPolicy.insightRefreshCooldown
    }

}
