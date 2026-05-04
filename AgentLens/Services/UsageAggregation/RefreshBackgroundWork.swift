import Foundation
import GRDB

// MARK: - Refresh Result Types

/// Value type returned by the off-main refresh work.  Carries all the data
/// the `@MainActor UsageAggregator` needs to update its observable state in
/// one atomic step — no incremental main-actor mutations during the heavy work.
struct FullRefreshResult: Sendable {
    var parserHealth: [AgentProvider: ParserHealth] = [:]
    var errors: [AgentProvider: String] = [:]
    var allUsages: [TokenUsage] = []
    var persistenceErrorMessage: String?
    var healthWriteError: String?
    var parsePhaseDuration: TimeInterval = 0
    var persistencePhaseDuration: TimeInterval = 0
    var indexedConversationChanges: Int = 0
    var postPersistence: PostPersistenceResult
}

struct SingleProviderResult: Sendable {
    var usages: [TokenUsage] = []
    var conversations: [ConversationRecord] = []
    var health: ParserHealth = .empty
    var indexedConversationChanges: Int = 0
    var error: String?
}

// MARK: - Refresh Background Work

/// Stateless namespace for off-main-thread refresh work.
///
/// `UsageAggregator` snapshots any `@MainActor` state it needs (settings,
/// API configs) *before* calling into these functions from a `Task.detached`.
/// The functions run entirely off the main actor and return value types that
/// the aggregator applies back on `@MainActor` in one step.
enum RefreshBackgroundWork {

    // MARK: - Full Refresh

    /// Runs the full parse → persist → post-persistence pipeline off the
    /// main thread.  Call from `Task.detached` and `await` the result.
    static func runFullRefresh(
        parsers: [AgentProvider: any LogParser],
        dataStore: DataStore,
        orchestrator: RefreshOrchestrator,
        existingUsages: [TokenUsage],
        settings: RefreshSettingsSnapshot
    ) async -> FullRefreshResult {
        var result = FullRefreshResult(
            postPersistence: PostPersistenceResult()
        )

        // ── Parse Phase ──────────────────────────────────────────────
        let parsePhaseStartedAt = Date()
        var allUsages: [TokenUsage] = []
        var allConversations: [ConversationRecord] = []
        var provisionalUsageMap = Dictionary(uniqueKeysWithValues: existingUsages.map { ($0.id, $0) })

        let parserEntries = parsers.sorted { $0.key.rawValue < $1.key.rawValue }
        for (provider, parser) in parserEntries {
            do {
                let parseResult = try await parser.parse()
                let usages = parseResult.usages
                let providerHealth: ParserHealth = usages.isEmpty
                    ? .empty
                    : .healthy(sessionCount: usages.count)
                allUsages.append(contentsOf: usages)
                allConversations.append(contentsOf: parseResult.conversations)
                result.parserHealth[provider] = providerHealth

                if !usages.isEmpty {
                    for usage in usages {
                        provisionalUsageMap[usage.id] = usage
                    }
                }
            } catch {
                result.parserHealth[provider] = .failed(error: error.localizedDescription)
                result.errors[provider] = error.localizedDescription
            }
        }
        result.allUsages = allUsages
        result.parsePhaseDuration = Date().timeIntervalSince(parsePhaseStartedAt)

        // ── Index Conversations ──────────────────────────────────────
        result.indexedConversationChanges = await orchestrator.indexConversationsOffMain(
            allConversations,
            indexingEnabled: settings.conversationIndexingEnabled
        )

        // ── Persistence Phase ────────────────────────────────────────
        let persistencePhaseStartedAt = Date()
        do {
            if allUsages.isEmpty {
                _ = try dataStore.usageStore.fetchAllUsage()
            } else {
                try dataStore.usageStore.insert(allUsages)
                _ = try dataStore.usageStore.fetchAllUsage()
            }
        } catch {
            let message = "Failed to store imported usage rows: \(error.localizedDescription)"
            result.persistenceErrorMessage = message
        }
        result.persistencePhaseDuration = Date().timeIntervalSince(persistencePhaseStartedAt)

        // ── Parser Health Persistence ────────────────────────────────
        do {
            try Self.writeParserImportHealth(
                parserHealth: result.parserHealth,
                parsers: parsers,
                dataStore: dataStore,
                importedUsageCount: allUsages.count,
                persistenceError: result.persistenceErrorMessage,
                conversationIndexingEnabled: settings.conversationIndexingEnabled
            )
        } catch {
            result.healthWriteError = "Failed to persist parser/import health: \(error.localizedDescription)"
        }

        // ── Backfill ─────────────────────────────────────────────────
        if result.persistenceErrorMessage == nil {
            await orchestrator.runScheduledBackfillIfNeeded(parsers: parsers)
        }

        // ── Post-Persistence Phase ───────────────────────────────────
        result.postPersistence = await orchestrator.runPostPersistencePhaseOffMain(
            allUsages: allUsages,
            snapshotAPIs: settings.snapshotAPIs
        )

        return result
    }

    // MARK: - Single Provider Refresh

    static func runSingleProviderRefresh(
        provider: AgentProvider,
        parser: any LogParser,
        dataStore: DataStore,
        settings: RefreshSettingsSnapshot
    ) async -> SingleProviderResult {
        var result = SingleProviderResult()

        do {
            let parseResult = try await parser.parse()
            result.usages = parseResult.usages
            result.conversations = parseResult.conversations
            result.health = parseResult.usages.isEmpty
                ? .empty
                : .healthy(sessionCount: parseResult.usages.count)

            try dataStore.insert(parseResult.usages)

            if settings.conversationIndexingEnabled {
                do {
                    let report = try await ConversationIndexer.shared.index(
                        parseResult.conversations, in: dataStore
                    )
                    result.indexedConversationChanges = report.changedRecordCount
                } catch {
                    let message = "Conversation indexing failed for \(provider.displayName): \(error.localizedDescription)"
                    result.health = .degraded(sessionCount: parseResult.usages.count, error: message)
                    result.error = message
                }
            }
        } catch {
            result.health = .failed(error: error.localizedDescription)
            result.error = "Provider refresh failed for \(provider.displayName): \(error.localizedDescription)"
        }

        return result
    }

    // MARK: - Health Persistence

    /// Writes a `RetrievalHealthRecord` summarising parser import status.
    /// All DB access goes through `nonisolated` `DataStore` extensions,
    /// so this is safe to call from any executor.
    static func writeParserImportHealth(
        parserHealth: [AgentProvider: ParserHealth],
        parsers: [AgentProvider: any LogParser],
        dataStore: DataStore,
        importedUsageCount: Int,
        persistenceError: String?,
        conversationIndexingEnabled: Bool
    ) throws {
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

        if let persistenceError, !persistenceError.isEmpty {
            status = .failed
            errorCode = "PARSER_IMPORT_PERSISTENCE_FAILED"
            errorMessage = persistenceError
        } else if failedCount > 0, failedCount == providerStates.count {
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
            conversationIndexingEnabled: conversationIndexingEnabled,
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
    }
}

// MARK: - Settings Snapshot

/// A `Sendable` snapshot of all settings and pre-built API instances needed
/// by `RefreshBackgroundWork`.  Built on `@MainActor` *before* entering the
/// background context so no main-actor hops are required during heavy work.
struct RefreshSettingsSnapshot: Sendable {
    var conversationIndexingEnabled: Bool
    var snapshotAPIs: [any ProviderUsageAPI]
}
