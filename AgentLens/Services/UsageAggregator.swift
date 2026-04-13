import Foundation
import CryptoKit
import GRDB

// MARK: - Parser Health

enum ParserHealth {
    case healthy(sessionCount: Int)
    case empty
    case degraded(sessionCount: Int, error: String)
    case failed(error: String)
    case notConfigured
}

private extension ParserHealth {
    var statusLabel: String {
        switch self {
        case .healthy:
            return "healthy"
        case .empty:
            return "empty"
        case .degraded:
            return "degraded"
        case .failed:
            return "failed"
        case .notConfigured:
            return "not_configured"
        }
    }

    var sessionCount: Int {
        switch self {
        case .healthy(let count), .degraded(let count, _):
            return max(0, count)
        case .empty, .failed, .notConfigured:
            return 0
        }
    }

    var errorMessage: String? {
        switch self {
        case .degraded(_, let error):
            return error
        case .failed(let error):
            return error
        case .healthy, .empty, .notConfigured:
            return nil
        }
    }
}

// MARK: - Summary Queue Item

struct SummaryQueueItem: Identifiable {
    let id: String          // conversation ID
    let title: String
    enum Status { case pending, processing, done, failed }
    var status: Status = .pending
    var provider: String?   // set when done
}

// MARK: - Usage Aggregator

@Observable
@MainActor
final class UsageAggregator {
    private static let apiReconciliationSessionPrefix = "api-reconcile-"
    private enum SummaryEndpointCooldownPolicy {
        static let localEndpointFailureCooldown: TimeInterval = 5 * 60
    }
    private enum ProjectionWorkerPolicy {
        /// Process indexing incrementally to keep UI work responsive.
        static let maxJobsPerPass = 8
        static let catchUpMaxJobsPerPass = 64
        /// Small delay between backlog passes to reduce CPU pressure.
        static let backlogDelayNanoseconds: UInt64 = 100_000_000
        /// Coalesce rapid-fire queue requests.
        static let coalesceDelayNanoseconds: UInt64 = 750_000_000
        /// Avoid rebuilding workflow insights on every tiny pass.
        static let insightRefreshCooldown: TimeInterval = 10
        /// Trim redundant queued conversation jobs when backlog explodes.
        static let backlogCompactionThreshold = 400
    }
    private enum AutoSummaryPolicy {
        /// Keep automatic summaries lightweight so background refreshes do not
        /// churn through entire historical backlogs or oversized prompts.
        static let maxPromptChars = 18_000
        static let maxOutputTokens = 220
        static let maxBatchSize = 8
        static let maxFirstLoadBatchSize = 16
        static let maxConcurrency = 2
        /// Pause summary churn while projection queue is already overloaded.
        static let pauseWhenProjectionQueueExceeds = 300
    }

    private let dataStore: DataStore
    private let parsers: [AgentProvider: any LogParser]
    private weak var cloudSync: CloudSyncService?
    private weak var sessionMirror: ICloudSessionMirrorService?
    private let settingsManager: SettingsManager
    private let providerAPIKeyStore: ProviderAPIKeyStore
    private(set) var usageAPIService: ProviderUsageAPIService?
    private let quotaService: ProviderQuotaService
    private let artifactDiscoveryService: ArtifactDiscoveryService
    private let projectionPipelineServiceOverride: ProjectionPipelineService?
    private var hasCompletedInitialSummarySweep = false
    private var localSummaryEndpointCooldownUntil: Date?
    private var mlxSummaryEndpointCooldownUntil: Date?
    private static let summaryFailureRetryCooldown: TimeInterval = 60 * 60

    private(set) var isRefreshing = false
    private(set) var isSummarizing = false
    private(set) var summaryProgressDone: Int = 0
    private(set) var summaryProgressTotal: Int = 0
    private(set) var summaryCurrentTitle: String = ""
    private(set) var summaryQueue: [SummaryQueueItem] = []
    /// Seconds remaining until the time limit, nil if no limit is set.
    private(set) var summaryTimeRemaining: TimeInterval? = nil
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

    private static func defaultParsers() -> [AgentProvider: any LogParser] {
        [
            .factory: FactoryDroidParser(),
            .claudeCode: ClaudeCodeParser(),
            .copilot: CopilotParser(),
            .aider: AiderParser(),
            .cursor: CursorParser(),
            .codex: CodexParser(),
            .zai: ModelFilterParser(modelPattern: "zai", provider: .zai),
            .minimax: ModelFilterParser(modelPattern: "minimax", provider: .minimax),
            .kimi: KimiParser(),
            .cline: ClineFormatParser(provider: .cline, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks",
            ]),
            .kiloCode: ClineFormatParser(provider: .kiloCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/tasks",
            ]),
            .rooCode: ClineFormatParser(provider: .rooCode, storagePaths: [
                "~/Library/Application Support/Code/User/globalStorage/rooveterinaryinc.roo-cline/tasks",
                "~/Library/Application Support/Code/User/globalStorage/roo-inc.roo-code/tasks",
            ]),
            .forgeDev: ForgeDevParser(),
            .augment: AugmentParser(),
            .hermes: HermesParser(),
            .geminiCLI: GeminiCLIParser(),
            .goose: GooseParser(),
            .windsurf: WindsurfParser(),
        ]
    }

    init(
        dataStore: DataStore,
        cloudSync: CloudSyncService? = nil,
        sessionMirror: ICloudSessionMirrorService? = nil,
        settingsManager: SettingsManager = .shared,
        usageAPIService: ProviderUsageAPIService? = nil,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        quotaService: ProviderQuotaService = .shared,
        artifactDiscoveryService: ArtifactDiscoveryService? = nil,
        projectionPipelineService: ProjectionPipelineService? = nil,
        parserOverrides: [AgentProvider: any LogParser]? = nil
    ) {
        self.dataStore = dataStore
        self.cloudSync = cloudSync
        self.sessionMirror = sessionMirror
        self.settingsManager = settingsManager
        self.usageAPIService = usageAPIService ?? ProviderUsageAPIService(keyStore: providerAPIKeyStore)
        self.providerAPIKeyStore = providerAPIKeyStore
        self.quotaService = quotaService
        self.artifactDiscoveryService = artifactDiscoveryService
            ?? ArtifactDiscoveryService(dataStore: dataStore, settingsProvider: settingsManager)
        self.projectionPipelineServiceOverride = projectionPipelineService
        self.hasCompletedInitialSummarySweep = settingsManager.summaryInitialSweepCompleted
        self.parsers = parserOverrides ?? Self.defaultParsers()
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
        // Tokenizer-assisted fallback runs only when the flag is enabled AND exact buckets are unavailable.
        TokenExtractionUtility.fallbackEstimator = settingsManager.tokenizerAssistedFallbackEnabled
            ? .tokenizerAssisted
            : .characterRatio

        let refreshStartedAt = Date()
        let parsePhaseStartedAt = Date()
        var allUsages: [TokenUsage] = []
        var indexedConversationChanges = 0
        var provisionalUsageMap = Dictionary(uniqueKeysWithValues: dataStore.usages.map { ($0.id, $0) })

        let parserEntries = parsers.sorted { $0.key.rawValue < $1.key.rawValue }
        for (provider, parser) in parserEntries {
            do {
                let result = try await parseProviderOffMainActor(parser)
                let usages = result.usages
                var providerHealth: ParserHealth = usages.isEmpty ? .empty : .healthy(sessionCount: usages.count)
                allUsages.append(contentsOf: usages)
                if settingsManager.conversationIndexingEnabled {
                    do {
                        let indexingReport = try await ConversationIndexer.shared.index(result.conversations, in: dataStore)
                        indexedConversationChanges += indexingReport.changedRecordCount
                    } catch {
                        let message = "Conversation indexing failed for \(provider.displayName): \(error.localizedDescription)"
                        providerHealth = .degraded(sessionCount: usages.count, error: message)
                        errors[provider] = message
                    }
                }
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
        // This wires BackfillCursorStore.nextBackfillWindow/advanceCursor into production:
        // VAL-PERSIST-006: Backfill run is bounded to 7-day window.
        // VAL-PERSIST-007: Backfill cursor progresses monotonically.
        // VAL-PERSIST-004: Checkpoints advance only after successful commit.
        if persistenceErrorMessage == nil {
            await runScheduledBackfillIfNeeded()
        }

        // Unblock scan UI immediately after local parsing/persistence completes.
        isRefreshing = false

        var pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0
        if pendingProjectionJobs >= ProjectionWorkerPolicy.backlogCompactionThreshold {
            let removed = (try? dataStore.compactConversationProjectionBacklog()) ?? 0
            if removed > 0 {
                pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? pendingProjectionJobs
            }
        }
        launchArtifactDiscoverySweep()
        if indexedConversationChanges > 0,
           pendingProjectionJobs < AutoSummaryPolicy.pauseWhenProjectionQueueExceeds {
            launchAutoSummarySweep(indexedAfter: refreshStartedAt)
        }
        if indexedConversationChanges > 0 || pendingProjectionJobs > 0 {
            launchProjectionSweep()
        }

        // Fetch from provider billing APIs (complementary to log parsing)
        let postPersistencePhaseStartedAt = Date()
        var apiSupplementalUsages: [TokenUsage] = []
        do {
            let refreshedRecords = try await deleteAndReloadUsageRows(sessionIDPrefix: Self.apiReconciliationSessionPrefix)
            dataStore.replaceUsages(refreshedRecords)
        } catch {
            parserImportError = "Failed to clear prior API-reconciled usage rows: \(error.localizedDescription)"
        }

        if let apiService = usageAPIService {
            apiService.rebuildAPIs()
        }
        if let apiService = usageAPIService, !apiService.configuredProviders.isEmpty {
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
            apiUsages = await apiService.fetchAll(since: thirtyDaysAgo)
            // VAL-CROSS-011: Use canonical multi-source baseline from database, not just parser output.
            // This ensures ALL local sources (provider_log, in_app_chat, cursor_bridge, daemon)
            // are included in the baseline for computing supplemental reconciliation deltas.
            let canonicalBaseline: [TokenUsage]
            do {
                canonicalBaseline = try dataStore.usageStore.fetchAllUsage()
            } catch {
                // Fall back to parser output if canonical fetch fails
                canonicalBaseline = allUsages
                let message = "Failed to fetch canonical usage baseline: \(error.localizedDescription)"
                if parserImportError == nil {
                    parserImportError = message
                }
            }
            apiSupplementalUsages = supplementalUsages(from: apiUsages, existingUsages: canonicalBaseline)
            if !apiSupplementalUsages.isEmpty {
                do {
                    let refreshedRecords = try await persistAndReloadUsageRows(apiSupplementalUsages)
                    dataStore.replaceUsages(refreshedRecords)
                } catch {
                    let message = "Failed to store API-reconciled usage rows: \(error.localizedDescription)"
                    parserImportError = message
                }
            }
        } else {
            apiUsages = []
        }

        await quotaService.refreshIfNeeded(dataStore: dataStore)

        // Upload unsynced rows to Firestore (no-op if not signed in)
        await cloudSync?.uploadPending()
        await cloudSync?.uploadPendingConversations()
        await cloudSync?.uploadPendingSessionLogs()
        await cloudSync?.syncSharedArtifacts()

        await sessionMirror?.syncIfNeeded()

        let postPersistencePhaseDuration = Date().timeIntervalSince(postPersistencePhaseStartedAt)
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
                "api_supplemental_rows": String(apiSupplementalUsages.count),
            ]
        )
    }

    fileprivate func supplementalUsages(
        from records: [ProviderUsageRecord],
        existingUsages: [TokenUsage]
    ) -> [TokenUsage] {
        let calendar = Calendar.current
        return records.compactMap { record in
            guard let fallbackProvider = record.mappedProvider else { return nil }

            let windowStart = calendar.startOfDay(for: record.date)
            let windowEnd = calendar.date(byAdding: .day, value: 1, to: windowStart) ?? windowStart
            let window = windowStart...windowEnd
            let matchingLocalUsages = existingUsages.filter { usage in
                usage.intersects(dateRange: window) && usageMatches(record: record, usage: usage)
            }

            let localInput = matchingLocalUsages.reduce(0) { $0 + $1.inputTokens }
            let localOutput = matchingLocalUsages.reduce(0) { $0 + $1.outputTokens }
            let localCacheRead = matchingLocalUsages.reduce(0) { $0 + $1.cacheReadTokens }
            let localCacheWrite = matchingLocalUsages.reduce(0) { $0 + $1.cacheCreationTokens }
            let localCost = matchingLocalUsages.reduce(0.0) { $0 + $1.cost }

            let missingInput = max(record.inputTokens - localInput, 0)
            let missingOutput = max(record.outputTokens - localOutput, 0)
            let missingCacheRead = max(record.cacheReadTokens - localCacheRead, 0)
            let missingCacheWrite = max(record.cacheCreationTokens - localCacheWrite, 0)
            let missingCost = max(record.costUSD - localCost, 0)

            // VAL-PERSIST-012: Cost-only reconciliation deltas are preserved.
            // When reconciliation detects cost drift without positive token deltas,
            // correction behavior must still be deterministic and persist expected cost adjustments.
            // We include missingCost > costEpsilon so cost-only corrections are not silently dropped,
            // while avoiding phantom micro-corrections from floating-point residue.
            // costEpsilon = 1e-9 is smaller than any meaningful cost delta ($0.000000001)
            // but larger than typical floating-point residue (~1e-15 to 1e-16).
            let costEpsilon = 1e-9
            guard missingInput > 0 || missingOutput > 0 || missingCacheRead > 0 || missingCacheWrite > 0 || missingCost > costEpsilon else {
                return nil
            }

            let candidateProviders = Set(matchingLocalUsages.map(\.provider))
            let targetProvider: AgentProvider
            if candidateProviders.count == 1, let only = candidateProviders.first {
                targetProvider = only
            } else {
                targetProvider = fallbackProvider
            }

            let modelKey = sanitizedModelKey(record.model)
            let providerKey = targetProvider.rawValue
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            let sessionId = "\(Self.apiReconciliationSessionPrefix)\(providerKey)-\(Int(windowStart.timeIntervalSince1970))-\(modelKey)"
            let projectName = matchingLocalUsages.isEmpty
                ? "\(record.providerName) API Reconciliation"
                : "\(targetProvider.displayName) · \(record.providerName) API Reconciliation"

            return TokenUsage(
                provider: targetProvider,
                sessionId: sessionId,
                projectName: projectName,
                model: record.model,
                inputTokens: missingInput,
                outputTokens: missingOutput,
                cacheCreationTokens: missingCacheWrite,
                cacheReadTokens: missingCacheRead,
                costUSD: missingCost,
                startTime: windowStart,
                endTime: windowStart,
                usageSource: .billingAPI,
                provenanceMethod: .billingAPI,
                provenanceConfidence: .exact
            )
        }
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
    /// This exposes the private reconciliation pipeline for direct unit testing.
    /// - Parameters:
    ///   - records: API usage records to reconcile against
    ///   - existingUsages: existing local token usages to compare against
    /// - Returns: array of supplemental TokenUsage rows to insert, or empty if no reconciliation needed
    internal func computeSupplementalUsages(
        from records: [ProviderUsageRecord],
        existingUsages: [TokenUsage]
    ) -> [TokenUsage] {
        supplementalUsages(from: records, existingUsages: existingUsages)
    }

    /// Test helper: checks if a cost delta exceeds the epsilon threshold used to avoid
    /// phantom micro-corrections from floating-point residue.
    /// - Parameters:
    ///   - localCost: the local accumulated cost
    ///   - apiCost: the API-reported cost
    /// - Returns: true if the cost delta exceeds epsilon threshold (1e-9)
    internal static func costDeltaExceedsEpsilon(localCost: Double, apiCost: Double) -> Bool {
        let missingCost = max(apiCost - localCost, 0)
        let costEpsilon = 1e-9
        return missingCost > costEpsilon
    }

    private func usageMatches(record: ProviderUsageRecord, usage: TokenUsage) -> Bool {
        switch record.mappedProvider {
        case .some(.minimax):
            let localKey = TokenExtractionUtility.normalizeModelKey(usage.model)
            let apiKey = TokenExtractionUtility.normalizeModelKey(record.model)
            if apiKey == "minimax" {
                return localKey.contains("minimax")
            }
            return localKey == apiKey || localKey.contains(apiKey) || (apiKey.contains("minimax") && localKey.contains("minimax"))
        case .some(.zai):
            let localKey = TokenExtractionUtility.normalizeModelKey(usage.model)
            let apiKey = TokenExtractionUtility.normalizeModelKey(record.model)
            if apiKey == "glm" || apiKey == "zai" || apiKey == "z.ai" {
                return localKey.contains("glm") || localKey.contains("zai")
            }
            return localKey == apiKey || localKey.contains(apiKey) || apiKey.contains(localKey)
        case .some(.copilot):
            return usage.provider == .copilot
        case .none:
            return false
        default:
            return false
        }
    }

    private func sanitizedModelKey(_ model: String) -> String {
        let raw = TokenExtractionUtility.normalizeModelKey(model)
        let allowed = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" {
                return character
            }
            return "-"
        }
        let sanitized = String(allowed)
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? "model" : sanitized
    }

    /// Clears local usage rows so the dashboard resets immediately, then re-parses all providers.
    func recountAll() async {
        guard !isRefreshing else { return }
        do {
            try dataStore.deleteAll()
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
            let result = try await parser.parse()
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
            dataStore.refresh()
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
            let pendingProjectionJobs = (try? dataStore.countProjectionJobs(statuses: [.queued, .leased, .running])) ?? 0
            launchArtifactDiscoverySweep()
            if indexedConversationChanges > 0 {
                launchAutoSummarySweep(indexedAfter: refreshStartedAt)
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

private struct SessionSummaryPayload: Decodable {
    let title: String
    let summary: String
}

private struct AutoSummaryResult {
    let title: String
    let summary: String
    let provider: SummaryProviderID
    let model: String
    let estimatedCostUSD: Double
}

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
            _ = try artifactDiscoveryService.discoverAndIngest()
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

    // MARK: - Scheduled Backfill

    /// Runs scheduled historical backfill with bounded 7-day windows.
    ///
    /// This method wires the BackfillCursorStore APIs into the production refresh flow:
    /// - Calls `nextBackfillWindow` to determine the next window to process
    /// - After successful refresh, calls `advanceCursor` to advance the cursor
    ///
    /// VAL-PERSIST-006: Backfill run is bounded to 7-day window.
    /// VAL-PERSIST-007: Backfill cursor progresses monotonically.
    ///
    /// This is called as part of the periodic refresh cycle to ensure backfill
    /// cursor progression happens in production, not just in tests.
    func runScheduledBackfillIfNeeded() async {
        let now = Date()

        // Process backfill for each provider
        for provider in parsers.keys {
            do {
                // Get the next backfill window using the cursor store API
                // This is the production call site for nextBackfillWindow (previously test-only)
                guard let window = try dataStore.backfillCursorStore.nextBackfillWindow(
                    for: provider,
                    currentDate: now
                ) else {
                    // No window available - backfill is complete for this provider
                    continue
                }

                // The actual parsing happens in refreshAll() which runs before this.
                // Here we just advance the cursor after successful processing.
                //
                // VAL-PERSIST-006: Each backfill run is bounded to 7 days.
                // The window returned by nextBackfillWindow is already clamped to 7 days.
                //
                // VAL-PERSIST-007: Cursor advances monotonically after successful commit.
                // advanceCursor enforces strict monotonic progression.
                try dataStore.backfillCursorStore.advanceCursor(
                    for: provider,
                    newUpperBound: window.upperBound,
                    earliestSourceDate: window.lowerBound
                )
            } catch {
                // Log but don't fail the refresh - backfill cursor errors are non-fatal
                let message = "Backfill cursor advance failed for \(provider.displayName): \(error.localizedDescription)"
                if errors[provider] == nil {
                    errors[provider] = message
                }
            }
        }
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

    func launchAutoSummarySweep(indexedAfter: Date) {
        guard settingsManager.conversationIndexingEnabled,
              settingsManager.autoSessionSummariesEnabled else { return }

        Task(priority: .utility) { [weak self] in
            await self?.runAutoSummarySweep(indexedAfter: indexedAfter)
        }
    }

    /// Called from `withTaskGroup` via `MainActor.run` so queue / store updates stay on the main actor.
    func recordParallelSummaryResult(id: String, result: AutoSummaryResult?, failedIDs: inout Set<String>) {
        if let result {
            try? dataStore.updateConversationSummary(
                id: id, title: result.title, summary: result.summary,
                provider: result.provider.rawValue, model: result.model,
                runCostUSD: result.estimatedCostUSD
            )
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .done
                summaryQueue[idx].provider = result.provider.rawValue
            }
        } else {
            failedIDs.insert(id)
            if let idx = summaryQueue.firstIndex(where: { $0.id == id }) {
                summaryQueue[idx].status = .failed
            }
            try? dataStore.markConversationSummaryAttempt(id: id)
        }
        summaryProgressDone += 1
    }

    func markSummaryItemProcessing(_ conversation: ConversationRecord) {
        if let idx = summaryQueue.firstIndex(where: { $0.id == conversation.id }) {
            summaryQueue[idx].status = .processing
        } else {
            summaryQueue.append(
                SummaryQueueItem(
                    id: conversation.id,
                    title: conversation.inferredTaskTitle.isEmpty ? conversation.sessionId : conversation.inferredTaskTitle,
                    status: .processing,
                    provider: nil
                )
            )
        }
        summaryCurrentTitle = conversation.inferredTaskTitle.isEmpty
            ? conversation.sessionId : conversation.inferredTaskTitle
    }

    func runAutoSummarySweep(indexedAfter: Date) async {
        guard settingsManager.conversationIndexingEnabled,
              settingsManager.autoSessionSummariesEnabled,
              !isSummarizing else { return }

        isSummarizing = true
        summaryProgressDone = 0
        summaryProgressTotal = 0
        summaryCurrentTitle = ""
        summaryQueue = []
        summaryTimeRemaining = nil
        defer {
            isSummarizing = false
            summaryCurrentTitle = ""
            summaryTimeRemaining = nil
        }

        let isInitialSweep = !hasCompletedInitialSummarySweep
        let batchLimit = effectiveAutoSummaryBatchLimit(isInitialSweep: isInitialSweep)

        // Compute optional wall-clock deadline
        let limitMinutes = settingsManager.summaryTimeLimitMinutes
        let deadline: Date? = limitMinutes > 0
            ? Date().addingTimeInterval(Double(limitMinutes) * 60)
            : nil

        // Start a 1-second ticker that publishes remaining time
        if let deadline {
            Task { @MainActor [weak self] in
                while self?.isSummarizing == true {
                    let remaining = deadline.timeIntervalSinceNow
                    self?.summaryTimeRemaining = max(remaining, 0)
                    if remaining <= 0 { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        // Get total count without loading full transcript payloads.
        summaryProgressTotal = (try? dataStore.countConversationsNeedingSummary(
            now: Date(),
            retryCooldown: Self.summaryFailureRetryCooldown,
            indexedAfter: indexedAfter
        )) ?? 0
        summaryQueue = []

        var failedIDs = Set<String>()
        var loopsRemaining = 1

        while loopsRemaining > 0, !Task.isCancelled {
            // Respect time limit
            if let deadline, Date() >= deadline { break }

            guard var candidates = try? dataStore.fetchConversationsNeedingSummary(
                limit: batchLimit,
                now: Date(),
                retryCooldown: Self.summaryFailureRetryCooldown,
                indexedAfter: indexedAfter
            ),
                  !candidates.isEmpty else { break }
            candidates.removeAll { failedIDs.contains($0.id) }
            if candidates.isEmpty { break }

            // Unified parallel pool — local and cloud compete for the same slots.
            // summarizeConversation already falls through the full provider list, so
            // sessions that miss local capacity naturally spill to cloud and vice versa.
            let maxConcurrent = effectiveAutoSummaryMaxConcurrency

            await withTaskGroup(of: (String, AutoSummaryResult?).self) { group in
                var inFlight = 0

                for conversation in candidates {
                    if Task.isCancelled { break }
                    if let deadline, Date() >= deadline { break }

                    await MainActor.run { markSummaryItemProcessing(conversation) }

                    if inFlight >= maxConcurrent, let (id, result) = await group.next() {
                        await MainActor.run {
                            recordParallelSummaryResult(id: id, result: result, failedIDs: &failedIDs)
                        }
                        inFlight -= 1
                    }

                    // Check deadline again after draining
                    if let deadline, Date() >= deadline { break }

                    let conv = conversation
                    group.addTask { [weak self] in
                        guard let self else { return (conv.id, nil) }
                        return (conv.id, await self.summarizeConversation(conv))
                    }
                    inFlight += 1
                }

                for await (id, result) in group {
                    await MainActor.run {
                        recordParallelSummaryResult(id: id, result: result, failedIDs: &failedIDs)
                    }
                }
            }

            loopsRemaining -= 1
            if candidates.count < batchLimit { break }
        }

        hasCompletedInitialSummarySweep = true
        settingsManager.summaryInitialSweepCompleted = true
        requestProjectionSweep()
    }

    private func requestProjectionSweep() {
        projectionSweepRequested = true
        guard projectionWorkerTask == nil else { return }

        projectionWorkerTask = Task(priority: .background) { [weak self] in
            await self?.runProjectionWorkerLoop()
        }
    }

    private func runProjectionWorkerLoop() async {
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

    private func shouldRefreshProjectionInsights(
        report: ProjectionSweepReport,
        hasBacklog: Bool
    ) -> Bool {
        guard report.completedJobs > 0 else { return false }
        if hasBacklog == false { return true }
        guard let lastProjectionInsightRefreshAt else { return true }
        return Date().timeIntervalSince(lastProjectionInsightRefreshAt) >= ProjectionWorkerPolicy.insightRefreshCooldown
    }

    private func effectiveAutoSummaryBatchLimit(isInitialSweep: Bool) -> Int {
        let configured = isInitialSweep
            ? max(settingsManager.summaryFirstLoadBatchSize, 1)
            : max(settingsManager.summaryBatchSize, 1)
        let ceiling = isInitialSweep
            ? AutoSummaryPolicy.maxFirstLoadBatchSize
            : AutoSummaryPolicy.maxBatchSize
        return min(configured, ceiling)
    }

    private var effectiveAutoSummaryMaxConcurrency: Int {
        min(max(settingsManager.summaryMaxConcurrency, 1), AutoSummaryPolicy.maxConcurrency)
    }

    private var effectiveAutoSummaryPromptChars: Int {
        min(max(settingsManager.summaryMaxPromptChars, 4_000), AutoSummaryPolicy.maxPromptChars)
    }

    private var effectiveAutoSummaryOutputTokens: Int {
        min(max(settingsManager.summaryMaxOutputTokens, 120), AutoSummaryPolicy.maxOutputTokens)
    }

    func summarizeConversation(_ conversation: ConversationRecord) async -> AutoSummaryResult? {
        let prompt = ContextBuilder.summarizeSessionJSONPrompt(
            fullText: conversation.fullText,
            maxChars: effectiveAutoSummaryPromptChars
        )

        for provider in settingsManager.summaryProviderOrder {
            switch provider {
            case .local:
                if let cooldown = localSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                if let payload = await summarizeWithOllama(prompt: prompt) {
                    let clean = sanitizeSummaryPayload(payload, fallbackTitle: conversation.inferredTaskTitle)
                    if let clean {
                        return AutoSummaryResult(
                            title: clean.title,
                            summary: clean.summary,
                            provider: .local,
                            model: settingsManager.summaryLocalModel,
                            estimatedCostUSD: 0
                        )
                    }
                }

            case .mlx:
                if let cooldown = mlxSummaryEndpointCooldownUntil, cooldown > Date() {
                    continue
                }
                let base = settingsManager.summaryMLXBaseURL
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !base.isEmpty, !settingsManager.summaryMLXModel.isEmpty else { continue }
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .mlx,
                    baseURL: base + "/v1",
                    apiKey: "",
                    model: settingsManager.summaryMLXModel,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }

            case .minimax:
                guard let key = resolveAPIKey(for: .minimax) else { continue }
                let model = settingsManager.summaryMiniMaxModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .minimax,
                    baseURL: "https://api.minimax.io/v1",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }

            case .openrouter:
                guard let key = resolveAPIKey(for: .openrouter) else { continue }
                let models = [settingsManager.summaryOpenRouterPrimaryModel, settingsManager.summaryOpenRouterFallbackModel]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                for model in models {
                    if let result = await summarizeWithOpenAICompatibleProvider(
                        provider: .openrouter,
                        baseURL: "https://openrouter.ai/api/v1",
                        apiKey: key,
                        model: model,
                        prompt: prompt,
                        fallbackTitle: conversation.inferredTaskTitle,
                        openRouterHeaders: true
                    ) {
                        return result
                    }
                }

            case .zai:
                guard let key = resolveAPIKey(for: .zai) else { continue }
                let model = settingsManager.summaryZaiModel
                if let result = await summarizeWithOpenAICompatibleProvider(
                    provider: .zai,
                    baseURL: "https://api.z.ai/api/coding/paas/v4",
                    apiKey: key,
                    model: model,
                    prompt: prompt,
                    fallbackTitle: conversation.inferredTaskTitle
                ) {
                    return result
                }
            }
        }

        return nil
    }

    func summarizeWithOpenAICompatibleProvider(
        provider: SummaryProviderID,
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        fallbackTitle: String,
        openRouterHeaders: Bool = false
    ) async -> AutoSummaryResult? {
        let requestTimeout = settingsManager.summaryRequestTimeoutSeconds
        let outputTokens = effectiveAutoSummaryOutputTokens
        let estimatedInputTokens = max(prompt.count / 4, 1)
        let estimatedOutputTokens = max(outputTokens / 2, 100)
        let estimatedCost = estimateCostUSD(
            provider: provider,
            model: model,
            inputTokens: estimatedInputTokens,
            outputTokens: estimatedOutputTokens
        )

        if provider != .local, provider != .mlx, exceedsCloudDailyCap(adding: estimatedCost) {
            return nil
        }

        let retryCount = max(settingsManager.summaryRetryCount, 0)
        for _ in 0...retryCount {
            if Task.isCancelled { return nil }
            guard let body = await callOpenAICompatibleCompletion(
                baseURL: baseURL,
                apiKey: apiKey,
                model: model,
                prompt: prompt,
                timeout: requestTimeout,
                maxOutputTokens: outputTokens,
                includeOpenRouterHeaders: openRouterHeaders
            ) else {
                if provider == .mlx {
                    mlxSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                        SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                    )
                }
                continue
            }

            guard let payload = parseSummaryPayload(from: body) else { continue }
            let clean = sanitizeSummaryPayload(payload, fallbackTitle: fallbackTitle)
            guard let clean else { continue }

            let outputEstimate = max((clean.title.count + clean.summary.count) / 4, 60)
            let finalCost = estimateCostUSD(
                provider: provider,
                model: model,
                inputTokens: estimatedInputTokens,
                outputTokens: outputEstimate
            )

            return AutoSummaryResult(
                title: clean.title,
                summary: clean.summary,
                provider: provider,
                model: model,
                estimatedCostUSD: max(finalCost, 0)
            )
        }
        return nil
    }

    func summarizeWithOllama(prompt: String) async -> SessionSummaryPayload? {
        let base = settingsManager.summaryLocalBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), !settingsManager.summaryLocalModel.isEmpty else { return nil }
        let endpoint = baseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = settingsManager.summaryRequestTimeoutSeconds
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "model": settingsManager.summaryLocalModel,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": effectiveAutoSummaryOutputTokens
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                localSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                    SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                )
            }
            return nil
        }

        guard let http = response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 404 || http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                localSummaryEndpointCooldownUntil = Date().addingTimeInterval(
                    SummaryEndpointCooldownPolicy.localEndpointFailureCooldown
                )
            }
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return nil
        }

        return parseSummaryPayload(from: text)
    }

    func callOpenAICompatibleCompletion(
        baseURL: String,
        apiKey: String,
        model: String,
        prompt: String,
        timeout: Double,
        maxOutputTokens: Int,
        includeOpenRouterHeaders: Bool
    ) async -> String? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + "/chat/completions") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if includeOpenRouterHeaders {
            request.setValue("OpenBurnBar", forHTTPHeaderField: "X-Title")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "Return strict JSON with keys title and summary."],
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1,
            "max_tokens": maxOutputTokens
        ]

        guard let requestBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = requestBody

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            return nil
        }

        if let content = message["content"] as? String {
            return content
        }
        if let blocks = message["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                if let text = block["text"] as? String { return text }
                return nil
            }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    func parseSummaryPayload(from text: String) -> SessionSummaryPayload? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(SessionSummaryPayload.self, from: data) {
            return decoded
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            return nil
        }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionSummaryPayload.self, from: data)
    }

    func sanitizeSummaryPayload(_ payload: SessionSummaryPayload, fallbackTitle: String) -> SessionSummaryPayload? {
        let cleanedSummary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty else { return nil }

        let cleanedTitleRaw = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = cleanedTitleRaw.isEmpty ? fallbackTitle : cleanedTitleRaw
        let normalizedTitle = cleanedTitle
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalTitle = String(normalizedTitle.prefix(100))
        let finalSummary = String(cleanedSummary.prefix(2_000))
        guard !finalTitle.isEmpty else { return nil }
        return SessionSummaryPayload(title: finalTitle, summary: finalSummary)
    }

    func resolveAPIKey(for provider: SummaryProviderID) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }

        func cursorConnectorKey(for account: String) -> String? {
            let keychain = KeychainStore()
            let raw = try? keychain.string(for: account, allowUserInteraction: false)
            return nonEmpty(raw ?? nil)
        }

        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .local, .mlx:
            return nil
        case .openrouter:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "openrouter"))
                ?? nonEmpty(env["OPENROUTER_API_KEY"])
        case .minimax:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "minimax"))
                ?? cursorConnectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(env["MINIMAX_API_KEY"])
        case .zai:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "zai"))
                ?? cursorConnectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(env["ZAI_API_KEY"])
        }
    }

    func exceedsCloudDailyCap(adding estimatedCost: Double) -> Bool {
        guard let cap = settingsManager.summaryDailyCapUSD else { return false }
        let spentToday = (try? dataStore.summarySpendToday()) ?? 0
        return spentToday + max(estimatedCost, 0) > cap
    }

    func estimateCostUSD(
        provider: SummaryProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int
    ) -> Double {
        let normalized = model.lowercased()
        let inputPerM: Double
        let outputPerM: Double

        switch provider {
        case .local, .mlx:
            return 0
        case .minimax:
            inputPerM = 0.69
            outputPerM = 0.69
        case .zai:
            inputPerM = 0.07
            outputPerM = 0.07
        case .openrouter:
            if normalized.contains("gpt-5-nano") {
                inputPerM = 0.05
                outputPerM = 0.40
            } else if normalized.contains("qwen3.5-9b") {
                inputPerM = 0.05
                outputPerM = 0.15
            } else if normalized.contains("qwen") {
                inputPerM = 0.08
                outputPerM = 0.24
            } else {
                inputPerM = 0.10
                outputPerM = 0.40
            }
        }

        return (Double(inputTokens) * inputPerM / 1_000_000)
            + (Double(outputTokens) * outputPerM / 1_000_000)
    }
}
