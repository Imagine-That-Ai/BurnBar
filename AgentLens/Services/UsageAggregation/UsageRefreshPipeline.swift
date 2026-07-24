import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Usage Refresh Pipeline Stages

/// Explicit refresh pipeline: discover → parse → reconcile → persist.
///
/// `RefreshBackgroundWork` delegates to these stages so timing and failure
/// boundaries stay visible without rewriting the orchestrator graph.
struct UsageRefreshPipeline: Sendable {
    let parsers: [AgentProvider: any OpenBurnBarCore.LogParser]
    let dataStore: DataStore
    let orchestrator: RefreshOrchestrator
    let existingUsages: [TokenUsage]
    let settings: RefreshSettingsSnapshot

    struct DiscoverResult: Sendable {
        var parserEntries: [(AgentProvider, any OpenBurnBarCore.LogParser)] = []
    }

    struct ParsedBatch: Sendable {
        var parserHealth: [AgentProvider: ParserHealth] = [:]
        var errors: [AgentProvider: String] = [:]
        var usageSessionIDsToDeleteByProvider: [AgentProvider: Set<String>] = [:]
        var allUsages: [TokenUsage] = []
        var allConversations: [OpenBurnBarCore.ConversationRecord] = []
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

    /// Parses provider usage, optionally including full conversation bodies.
    ///
    /// The normal refresh passes `false` so token usage can be persisted before
    /// the much more expensive optional conversation-indexing pass begins.
    func parse(
        from discovery: DiscoverResult,
        includeConversationBodies: Bool? = nil,
        minimumFileModificationDate: Date? = nil,
        resourceGovernor: OpenBurnBarCore.ParserResourceGovernor? = nil,
        resourceGovernorForProvider: ((AgentProvider) -> OpenBurnBarCore.ParserResourceGovernor?)? = nil
    ) async throws -> ParsedBatch {
        var result = ParsedBatch()
        let startedAt = Date()
        let includeConversationBodies = includeConversationBodies ?? settings.conversationIndexingEnabled

        for (provider, parser) in discovery.parserEntries {
            do {
                let parseResult = try await parser.parse(
                    options: OpenBurnBarCore.LogParseOptions(
                        includeConversationBodies: includeConversationBodies,
                        minimumFileModificationDate: minimumFileModificationDate,
                        resourceGovernor: resourceGovernorForProvider?(provider) ?? resourceGovernor
                    )
                )
                let usages = parseResult.usages
                let providerHealth: ParserHealth = usages.isEmpty
                    ? .empty
                    : .healthy(sessionCount: usages.count)
                result.allUsages.append(contentsOf: usages)
                if !parseResult.usageSessionIDsToDelete.isEmpty {
                    result.usageSessionIDsToDeleteByProvider[provider, default: []]
                        .formUnion(parseResult.usageSessionIDsToDelete)
                }
                if includeConversationBodies {
                    result.allConversations.append(contentsOf: parseResult.conversations)
                }
                result.parserHealth[provider] = providerHealth
            } catch {
                if error is CancellationError {
                    throw error
                }
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

    func persist(parsed: ParsedBatch) async -> PersistResult {
        var result = PersistResult()
        let startedAt = Date()

        do {
            var sessionIDsToDeleteByProvider = parsed.usageSessionIDsToDeleteByProvider
            let staleExactCodexSessionIDs = codexSessionIDsWithNewerStateTotals(in: parsed.allUsages)
            if !staleExactCodexSessionIDs.isEmpty {
                sessionIDsToDeleteByProvider[.codex, default: []]
                    .formUnion(staleExactCodexSessionIDs)
            }

            for provider in sessionIDsToDeleteByProvider.keys.sorted(by: {
                $0.rawValue < $1.rawValue
            }) {
                try await dataStore.deleteUsage(
                    provider: provider,
                    sessionIDs: Array(sessionIDsToDeleteByProvider[provider] ?? [])
                )
            }
            if !parsed.allUsages.isEmpty {
                try await dataStore.insertChunked(parsed.allUsages, chunkSize: 500)
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

    /// A provider-log row can be exact for an older file offset while Codex's
    /// state DB already exposes a larger, current thread total. Replace that
    /// stale snapshot with the monotonic state-total estimate; a later JSONL
    /// scan upgrades it back to exact buckets. Lower estimates never displace
    /// an exact row.
    private func codexSessionIDsWithNewerStateTotals(in incomingUsages: [TokenUsage]) -> Set<String> {
        let exactTotalsByIdentity = Dictionary(
            existingUsages.compactMap { usage -> (String, Int)? in
                guard usage.provider == .codex,
                      usage.provenanceConfidence == .exact || usage.provenanceConfidence == .derivedExact else {
                    return nil
                }
                return (Self.usageIdentity(usage), usage.totalTokens)
            },
            uniquingKeysWith: max
        )

        return Set(incomingUsages.compactMap { usage -> String? in
            guard usage.provider == .codex,
                  usage.estimatorVersion == "tokens-used-cache-split-v2",
                  let exactTotal = exactTotalsByIdentity[Self.usageIdentity(usage)],
                  usage.totalTokens > exactTotal else {
                return nil
            }
            return usage.sessionId
        })
    }

    private static func usageIdentity(_ usage: TokenUsage) -> String {
        TokenUsage.deterministicIdentityKey(
            provider: usage.provider,
            sessionId: usage.sessionId,
            model: usage.model,
            sourceDeviceId: usage.sourceDeviceId,
            providerAccountID: usage.providerAccountID
        )
    }

    func writeParserHealth(
        parsed: ParsedBatch,
        persist: PersistResult
    ) async throws {
        try await RefreshBackgroundWork.writeParserImportHealth(
            parserHealth: parsed.parserHealth,
            parsers: parsers,
            dataStore: dataStore,
            importedUsageCount: parsed.allUsages.count,
            persistenceError: persist.persistenceErrorMessage,
            conversationIndexingEnabled: settings.conversationIndexingEnabled
        )
    }
}
