import Foundation
import OpenBurnBarCore

extension SearchService {
        func retrieveInGate(_ query: RetrievalQuery, sharedArtifactAccessContext: SharedArtifactAccessContext?) async -> [RetrievalResult] {
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
            ) async {
                await persistLexicalHealth(
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

            // Perf: lexical (GRDB FTS) and semantic (embedding + ANN) are independent
            // I/O — run them concurrently so the slower path does not block the other.
            // The previous sequential flow paid lexical + semantic latency serially.
            let lexicalStartedAt = OpenBurnBarPerformanceTimer.now()

            async let lexicalTask: Result<[SearchChunkLexicalMatch], Error> = {
                if lexicalFTSInput.isEmpty {
                    return .success([])
                }
                do {
                    let matches = try await dataStore.searchLexicalChunks(
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
                    return .success(matches)
                } catch {
                    return .failure(error)
                }
            }()

            // The semantic child times itself so `semanticQueryLatencyMs` measures the
            // embedding + ANN round trip alone. Measuring it at the await site would
            // fold in however long the concurrent lexical query took.
            async let semanticTask: (result: Result<[SemanticCandidate], Error>, latencyMs: Double) = {
                let startedAt = OpenBurnBarPerformanceTimer.now()
                guard semanticLimit > 0, let provider = semanticProvider else {
                    return (.success([]), OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: startedAt))
                }
                do {
                    let sem = try await provider.semanticCandidates(
                        for: trimmed,
                        filters: query.filters,
                        limit: semanticLimit
                    )
                    return (.success(sem), OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: startedAt))
                } catch {
                    return (.failure(error), OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: startedAt))
                }
            }()

            let lexicalMatches: [SearchChunkLexicalMatch]
            switch await lexicalTask {
            case .success(let matches):
                lexicalMatches = matches
                lexicalSkippedEmptyQuery = lexicalFTSInput.isEmpty
                lexicalQueryLatencyMs = lexicalMatches.isEmpty && lexicalFTSInput.isEmpty ? 0 : OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
            case .failure(let error):
                lexicalQueryLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: lexicalStartedAt)
                // Lexical failure is terminal, so the semantic result would be discarded.
                // Returning without awaiting `semanticTask` cancels the child instead of
                // paying for (and waiting on) a remote embedding request we cannot use.
                await persistQueryHealth(
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

            let semanticRetrieval = await semanticTask
            semanticQueryLatencyMs = semanticRetrieval.latencyMs

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
            switch semanticRetrieval.result {
            case .success(let semanticCandidates):
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
            case .failure(let error):
                semanticFallbackUsed = true
                await persistSemanticFallbackHealth(
                    query: trimmed,
                    lexicalCandidateCount: lexicalMatches.count,
                    error: error
                )
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
                await persistQueryHealth(
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

            // Round-4 perf sweep: collapse chunk + document hydration into a
            // single JOIN query. The old flow fetched missing chunks, then
            // fetched their parent documents in a second round-trip. The
            // combined fetch returns both in one pass; documents already in
            // `lexicalDocumentMap` are simply overwritten (same content).
            let missingChunkIDs = boundedChunkIDs.filter { lexicalChunkMap[$0] == nil }
            var chunkMap = lexicalChunkMap
            var documentMap = lexicalDocumentMap
            if missingChunkIDs.isEmpty == false {
                do {
                    let combined = try await dataStore.fetchSearchChunksWithDocuments(ids: missingChunkIDs)
                    for (chunk, document) in combined {
                        chunkMap[chunk.id] = chunk
                        documentMap[document.id] = document
                    }
                } catch {
                    indexStale = true
                    indexStaleError = indexStaleError ?? error.localizedDescription
                }
            }

            // Documents for lexical-only chunks whose documents weren't in the
            // lexical match payload (rare — the lexical match includes document
            // fields — but defensive against schema gaps).
            let allDocumentIDs = Set(
                boundedChunkIDs.compactMap { chunkID in
                    chunkMap[chunkID]?.documentID
                }
            )
            let missingDocumentIDs = allDocumentIDs.filter { documentMap[$0] == nil }
            if missingDocumentIDs.isEmpty == false {
                do {
                    let fetchedDocuments = try await dataStore.fetchSearchDocuments(ids: Array(missingDocumentIDs))
                    for document in fetchedDocuments {
                        documentMap[document.id] = document
                    }
                } catch {
                    indexStale = true
                    indexStaleError = indexStaleError ?? error.localizedDescription
                }
            }

            let readableSharedSourceIDs: Set<String>?
            if shouldEnforceSharedArtifactAccess(filters: query.filters, sourceKinds: sourceKinds) {
                if let sharedArtifactAccessContext {
                    do {
                        // Security: this set is the ALLOW-list consulted by `matchesFilters` for
                        // `.sharedArtifact` documents. If the access-control lookup fails we MUST
                        // fail closed — an empty set denies every shared artifact — rather than
                        // letting `try?` swallow the error (a `nil` set would also deny here, but
                        // silently, with no health signal). We additionally mark the index stale so
                        // the failure is observable and the result is reported as degraded.
                        readableSharedSourceIDs = try await dataStore.fetchReadableSharedArtifactSourceIDs(
                            accessContext: sharedArtifactAccessContext
                        )
                    } catch {
                        readableSharedSourceIDs = Set<String>()
                        indexStale = true
                        indexStaleError = indexStaleError ?? error.localizedDescription
                        AppLogger.search.error(
                            "shared_artifact_access_lookup_failed",
                            metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                        )
                    }
                } else {
                    readableSharedSourceIDs = Set<String>()
                }
            } else {
                readableSharedSourceIDs = nil
            }

            // Batch preload conversations to eliminate N+1 queries during scoring.
            // Extract all unique conversation sourceIDs from the candidate set.
            var conversationCache: [String: OpenBurnBarCore.ConversationRecord?] = [:]
            let conversationSourceIDs = Set(boundedChunkIDs.compactMap { chunkID -> String? in
                guard let chunk = chunkMap[chunkID],
                      let document = documentMap[chunk.documentID],
                      document.sourceKind == .conversation else { return nil }
                return document.sourceID
            })
            if !conversationSourceIDs.isEmpty {
                do {
                    let batchConversations = try await dataStore.fetchConversations(ids: Array(conversationSourceIDs))
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

                let conversation: OpenBurnBarCore.ConversationRecord?
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
                await persistQueryHealth(
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
                    let typed = OpenBurnBarError.search(
                        "cross_encoder_rerank_failed",
                        message: "Cross-encoder reranking failed.",
                        underlying: error
                    )
                    setLastHealthWriteError(typed.message, typed: typed)
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
            await persistQueryHealth(
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
