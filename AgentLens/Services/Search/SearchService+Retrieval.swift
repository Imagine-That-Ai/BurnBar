import Foundation
import OpenBurnBarCore

// MARK: - Core retrieval pipeline

extension SearchService {

    internal func retrieveInGate(_ query: RetrievalQuery, sharedArtifactAccessContext: SharedArtifactAccessContext?) async -> [RetrievalResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let queryStartedAt = OpenBurnBarPerformanceTimer.now()

        let lexicalLimit = max(1, min(query.lexicalCandidateLimit, 1_000))
        let semanticLimit = max(0, min(query.semanticCandidateLimit, 1_000))
        let rerankLimit = max(1, min(query.rerankCandidateLimit, 1_000))
        let resultLimit = max(1, min(query.resultLimit, rerankLimit))

        let sourceKinds = normalizedSourceKinds(query.filters.artifactTypes)
        let sourceIDs = normalizedSourceIDs(query.filters.sourceIDs)
        var semanticFallbackUsed = false
        var semanticCandidateCount = 0
        var indexStale = false
        var indexStaleError: String?
        var lexicalQueryLatencyMs: Double?
        var semanticQueryLatencyMs: Double?
        var rerankLatencyMs: Double?
        var hydrationLatencyMs: Double?
        var crossEncoderLatencyMs: Double?
        var lexicalSkippedEmptyQuery = false

        func persistQueryHealth(
            status: RetrievalHealthStatus,
            lexicalCandidateCount: Int,
            resultCount: Int,
            indexStale: Bool,
            semanticFallbackUsed: Bool,
            errorCode: String?,
            errorMessage: String?
        ) {
            persistLexicalHealth(
                status: status,
                query: trimmed,
                lexicalCandidateCount: lexicalCandidateCount,
                semanticCandidateCount: semanticCandidateCount,
                resultCount: resultCount,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt),
                lexicalQueryLatencyMs: lexicalQueryLatencyMs,
                semanticQueryLatencyMs: semanticQueryLatencyMs,
                rerankLatencyMs: rerankLatencyMs,
                hydrationLatencyMs: hydrationLatencyMs,
                crossEncoderLatencyMs: crossEncoderLatencyMs
            )
        }

        let lexicalFTSInput: String = {
            if let o = query.lexicalFTSQuery?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty {
                return o
            }
            return BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        }()

        let lexicalMatches: [SearchChunkLexicalMatch]
        let lexicalStartedAt = OpenBurnBarPerformanceTimer.now()
        if lexicalFTSInput.isEmpty {
            lexicalSkippedEmptyQuery = true
            lexicalMatches = []
            lexicalQueryLatencyMs = 0
        } else {
            do {
                lexicalMatches = try dataStore.searchLexicalChunks(
                    ftsQuery: lexicalFTSInput,
                    provider: query.filters.provider,
                    projectName: query.filters.projectName,
                    sourceKinds: sourceKinds,
                    dateRange: query.filters.dateRange,
                    visibility: query.filters.ownership.visibilityScope,
                    sharedArtifactAccessContext: sharedArtifactAccessContext,
                    sourceIDs: sourceIDs,
                    limit: lexicalLimit
                )
                lexicalQueryLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
            } catch {
                lexicalQueryLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
                persistQueryHealth(
                    status: .failed,
                    lexicalCandidateCount: 0,
                    resultCount: 0,
                    indexStale: true,
                    semanticFallbackUsed: false,
                    errorCode: "LEXICAL_QUERY_FAILED",
                    errorMessage: error.localizedDescription
                )
                return []
            }
        }

        var candidates: [String: CandidateAccumulator] = [:]
        var lexicalChunkMap: [String: SearchChunkRecord] = [:]
        var lexicalDocumentMap: [String: SearchDocumentRecord] = [:]
        var lexicalRankByChunkID: [String: Int] = [:]
        var lexicalOrderCounter = 0
        for match in lexicalMatches {
            if lexicalRankByChunkID[match.chunkID] == nil {
                lexicalOrderCounter += 1
                lexicalRankByChunkID[match.chunkID] = lexicalOrderCounter
            }
            candidates[match.chunkID] = CandidateAccumulator(
                lexicalRank: match.lexicalRank,
                semanticScore: nil,
                lexicalSnippet: match.snippet
            )
            lexicalChunkMap[match.chunkID] = SearchChunkRecord(
                id: match.chunkID,
                documentID: match.documentID,
                sourceKind: match.sourceKind,
                sourceID: match.sourceID,
                sourceVersionID: match.sourceVersionID,
                ordinal: match.chunkOrdinal,
                startOffset: match.startOffset,
                endOffset: match.endOffset,
                messageStartOffset: nil,
                messageEndOffset: nil,
                sectionPath: match.sectionPath,
                text: match.chunkText,
                createdAt: match.indexedAt,
                updatedAt: match.indexedAt
            )
            lexicalDocumentMap[match.documentID] = SearchDocumentRecord(
                id: match.documentID,
                sourceKind: match.sourceKind,
                sourceID: match.sourceID,
                sourceVersionID: match.sourceVersionID,
                provider: match.provider,
                projectName: match.projectName,
                title: match.title,
                subtitle: match.subtitle,
                bodyPreview: match.bodyPreview,
                sourceUpdatedAt: match.sourceUpdatedAt,
                indexedAt: match.indexedAt,
                contentHash: nil,
                createdAt: match.indexedAt,
                updatedAt: match.indexedAt
            )
        }

        var semanticRankByChunkID: [String: Int] = [:]
        if semanticLimit > 0, let semanticProvider {
            let semanticStartedAt = OpenBurnBarPerformanceTimer.now()
            do {
                let semanticCandidates = try await semanticProvider.semanticCandidates(
                    for: trimmed,
                    filters: query.filters,
                    limit: semanticLimit
                )
                semanticQueryLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: semanticStartedAt)
                semanticCandidateCount = semanticCandidates.count
                var semanticOrderCounter = 0
                for semanticCandidate in semanticCandidates {
                    if semanticRankByChunkID[semanticCandidate.chunkID] == nil {
                        semanticOrderCounter += 1
                        semanticRankByChunkID[semanticCandidate.chunkID] = semanticOrderCounter
                    }
                    let normalizedScore = max(0, semanticCandidate.score)
                    if var existing = candidates[semanticCandidate.chunkID] {
                        if let semantic = existing.semanticScore {
                            existing.semanticScore = max(semantic, normalizedScore)
                        } else {
                            existing.semanticScore = normalizedScore
                        }
                        candidates[semanticCandidate.chunkID] = existing
                    } else {
                        candidates[semanticCandidate.chunkID] = CandidateAccumulator(
                            lexicalRank: nil,
                            semanticScore: normalizedScore,
                            lexicalSnippet: nil
                        )
                    }
                }
            } catch {
                semanticQueryLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: semanticStartedAt)
                semanticFallbackUsed = true
                persistSemanticFallbackHealth(
                    query: trimmed,
                    lexicalCandidateCount: lexicalMatches.count,
                    error: error
                )
            }
        }

        // Only return early if we have no candidates AND semantic didn't produce any
        // (semantic-only path is allowed when FTS is empty but semanticLimit > 0)
        let hasSemanticCandidates = semanticCandidateCount > 0
        let semanticWasAvailable = semanticLimit > 0 && semanticProvider != nil
        let shouldReturnEmpty = candidates.isEmpty && (!semanticWasAvailable || !hasSemanticCandidates)

        if shouldReturnEmpty {
            let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
            let lexicalError = lexicalHealthError(
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
                indexStaleError: indexStaleError
            )
            persistQueryHealth(
                status: lexicalStatus,
                lexicalCandidateCount: lexicalMatches.count,
                resultCount: 0,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: lexicalError.code,
                errorMessage: lexicalError.message
            )
            return []
        }

        let rerankStartedAt = OpenBurnBarPerformanceTimer.now()
        let kRRF = HybridRetrievalConstants.rrfK
        let boundedChunkIDs: [String]
        switch query.hybridFusionStrategy {
        case .reciprocalRankFusion:
            boundedChunkIDs = Array(
                candidates.keys.sorted { a, b in
                    let ra = Self.reciprocalRankFusion(
                        lexicalRank: lexicalRankByChunkID[a],
                        semanticRank: semanticRankByChunkID[a],
                        k: kRRF
                    )
                    let rb = Self.reciprocalRankFusion(
                        lexicalRank: lexicalRankByChunkID[b],
                        semanticRank: semanticRankByChunkID[b],
                        k: kRRF
                    )
                    if ra == rb { return a < b }
                    return ra > rb
                }
                .prefix(rerankLimit)
            )
        case .legacyWeighted:
            boundedChunkIDs = Array(
                candidates
                    .sorted {
                        let lhs = preliminaryScore(for: $0.value)
                        let rhs = preliminaryScore(for: $1.value)
                        if lhs == rhs {
                            return $0.key < $1.key
                        }
                        return lhs > rhs
                    }
                    .prefix(rerankLimit)
                    .map(\.key)
            )
        }
        rerankLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: rerankStartedAt)

        let hydrationStartedAt = OpenBurnBarPerformanceTimer.now()

        let missingChunkIDs = boundedChunkIDs.filter { lexicalChunkMap[$0] == nil }
        let fetchedChunks: [SearchChunkRecord]
        if missingChunkIDs.isEmpty {
            fetchedChunks = []
        } else {
            do {
                fetchedChunks = try dataStore.fetchSearchChunks(ids: missingChunkIDs)
            } catch {
                fetchedChunks = []
                indexStale = true
                indexStaleError = indexStaleError ?? error.localizedDescription
            }
        }
        var chunkMap = lexicalChunkMap
        for chunk in fetchedChunks {
            chunkMap[chunk.id] = chunk
        }

        let allDocumentIDs = Set(
            boundedChunkIDs.compactMap { chunkID in
                chunkMap[chunkID]?.documentID
            }
        )
        let missingDocumentIDs = allDocumentIDs.filter { lexicalDocumentMap[$0] == nil }
        let fetchedDocuments: [SearchDocumentRecord]
        if missingDocumentIDs.isEmpty {
            fetchedDocuments = []
        } else {
            do {
                fetchedDocuments = try dataStore.fetchSearchDocuments(ids: Array(missingDocumentIDs))
            } catch {
                fetchedDocuments = []
                indexStale = true
                indexStaleError = indexStaleError ?? error.localizedDescription
            }
        }
        var documentMap = lexicalDocumentMap
        for document in fetchedDocuments {
            documentMap[document.id] = document
        }

        let readableSharedSourceIDs: Set<String>?
        if shouldEnforceSharedArtifactAccess(filters: query.filters, sourceKinds: sourceKinds) {
            if let sharedArtifactAccessContext {
                readableSharedSourceIDs = try? dataStore.fetchReadableSharedArtifactSourceIDs(
                    accessContext: sharedArtifactAccessContext
                )
            } else {
                readableSharedSourceIDs = Set<String>()
            }
        } else {
            readableSharedSourceIDs = nil
        }

        // Batch preload conversations to eliminate N+1 queries during scoring.
        // Extract all unique conversation sourceIDs from the candidate set.
        var conversationCache: [String: ConversationRecord?] = [:]
        let conversationSourceIDs = Set(boundedChunkIDs.compactMap { chunkID -> String? in
            guard let chunk = chunkMap[chunkID],
                  let document = documentMap[chunk.documentID],
                  document.sourceKind == .conversation else { return nil }
            return document.sourceID
        })
        if !conversationSourceIDs.isEmpty {
            do {
                let batchConversations = try dataStore.fetchConversations(ids: Array(conversationSourceIDs))
                for conv in batchConversations {
                    conversationCache[conv.id] = conv
                }
            } catch {
                indexStale = true
                indexStaleError = indexStaleError ?? error.localizedDescription
            }
        }

        var scoredResults: [RetrievalResult] = []
        scoredResults.reserveCapacity(boundedChunkIDs.count)

        let tokens = Self.queryTokens(from: trimmed)

        for chunkID in boundedChunkIDs {
            guard
                let candidate = candidates[chunkID],
                let chunk = chunkMap[chunkID],
                let document = documentMap[chunk.documentID]
            else {
                continue
            }

            let conversation: ConversationRecord?
            if document.sourceKind == .conversation {
                conversation = conversationCache[document.sourceID] ?? nil
            } else {
                conversation = nil
            }

            guard
                matchesFilters(
                    document: document,
                    conversation: conversation,
                    filters: query.filters,
                    readableSharedSourceIDs: readableSharedSourceIDs
                )
            else {
                continue
            }

            let exactScore = Self.exactTokenCoverageScore(tokens: tokens, title: document.title, chunkText: chunk.text)
            let recency = recencyScore(document.sourceUpdatedAt ?? document.indexedAt)
            let rerank: Double
            switch query.hybridFusionStrategy {
            case .reciprocalRankFusion:
                let rawRRF = Self.reciprocalRankFusion(
                    lexicalRank: lexicalRankByChunkID[chunkID],
                    semanticRank: semanticRankByChunkID[chunkID],
                    k: kRRF
                )
                let normRRF = Self.normalizedRRFForRerank(
                    rawRRF,
                    lexicalRank: lexicalRankByChunkID[chunkID],
                    semanticRank: semanticRankByChunkID[chunkID],
                    k: kRRF
                )
                rerank = (normRRF * 0.52) + (exactScore * 0.33) + (recency * 0.15)
            case .legacyWeighted:
                let lexicalScore = Self.normalizedLexicalScore(candidate.lexicalRank)
                let semanticScore = max(0, candidate.semanticScore ?? 0)
                rerank = (lexicalScore * 0.52) + (semanticScore * 0.33) + (exactScore * 0.10) + (recency * 0.05)
            }

            let snippet = Self.makeSnippet(
                lexicalSnippet: candidate.lexicalSnippet,
                chunkText: chunk.text,
                fallback: document.bodyPreview ?? document.title
            )

            scoredResults.append(
                RetrievalResult(
                    chunkID: chunk.id,
                    documentID: document.id,
                    sourceKind: document.sourceKind,
                    sourceID: document.sourceID,
                    provider: document.provider.flatMap(AgentProvider.init(rawValue:)),
                    providerRawValue: document.provider,
                    projectName: document.projectName,
                    title: document.title,
                    subtitle: document.subtitle,
                    snippet: snippet,
                    sectionPath: chunk.sectionPath,
                    startOffset: chunk.startOffset,
                    endOffset: chunk.endOffset,
                    sourceUpdatedAt: document.sourceUpdatedAt,
                    indexedAt: document.indexedAt,
                    lexicalRank: candidate.lexicalRank,
                    semanticScore: candidate.semanticScore,
                    rerankScore: rerank,
                    conversation: conversation
                )
            )
        }

        guard scoredResults.isEmpty == false else {
            hydrationLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: hydrationStartedAt)
            let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
            let lexicalError = lexicalHealthError(
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
                indexStaleError: indexStaleError
            )
            persistQueryHealth(
                status: lexicalStatus,
                lexicalCandidateCount: lexicalMatches.count,
                resultCount: 0,
                indexStale: indexStale,
                semanticFallbackUsed: semanticFallbackUsed,
                errorCode: lexicalError.code,
                errorMessage: lexicalError.message
            )
            return []
        }

        // Cross-encoder reranking: take top N candidates, rerank them, merge back
        if query.crossEncoderEnabled, let reranker, reranker is NoOpRetrievalReranker == false {
            let crossEncoderStartedAt = OpenBurnBarPerformanceTimer.now()
            let crossEncoderLimit = max(5, min(query.crossEncoderCandidateLimit, scoredResults.count))
            let candidatesToRerank = Array(scoredResults.prefix(crossEncoderLimit))

            do {
                let rerankedCandidates = try await reranker.rerank(
                    query: trimmed,
                    candidates: candidatesToRerank,
                    limit: crossEncoderLimit
                )

                // Build a set of reranked chunkIDs for quick lookup
                let rerankedIDs = Set(rerankedCandidates.map(\.chunkID))

                // Keep candidates not in the reranked set in their original relative order
                let remainingCandidates = scoredResults.filter { !rerankedIDs.contains($0.chunkID) }

                // Replace reranked section with the new order
                scoredResults = rerankedCandidates + remainingCandidates

                crossEncoderLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: crossEncoderStartedAt)
            } catch {
                // Fall back to pre-rerank order on error; mark health as degraded
                crossEncoderLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: crossEncoderStartedAt)
                setLastHealthWriteError("Cross-encoder reranking failed: \(error.localizedDescription)")
                // scoredResults remains unchanged — this is the graceful fallback
            }
        }

        scoredResults.sort { lhs, rhs in
            if lhs.rerankScore == rhs.rerankScore {
                if lhs.indexedAt == rhs.indexedAt {
                    return lhs.chunkID < rhs.chunkID
                }
                return lhs.indexedAt > rhs.indexedAt
            }
            return lhs.rerankScore > rhs.rerankScore
        }

        var seenDocuments: Set<String> = []
        var dedupedResults: [RetrievalResult] = []
        dedupedResults.reserveCapacity(min(resultLimit, scoredResults.count))
        for result in scoredResults {
            guard seenDocuments.insert(result.documentID).inserted else { continue }
            dedupedResults.append(result)
            if dedupedResults.count >= resultLimit { break }
        }

        hydrationLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: hydrationStartedAt)
        let lexicalStatus = lexicalHealthStatus(indexStale: indexStale, semanticFallbackUsed: semanticFallbackUsed)
        let lexicalError = lexicalHealthError(
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            lexicalSkippedEmptyQuery: lexicalSkippedEmptyQuery,
            indexStaleError: indexStaleError
        )
        persistQueryHealth(
            status: lexicalStatus,
            lexicalCandidateCount: lexicalMatches.count,
            resultCount: dedupedResults.count,
            indexStale: indexStale,
            semanticFallbackUsed: semanticFallbackUsed,
            errorCode: lexicalError.code,
            errorMessage: lexicalError.message
        )

        return dedupedResults
    }

}
