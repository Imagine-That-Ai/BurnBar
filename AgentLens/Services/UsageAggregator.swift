import Foundation
import GRDB

// MARK: - Usage Aggregator

/// Thin `@MainActor @Observable` facade that coordinates the refresh pipeline.
///
/// Heavy work (parsing 12+ providers, DB persistence, quota API calls,
/// conversation indexing, cloud sync) runs off the main thread via
/// `RefreshBackgroundWork` inside `Task.detached`.  This type only touches
/// observable state on the main actor: setting `isRefreshing`, applying
/// results to `DataStore`, and launching post-refresh side-effects.
@Observable
@MainActor
final class UsageAggregator {
    private let dataStore: DataStore
    private let parsers: [AgentProvider: any LogParser]
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
    /// Usage records fetched from provider billing APIs (separate from log-parsed data).
    private(set) var apiUsages: [ProviderUsageRecord] = []
    private var projectionWorkerTask: Task<Void, Never>?
    private var projectionSweepRequested = false
    private var lastProjectionInsightRefreshAt: Date?

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
        parserOverrides: [AgentProvider: any LogParser]? = nil,
        summaryEngine: AutoSummaryEngine? = nil
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
            ?? ArtifactDiscoveryService(dataStoreActor: dataStore.actor, settingsProvider: settingsManager)
        self.projectionPipelineServiceOverride = projectionPipelineService
        self.parsers = parserOverrides ?? ParserRegistry.defaultParsers()
        self.refreshOrchestrator = RefreshOrchestrator(
            dataStore: dataStore,
            settingsManager: settingsManager,
            cloudSyncCoordinator: cloudSyncCoordinator,
            cloudSync: cloudSync,
            sessionMirror: sessionMirror,
            quotaService: quotaService,
            usageAPIService: usageAPIService
        )
        self.summaryEngine = summaryEngine ?? AutoSummaryEngine(
            dataStore: dataStore,
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )
        self.summaryEngine.onRequestProjectionSweep = { [weak self] in
            self?.requestProjectionSweep()
        }
    }

    // MARK: - Refresh All

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errors = [:]
        parserImportError = nil
        parserHealth = [:]
        persistenceErrorMessage = nil

        // VAL-TOKEN-008: Set fallback estimator based on user flag before parsing.
        TokenExtractionUtility.fallbackEstimator = settingsManager.tokenizerAssistedFallbackEnabled
            ? .tokenizerAssisted
            : .characterRatio

        // Snapshot @MainActor state before entering background.
        let existingUsages = dataStore.usages
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
        let result = await Task.detached(priority: .utility) {
            await RefreshBackgroundWork.runFullRefresh(
                parsers: parsers,
                dataStore: dataStore,
                orchestrator: orchestrator,
                existingUsages: existingUsages,
                settings: settings
            )
        }.value

        // ── Apply results back on @MainActor ─────────────────────────
        parserHealth = result.parserHealth
        errors = result.errors

        // Reload from DB so in-memory array is canonical.
        if let refreshed = result.postPersistence.refreshedRecords {
            dataStore.replaceUsages(refreshed)
        } else {
            await dataStore.refresh()
        }
        lastRefresh = Date()

        persistenceErrorMessage = result.persistenceErrorMessage
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
            ]
        )
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
        do {
            try await dataStore.deleteAll()
        } catch {
            let message = "Failed to clear usage rows before recount: \(error.localizedDescription)"
            parserImportError = message
            do {
                try upsertParserImportHealth(importedUsageCount: 0, persistenceError: message)
            } catch {
                parserImportError = "Failed to persist parser/import health: \(error.localizedDescription)"
            }
        }
        await refreshAll()
    }

    // MARK: - Refresh Single Provider

    func refresh(provider: AgentProvider) async {
        guard let parser = parsers[provider] else { return }

        // VAL-TOKEN-008: Set fallback estimator based on user flag before parsing.
        TokenExtractionUtility.fallbackEstimator = settingsManager.tokenizerAssistedFallbackEnabled
            ? .tokenizerAssisted
            : .characterRatio

        // Snapshot @MainActor state before entering background.
        let settings = RefreshSettingsSnapshot(
            conversationIndexingEnabled: settingsManager.conversationIndexingEnabled,
            snapshotAPIs: usageAPIService?.snapshotAPIs() ?? []
        )
        let dataStore = self.dataStore

        let refreshStartedAt = Date()

        // ── Heavy work runs entirely off the main thread ─────────────
        let result = await Task.detached(priority: .utility) {
            await RefreshBackgroundWork.runSingleProviderRefresh(
                provider: provider,
                parser: parser,
                dataStore: dataStore,
                settings: settings
            )
        }.value

        // ── Apply results back on @MainActor ─────────────────────────
        parserHealth[provider] = result.health

        if let error = result.error {
            errors[provider] = error
            parserImportError = error
        } else {
            errors.removeValue(forKey: provider)
        }

        await dataStore.refresh()

        do {
            try upsertParserImportHealth(
                importedUsageCount: result.usages.count,
                persistenceError: result.error
            )
        } catch {
            parserImportError = "Failed to persist parser/import health: \(error.localizedDescription)"
        }

        let pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0
        launchArtifactDiscoverySweep()
        if result.indexedConversationChanges > 0 {
            summaryEngine.launchAutoSummarySweep(indexedAfter: refreshStartedAt)
        }
        if result.indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
            launchProjectionSweep()
        }
        if ProviderQuotaService.supportedProviders.contains(provider) {
            await quotaService.refresh(provider: provider, dataStore: dataStore)
        }
    }
}

// MARK: - Private Helpers

private extension UsageAggregator {
    func upsertParserImportHealth(importedUsageCount: Int, persistenceError: String?) throws {
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
        try dataStore.upsertRetrievalHealth(
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
                try dataStore.upsertRetrievalHealth(
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
                // Keep refresh flow alive; retrieval health write failures are non-fatal here.
            }
        }
        requestProjectionSweep()
    }


    @discardableResult
    func runProjectionSweep() async -> Bool {
        do {
            let queueDepthBeforeSweep = try dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])
            let maxJobs = queueDepthBeforeSweep >= ProjectionWorkerPolicy.backlogCompactionThreshold
                ? ProjectionWorkerPolicy.catchUpMaxJobsPerPass
                : ProjectionWorkerPolicy.maxJobsPerPass
            let report = try await makeProjectionPipelineService().runSweep(
                maxJobs: maxJobs
            )
            let queueDepth = try dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])
            let hasBacklog = queueDepth > 0 || report.leasedJobs >= maxJobs

            if shouldRefreshProjectionInsights(report: report, hasBacklog: hasBacklog) {
                _ = WorkflowInsightRollupService(dataStore: dataStore).snapshot(refreshIfStale: true)
                lastProjectionInsightRefreshAt = Date()
            }
            return hasBacklog
        } catch {
            let now = Date()
            do {
                try dataStore.upsertRetrievalHealth(
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
                // Keep refresh flow alive; health write failures are non-fatal here.
            }
            return false
        }
    }

    func requestProjectionSweep() {
        projectionSweepRequested = true
        guard projectionWorkerTask == nil else { return }

        projectionWorkerTask = Task(priority: .background) { [weak self] in
            await self?.runProjectionWorkerLoop()
        }
    }

    func runProjectionWorkerLoop() async {
        defer { projectionWorkerTask = nil }

        while !Task.isCancelled {
            guard projectionSweepRequested else { break }
            projectionSweepRequested = false

            let hasBacklog = await runProjectionSweep()
            if hasBacklog {
                projectionSweepRequested = true
                try? await Task.sleep(nanoseconds: ProjectionWorkerPolicy.backlogDelayNanoseconds)
            } else if projectionSweepRequested {
                try? await Task.sleep(nanoseconds: ProjectionWorkerPolicy.coalesceDelayNanoseconds)
            }
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
