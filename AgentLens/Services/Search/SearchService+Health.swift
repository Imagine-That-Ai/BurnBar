import Foundation
import OpenBurnBarCore

// MARK: - Health persistence

extension SearchService {

    public func search(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil,
        conversationSources: Set<ConversationSourceType>? = nil,
        resultLimit: Int = 50
    ) async -> [SearchResult] {
        let boundedLimit = max(1, min(resultLimit, 200))
        let plan = BurnBarSearchPlan.plan(userText: query)
        let semanticCandidateLimit = plan.allowsSemanticSearch ? 120 : 0
        let run = await runBurnBarQuery(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(
                    provider: provider,
                    projectName: projectName,
                    artifactTypes: [.conversation],
                    dateRange: dateRange,
                    ownership: .personal,
                    conversationSources: conversationSources
                ),
                lexicalCandidateLimit: 120,
                semanticCandidateLimit: semanticCandidateLimit,
                rerankCandidateLimit: 200,
                resultLimit: boundedLimit
            )
        )

        return run.retrievalResults.compactMap { result in
            guard let conversation = result.conversation else { return nil }
            return SearchResult(
                conversation: conversation,
                snippet: result.snippet,
                rank: result.rerankScore
            )
        }
    }

    internal func lexicalHealthStatus(indexStale: Bool, semanticFallbackUsed: Bool) -> RetrievalHealthStatus {
        if indexStale {
            return .degraded
        }
        if semanticFallbackUsed {
            return .degraded
        }
        return .healthy
    }

    internal func lexicalHealthError(
        indexStale: Bool,
        semanticFallbackUsed: Bool,
        lexicalSkippedEmptyQuery: Bool = false,
        indexStaleError: String?
    ) -> (code: String?, message: String?) {
        if indexStale {
            return (
                "INDEX_STALE_PARTIAL_RESULTS",
                indexStaleError ?? "Search index metadata could not be fully loaded; partial results were returned."
            )
        }
        if semanticFallbackUsed {
            return (
                "SEMANTIC_FALLBACK_USED",
                "Semantic retrieval failed; lexical fallback served this query."
            )
        }
        if lexicalSkippedEmptyQuery {
            return (
                "LEXICAL_SKIPPED_EMPTY_QUERY",
                "Lexical FTS query was empty (stopwords-only input); semantic retrieval served this query."
            )
        }
        return (nil, nil)
    }

    internal func persistLexicalHealth(
        status: RetrievalHealthStatus,
        query: String,
        lexicalCandidateCount: Int,
        semanticCandidateCount: Int,
        resultCount: Int,
        indexStale: Bool,
        semanticFallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        totalQueryLatencyMs: Double?,
        lexicalQueryLatencyMs: Double?,
        semanticQueryLatencyMs: Double?,
        rerankLatencyMs: Double?,
        hydrationLatencyMs: Double?,
        crossEncoderLatencyMs: Double?
    ) {
        let now = nowProvider()
        let details = LexicalRetrievalHealthDetails(
            queryLength: query.count,
            lexicalCandidateCount: lexicalCandidateCount,
            semanticCandidateCount: semanticCandidateCount,
            resultCount: resultCount,
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            totalQueryLatencyMs: totalQueryLatencyMs,
            lexicalQueryLatencyMs: lexicalQueryLatencyMs,
            semanticQueryLatencyMs: semanticQueryLatencyMs,
            rerankLatencyMs: rerankLatencyMs,
            hydrationLatencyMs: hydrationLatencyMs,
            crossEncoderLatencyMs: crossEncoderLatencyMs
        )
        do {
            let detailsData = try JSONEncoder().encode(details)
            let detailsJSON = String(data: detailsData, encoding: .utf8)
            try dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .lexical,
                    status: status,
                    errorCode: errorCode,
                    errorMessage: errorMessage,
                    detailsJSON: detailsJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
            setLastHealthWriteError(nil)
        } catch {
            setLastHealthWriteError(error.localizedDescription)
        }
    }

    internal func persistSemanticFallbackHealth(
        query: String,
        lexicalCandidateCount: Int,
        error: Error
    ) {
        let now = nowProvider()
        let details = SemanticFallbackHealthDetails(
            queryLength: query.count,
            lexicalCandidateCount: lexicalCandidateCount
        )
        do {
            let detailsData = try JSONEncoder().encode(details)
            let detailsJSON = String(data: detailsData, encoding: .utf8)
            try dataStore.upsertRetrievalHealth(
                RetrievalHealthRecord(
                    subsystem: .semantic,
                    status: .degraded,
                    errorCode: "SEMANTIC_PROVIDER_FALLBACK",
                    errorMessage: error.localizedDescription,
                    detailsJSON: detailsJSON,
                    observedAt: now,
                    updatedAt: now
                )
            )
            setLastHealthWriteError(nil)
        } catch {
            setLastHealthWriteError(error.localizedDescription)
        }
    }
}
