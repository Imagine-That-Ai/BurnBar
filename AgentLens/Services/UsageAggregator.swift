import Foundation
import GRDB

// MARK: - Usage Aggregator

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
        // Wire the projection-sweep callback so the summary engine can
        // request a projection sweep without a circular reference.
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

        // Data retention: purge expired rows once per launch.
        await refreshOrchestrator.runRetentionPurgeIfNeeded()

        let refreshStartedAt = Date()
        let parsePhaseStartedAt = Date()
        var allUsages: [TokenUsage] = []
        var allConversations: [ConversationRecord] = []
        var provisionalUsageMap = Dictionary(uniqueKeysWithValues: dataStore.usages.map { ($0.id, $0) })

        let parserEntries = parsers.sorted { $0.key.rawValue < $1.key.rawValue }
        for (provider, parser) in parserEntries {
            do {
                let result = try await parseProviderOffMainActor(parser)
                let usages = result.usages
                var providerHealth: ParserHealth = usages.isEmpty ? .empty : .healthy(sessionCount: usages.count)
                allUsages.append(contentsOf: usages)
                allConversations.append(contentsOf: result.conversations)
                parserHealth[provider] = providerHealth
                if usages.isEmpty == false {
                    for usage in usages {
                        provisionalUsageMap[usage.id] = usage
                    }
                    dataStore.replaceUsages(Array(provisionalUsageMap.values))
                    lastRefresh = Date()
                }
            } catch {
                parserHealth[provider] = .failed(error: error.localizedDescription)
                errors[provider] = error.localizedDescription
            }
        }
        let parsePhaseDuration = Date().timeIntervalSince(parsePhaseStartedAt)

        // Index conversations off the main thread after parsing completes.
        let indexedConversationChanges = await refreshOrchestrator.indexConversations(allConversations)

        // Store all usages and reload from SQLite so the in-memory array
        // includes both parser output and any chat-inserted rows.
        let persistencePhaseStartedAt = Date()
        do {
            let refreshedRecords = try await persistAndReloadUsageRows(allUsages)
            dataStore.replaceUsages(refreshedRecords)
            lastRefresh = Date()
        } catch {
            let message = "Failed to store imported usage rows: \(error.localizedDescription)"
            parserImportError = message
            persistenceErrorMessage = message
        }
        let persistencePhaseDuration = Date().timeIntervalSince(persistencePhaseStartedAt)

        do {
            try upsertParserImportHealth(importedUsageCount: allUsages.count, persistenceError: persistenceErrorMessage)
        } catch {
            parserImportError = "Failed to persist parser/import health: \(error.localizedDescription)"
        }

        // Advance backfill cursors only after successful persistence.
        // VAL-PERSIST-006 / VAL-PERSIST-007 / VAL-PERSIST-004
        if persistenceErrorMessage == nil {
            await refreshOrchestrator.runScheduledBackfillIfNeeded(parsers: parsers)
        }

        // Unblock scan UI immediately after local parsing/persistence completes.
        isRefreshing = false

        // Post-persistence phase runs off the main thread.
        let postResult = await refreshOrchestrator.runPostPersistencePhase(
            refreshStartedAt: refreshStartedAt,
            allUsages: allUsages,
            indexedConversationChanges: indexedConversationChanges,
            parsePhaseDuration: parsePhaseDuration,
            persistencePhaseDuration: persistencePhaseDuration
        )

        if let refreshedRecords = postResult.refreshedRecords {
            dataStore.replaceUsages(refreshedRecords)
            lastRefresh = Date()
        }

        apiUsages = postResult.apiUsages
        if let error = postResult.parserImportError, parserImportError == nil {
            parserImportError = error
        }

        let pendingProjectionJobs = postResult.pendingProjectionJobs
        launchArtifactDiscoverySweep()
        if indexedConversationChanges > 0,
           pendingProjectionJobs < AutoSummaryPolicy.pauseWhenProjectionQueueExceeds {
            summaryEngine.launchAutoSummarySweep(indexedAfter: refreshStartedAt)
        }
        if indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
            launchProjectionSweep()
        }

        let postPersistencePhaseDuration = postResult.postPersistencePhaseDuration
        let totalDuration = Date().timeIntervalSince(refreshStartedAt)
        AppLogger.parser.info(
            "usage_refresh_timing",
            metadata: [
                "parse_ms": Self.formatMilliseconds(parsePhaseDuration),
                "persist_ms": Self.formatMilliseconds(persistencePhaseDuration),
                "post_persist_ms": Self.formatMilliseconds(postPersistencePhaseDuration),
                "total_ms": Self.formatMilliseconds(totalDuration),
                "providers_scanned": String(parserEntries.count),
                "usage_rows": String(allUsages.count),
                "indexed_changes": String(indexedConversationChanges),
                "api_supplemental_rows": String(postResult.supplementalUsageCount),
            ]
        )
    }

    private func parseProviderOffMainActor(_ parser: any LogParser) async throws -> ParseResult {
        try await Task.detached(priority: .utility) {
            try await parser.parse()
        }.value
    }

    private func persistAndReloadUsageRows(_ usages: [TokenUsage]) async throws -> [TokenUsage] {
        guard usages.isEmpty == false else {
            return try await reloadUsageRows()
        }
        let usageStore = dataStore.usageStore
        return try await Task.detached(priority: .utility) {
            try usageStore.insert(usages)
            return try usageStore.fetchAllUsage()
        }.value
    }

    private func deleteAndReloadUsageRows(sessionIDPrefix: String) async throws -> [TokenUsage] {
        let usageStore = dataStore.usageStore
        return try await Task.detached(priority: .utility) {
            try usageStore.deleteUsage(sessionIDPrefix: sessionIDPrefix)
            return try usageStore.fetchAllUsage()
        }.value
    }

    private func reloadUsageRows() async throws -> [TokenUsage] {
        let usageStore = dataStore.usageStore
        return try await Task.detached(priority: .utility) {
            try usageStore.fetchAllUsage()
        }.value
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

        let refreshStartedAt = Date()
        var indexedConversationChanges = 0

        do {
            let result = try await Task.detached(priority: .utility) {
                try await parser.parse()
            }.value
            var providerHealth: ParserHealth = result.usages.isEmpty ? .empty : .healthy(sessionCount: result.usages.count)
            try dataStore.insert(result.usages)
            if settingsManager.conversationIndexingEnabled {
                do {
                    let indexingReport = try await ConversationIndexer.shared.index(result.conversations, in: dataStore)
                    indexedConversationChanges += indexingReport.changedRecordCount
                } catch {
                    let message = "Conversation indexing failed for \(provider.displayName): \(error.localizedDescription)"
                    providerHealth = .degraded(sessionCount: result.usages.count, error: message)
                    errors[provider] = message
                }
            }
            parserHealth[provider] = providerHealth
            await dataStore.refresh()
            switch providerHealth {
            case .degraded:
                break
            default:
                errors.removeValue(forKey: provider)
            }
            do {
                try upsertParserImportHealth(importedUsageCount: result.usages.count, persistenceError: nil)
            } catch {
                parserImportError = "Failed to persist parser/import health: \(error.localizedDescription)"
            }
            // Category B: If job count fails, 0 is a safe fallback.
            let pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0
            launchArtifactDiscoverySweep()
            if indexedConversationChanges > 0 {
                summaryEngine.launchAutoSummarySweep(indexedAfter: refreshStartedAt)
            }
            if indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
                launchProjectionSweep()
            }
            if ProviderQuotaService.supportedProviders.contains(provider) {
                await quotaService.refresh(provider: provider, dataStore: dataStore)
            }
        } catch {
            parserHealth[provider] = .failed(error: error.localizedDescription)
            errors[provider] = error.localizedDescription
            let message = "Provider refresh failed for \(provider.displayName): \(error.localizedDescription)"
            parserImportError = message
            do {
                try upsertParserImportHealth(importedUsageCount: 0, persistenceError: message)
            } catch {
                parserImportError = "Failed to persist parser/import health: \(error.localizedDescription)"
            }
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
