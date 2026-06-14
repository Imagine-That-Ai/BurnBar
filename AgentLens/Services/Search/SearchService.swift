import Foundation
import OpenBurnBarCore

// Retrieval flow (shared service path):
// query
//   -> lexical candidates from search_chunks_fts (always)
//   -> optional semantic candidates (ANN -> exact fallback)
//   -> bounded rerank + source hydration
//   -> RBAC/visibility filtering + snippets/context

// MARK: - Search Service

/// Hybrid retrieval is intentionally **not** `@MainActor` so FTS, fusion, hydration, and cross-encoder
/// work do not run on the main thread. `MainActor` is only used to snapshot `SharedArtifactAccessContext`.
///
/// `SearchService` is an actor: all mutable state (including `_lastHealthWriteError`) is protected by
/// actor isolation. Callers `await` all public methods. The `SearchRetrievalGate` private actor that
/// previously serialized calls is now redundant and has been removed.
actor SearchService {
    let dataStore: DataStore
    let semanticProvider: SemanticCandidateProviding?
    let reranker: RetrievalRerankProviding?
    let sharedArtifactAccessContextProvider: @MainActor @Sendable () -> SharedArtifactAccessContext?
    let nowProvider: @Sendable () -> Date

    var _lastHealthWriteError: String?
    var _lastTypedHealthWriteError: OpenBurnBarError?

    /// May be read from the main thread or tests while retrieval runs in the background.
    var lastHealthWriteError: String? {
        _lastHealthWriteError
    }

    /// Typed counterpart to `lastHealthWriteError` for metrics and structured logging.
    var lastTypedHealthWriteError: OpenBurnBarError? {
        _lastTypedHealthWriteError
    }

    func setLastHealthWriteError(_ value: String?, typed: OpenBurnBarError? = nil) {
        _lastHealthWriteError = value
        _lastTypedHealthWriteError = typed
    }

    /// Preferred initializer when shared-artifact access should resolve against the live account; requires a
    /// `MainActor` snapshotter (use ``makeConversationSearchService(dataStore:settingsManager:providerAPIKeyStore:nowProvider:)`` in app code).
    init(
        dataStore: DataStore,
        semanticProvider: SemanticCandidateProviding? = nil,
        reranker: RetrievalRerankProviding? = nil,
        sharedArtifactAccessContextProvider: @escaping @MainActor @Sendable () -> SharedArtifactAccessContext?,
        nowProvider: @escaping @Sendable () -> Date
    ) {
        self.dataStore = dataStore
        self.semanticProvider = semanticProvider
        self.reranker = reranker
        self.sharedArtifactAccessContextProvider = sharedArtifactAccessContextProvider
        self.nowProvider = nowProvider
    }

    /// Tests and call sites that do not use shared artifacts may omit the provider; context resolves to `nil`.
    init(
        dataStore: DataStore,
        semanticProvider: SemanticCandidateProviding? = nil,
        reranker: RetrievalRerankProviding? = nil,
        nowProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            reranker: reranker,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: nowProvider
        )
    }

    /// `nonisolated` because `dataStore` is an immutable `let` and `fetchConversations`
    /// uses GRDB's synchronous `read` — no actor isolation needed.
    ///
    /// A real DB/GRDB read failure here is recoverable (callers degrade to an empty
    /// list), but it must be **observable**: a swallowed `try?` makes a genuine read
    /// fault indistinguishable from an empty store. `AppLogger.search.silently` logs
    /// the failure and only then falls back to `[]`. (This is `nonisolated`, so the
    /// actor-scoped `setLastHealthWriteError` cannot be called from here; logging is
    /// the available observability seam.)
    nonisolated func recentConversations(limit: Int = 80) -> [ConversationRecord] {
        let bounded = max(1, min(limit, 1_000))
        return AppLogger.search.silently(
            "recent_conversations_fetch_failed",
            try dataStore.fetchConversations(limit: bounded),
            fallback: []
        )
    }

    nonisolated func latestConversation(limit: Int = 200) -> ConversationRecord? {
        latestConversation(in: recentConversations(limit: limit))
    }

    nonisolated func latestConversation(in conversations: [ConversationRecord]) -> ConversationRecord? {
        conversations.max(by: { a, b in
            let ad = a.endTime ?? a.startTime ?? .distantPast
            let bd = b.endTime ?? b.startTime ?? .distantPast
            return ad < bd
        })
    }

    func runBurnBarQuery(_ query: RetrievalQuery) async -> OpenBurnBarQueryRunResult {
        let now = nowProvider()
        let cacheKey = SearchQueryCacheKey(query: query)
        if let cachedResult = SearchQueryCache.shared.get(key: cacheKey, now: now) {
            TelemetryService.shared.record(feature: .searchRetrieval, outcome: .success, durationMs: 0)
            OpenBurnBarMetrics.histogram(name: "search_latency_ms", value: 0.0, labels: ["mode": cachedResult.plan.mode.rawValue])
            return cachedResult
        }

        let start = Date()
        let result = await runBurnBarQueryInGate(query)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let status: TelemetryOutcome = result.retrievalResults.isEmpty && result.aggregateOccurrenceCount == nil ? .degraded : .success
        TelemetryService.shared.record(feature: .searchRetrieval, outcome: status, durationMs: durationMs)
        OpenBurnBarMetrics.histogram(name: "search_latency_ms", value: Double(durationMs), labels: ["mode": result.plan.mode.rawValue])

        SearchQueryCache.shared.set(key: cacheKey, result: result, now: now)
        return result
    }

    func runBurnBarQueryInGate(_ query: RetrievalQuery) async -> OpenBurnBarQueryRunResult {
        let plan = BurnBarSearchPlan.plan(userText: query.text)
        let now = nowProvider()
        var filters = query.filters
        var aggregateWindowDescription: String?
        if filters.dateRange == nil,
           let inferred = BurnBarSearchTimeWindow.inferredDateRange(from: query.text, now: now, calendar: .current) {
            filters.dateRange = inferred
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            aggregateWindowDescription =
                "Counts and retrieval are limited to local time window: \(fmt.string(from: inferred.lowerBound)) – \(fmt.string(from: inferred.upperBound))."
        }

        var aggregateCount: Int?
        if plan.mode == .mixed || plan.mode == .aggregate, !plan.aggregatePatterns.isEmpty {
            // Fail closed on a DB/FTS error: this value is surfaced as the
            // authoritative `aggregateOccurrenceCount` for count-style queries
            // ("how many times X"). Collapsing a real error to `0` would tell the
            // user "0 occurrences" when the true count is *unknown* — a silent
            // correctness regression. Leave `aggregateCount` as `nil` so the result
            // reports "unknown"/degraded (see `runBurnBarQuery`'s telemetry, which
            // treats a `nil` count as `.degraded`), and record the failure.
            do {
                aggregateCount = try dataStore.countOccurrencesInConversationFullText(
                    patterns: plan.aggregatePatterns,
                    provider: filters.provider,
                    projectName: filters.projectName,
                    dateRange: filters.dateRange,
                    conversationSources: filters.conversationSources
                )
            } catch {
                let typed = OpenBurnBarError.search(
                    "aggregate_count_query_failed",
                    message: "Failed to count conversation full-text occurrences for an aggregate query.",
                    underlying: error
                )
                AppLogger.search.error(
                    "aggregate_count_query_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
                setLastHealthWriteError(typed.message, typed: typed)
                // `aggregateCount` stays `nil` (its initial value): the fail-closed
                // "unknown" signal, never a fabricated `0`.
            }
        }
        // Filter-aware semantic candidate generation is not yet able to enforce
        // date/source bounds before top-k truncation. For count-style and
        // restricted-window queries, prefer deterministic lexical + aggregate paths.
        let disableSemanticForBoundedQuery =
            plan.mode == .mixed
            || plan.mode == .aggregate
            || filters.dateRange != nil
            || filters.sourceIDs?.isEmpty == false
            || filters.conversationSources?.isEmpty == false
            || Self.looksLikeSensitiveExactLookup(query.text)
        let lexicalTrimmed = plan.lexicalFTSQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let subQuery = RetrievalQuery(
            text: plan.semanticText,
            lexicalFTSQuery: lexicalTrimmed.isEmpty ? nil : lexicalTrimmed,
            filters: filters,
            lexicalCandidateLimit: query.lexicalCandidateLimit,
            semanticCandidateLimit: disableSemanticForBoundedQuery ? 0 : query.semanticCandidateLimit,
            rerankCandidateLimit: query.rerankCandidateLimit,
            resultLimit: query.resultLimit,
            hybridFusionStrategy: query.hybridFusionStrategy
        )
        let accessContext = await MainActor.run { self.sharedArtifactAccessContextProvider() }
        let results = await retrieveInGate(subQuery, sharedArtifactAccessContext: accessContext)
        return OpenBurnBarQueryRunResult(
            plan: plan,
            retrievalResults: results,
            aggregateOccurrenceCount: aggregateCount,
            aggregateWindowDescription: aggregateWindowDescription
        )
    }

    func retrieve(_ query: RetrievalQuery) async -> [RetrievalResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let accessContext = await MainActor.run { self.sharedArtifactAccessContextProvider() }
        return await retrieveInGate(query, sharedArtifactAccessContext: accessContext)
    }

    /// Core retrieval, invoked on the actor's serial executor; `sharedArtifactAccessContext` is
    /// pre-snapshoted on the main actor by callers.

}
