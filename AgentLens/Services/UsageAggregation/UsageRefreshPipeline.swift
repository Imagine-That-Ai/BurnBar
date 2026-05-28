import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Usage Refresh Pipeline Stages

/// Explicit refresh pipeline: discover → parse → reconcile → persist.
///
/// `RefreshBackgroundWork` delegates to these stages so timing and failure
/// boundaries stay visible without rewriting the orchestrator graph.
struct UsageRefreshPipeline: Sendable {
    let parsers: [AgentProvider: any LogParser]
    let dataStore: DataStore
    let orchestrator: RefreshOrchestrator
    let existingUsages: [TokenUsage]
    let settings: RefreshSettingsSnapshot

    struct DiscoverResult: Sendable {
        var parserEntries: [(AgentProvider, any LogParser)] = []
    }

    struct ParsedBatch: Sendable {
        var parserHealth: [AgentProvider: ParserHealth] = [:]
        var errors: [AgentProvider: String] = [:]
        var allUsages: [TokenUsage] = []
        var allConversations: [ConversationRecord] = []
        var duration: TimeInterval = 0
    }

    struct ReconcileResult: Sendable {
        var indexedConversationChanges: Int = 0
    }

    struct PersistResult: Sendable {
        var persistenceErrorMessage: String?
        var typedPersistenceError: OpenBurnBarError?
        var healthWriteError: String?
        var duration: TimeInterval = 0
    }

    func discover() -> DiscoverResult {
        var result = DiscoverResult()
        result.parserEntries = parsers.sorted { $0.key.rawValue < $1.key.rawValue }
        return result
    }

    func parse(from discovery: DiscoverResult) async -> ParsedBatch {
        var result = ParsedBatch()
        let startedAt = Date()

        for (provider, parser) in discovery.parserEntries {
            do {
                let parseResult = try await parser.parse()
                let usages = parseResult.usages
                let providerHealth: ParserHealth = usages.isEmpty
                    ? .empty
                    : .healthy(sessionCount: usages.count)
                result.allUsages.append(contentsOf: usages)
                if settings.conversationIndexingEnabled {
                    result.allConversations.append(contentsOf: parseResult.conversations)
                }
                result.parserHealth[provider] = providerHealth
            } catch {
                let typed = OpenBurnBarError.parse(
                    "provider_parse_failed",
                    message: error.localizedDescription,
                    underlying: error
                )
                result.parserHealth[provider] = .failed(error: typed.message)
                result.errors[provider] = typed.message
            }
        }

        result.duration = Date().timeIntervalSince(startedAt)
        return result
    }

    func reconcile(parsed: ParsedBatch) async -> ReconcileResult {
        var result = ReconcileResult()
        result.indexedConversationChanges = await orchestrator.indexConversationsOffMain(
            parsed.allConversations,
            indexingEnabled: settings.conversationIndexingEnabled
        )
        return result
    }

    func persist(parsed: ParsedBatch) -> PersistResult {
        var result = PersistResult()
        let startedAt = Date()

        do {
            if !parsed.allUsages.isEmpty {
                try dataStore.usageStore.insertChunked(parsed.allUsages, chunkSize: 500)
            }
        } catch {
            let typed = OpenBurnBarError.database(
                "usage_persist_failed",
                message: "Failed to store imported usage rows.",
                underlying: error
            )
            result.persistenceErrorMessage = typed.message
            result.typedPersistenceError = typed
        }

        result.duration = Date().timeIntervalSince(startedAt)
        return result
    }

    func writeParserHealth(
        parsed: ParsedBatch,
        persist: PersistResult
    ) throws {
        try RefreshBackgroundWork.writeParserImportHealth(
            parserHealth: parsed.parserHealth,
            parsers: parsers,
            dataStore: dataStore,
            importedUsageCount: parsed.allUsages.count,
            persistenceError: persist.persistenceErrorMessage,
            conversationIndexingEnabled: settings.conversationIndexingEnabled
        )
    }
}
