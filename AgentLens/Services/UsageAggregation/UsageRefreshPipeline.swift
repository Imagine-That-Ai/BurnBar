import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - Conversation Indexing Seam

/// The single capability the reconcile stage needs from `RefreshOrchestrator`.
///
/// Narrow on purpose. Usage accounting depends on conversation indexing running
/// *after* usage rows are committed, and that ordering is only worth as much as
/// the test that pins it. A protocol here lets a test observe the usage table at
/// the exact moment indexing is invoked; `RefreshOrchestrator` is an `actor` and
/// cannot be subclassed for that purpose.
protocol ConversationIndexingCoordinator: Sendable {
    func indexConversationsOffMain(
        _ conversations: [OpenBurnBarCore.ConversationRecord],
        indexingEnabled: Bool
    ) async -> Int
}

extension RefreshOrchestrator: ConversationIndexingCoordinator {}

// MARK: - Usage Refresh Pipeline Stages

/// Explicit refresh pipeline: discover → parse → persist → reconcile.
///
/// `RefreshBackgroundWork` delegates to these stages so timing and failure
/// boundaries stay visible without rewriting the orchestrator graph.
///
/// Stage order is a correctness contract, not a preference: usage rows are
/// published before anything indexes conversation bodies. See
/// `publishUsageThenIndexConversations(parsed:)`.
struct UsageRefreshPipeline: Sendable {
    let parsers: [AgentProvider: any OpenBurnBarCore.LogParser]
    let dataStore: DataStore
    let orchestrator: any ConversationIndexingCoordinator
    let settings: RefreshSettingsSnapshot

    struct DiscoverResult: Sendable {
        var parserEntries: [(AgentProvider, any OpenBurnBarCore.LogParser)] = []
    }

    struct ParsedBatch: Sendable {
        var parserHealth: [AgentProvider: ParserHealth] = [:]
        var errors: [AgentProvider: String] = [:]
        var allUsages: [TokenUsage] = []
        var allConversations: [OpenBurnBarCore.ConversationRecord] = []
        var usageSessionIDsToDeleteByProvider: [AgentProvider: Set<String>] = [:]
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

    /// Result of the ordered publish-then-index operation. Holding one is proof
    /// that usage rows were committed before conversation indexing ran, or,
    /// when persistence failed, that indexing was deliberately skipped rather
    /// than run against a partially published usage table.
    struct PublishResult: Sendable {
        var persist: PersistResult
        var reconcile: ReconcileResult
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
        resourceGovernor: OpenBurnBarCore.ParserResourceGovernor? = nil
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
                        resourceGovernor: resourceGovernor
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

    /// Commits the parsed usage batch, then indexes any conversation bodies it
    /// carried — in that order, always.
    ///
    /// The ordering is the fix. `persist` is what makes a refresh tick's numbers
    /// real: it deletes the session IDs the parsers invalidated
    /// (`usageSessionIDsToDelete` — e.g. a Codex lifetime row superseded by exact
    /// per-day rows) and inserts the replacements. `reconcile` runs
    /// `ConversationIndexer`, which takes the DataStore's single writer for one
    /// `upsertConversation` + one `enqueueConversationProjectionJob` per changed
    /// record and wakes the projection worker.
    ///
    /// Running reconcile first opens a window in which the usage table still
    /// holds the superseded rows, does not yet hold their replacements, and is
    /// already being read by projection jobs the indexer just enqueued — so
    /// totals computed in that window double-count. Persisting first closes it:
    /// by the time anything indexes, the tick's accounting has committed.
    ///
    /// When persistence fails the ordering contract cannot be satisfied at all:
    /// the deletions and chunked inserts commit in separate transactions, so a
    /// mid-flight failure can leave only some invalidations or replacements
    /// applied. Indexing against that partially published state would enqueue
    /// projection jobs that materialize incomplete totals, so reconciliation is
    /// skipped and the persistence error is surfaced via `PublishResult.persist`.
    func publishUsageThenIndexConversations(parsed: ParsedBatch) async -> PublishResult {
        let persisted = await persist(parsed: parsed)
        guard persisted.persistenceErrorMessage == nil else {
            return PublishResult(persist: persisted, reconcile: ReconcileResult())
        }
        let reconciled = await reconcile(parsed: parsed, afterPublishing: persisted)
        return PublishResult(persist: persisted, reconcile: reconciled)
    }

    /// Indexes conversation bodies.
    ///
    /// `private` on purpose: `publishUsageThenIndexConversations` is the only
    /// entry point to conversation indexing, so a caller cannot schedule
    /// indexing ahead of (or instead of) usage publication. `published` keeps
    /// the ordering explicit at the single call site inside this file.
    private func reconcile(
        parsed: ParsedBatch,
        afterPublishing published: PersistResult
    ) async -> ReconcileResult {
        _ = published
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
            for provider in parsed.usageSessionIDsToDeleteByProvider.keys.sorted(by: {
                $0.rawValue < $1.rawValue
            }) {
                try await dataStore.deleteUsage(
                    provider: provider,
                    sessionIDs: Array(parsed.usageSessionIDsToDeleteByProvider[provider] ?? [])
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
