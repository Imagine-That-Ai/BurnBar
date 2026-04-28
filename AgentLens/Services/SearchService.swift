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
    private let dataStore: DataStore
    private let semanticProvider: SemanticCandidateProviding?
    private let reranker: RetrievalRerankProviding?
    private let sharedArtifactAccessContextProvider: @MainActor () -> SharedArtifactAccessContext?
    private let nowProvider: () -> Date

    private var _lastHealthWriteError: String?

    /// May be read from the main thread or tests while retrieval runs in the background.
    public var lastHealthWriteError: String? {
        get { _lastHealthWriteError }
    }

    private func setLastHealthWriteError(_ value: String?) {
        _lastHealthWriteError = value
    }

    /// Preferred initializer when shared-artifact access should resolve against the live account; requires a
    /// `MainActor` snapshotter (use ``makeConversationSearchService(dataStore:settingsManager:providerAPIKeyStore:nowProvider:)`` in app code).
    init(
        dataStore: DataStore,
        semanticProvider: SemanticCandidateProviding? = nil,
        reranker: RetrievalRerankProviding? = nil,
        sharedArtifactAccessContextProvider: @escaping @MainActor () -> SharedArtifactAccessContext?,
        nowProvider: @escaping () -> Date
    ) {
        self.dataStore = dataStore
        self.semanticProvider = semanticProvider
        self.reranker = reranker
        self.sharedArtifactAccessContextProvider = sharedArtifactAccessContextProvider
        self.nowProvider = nowProvider
    }

    /// Tests and call sites that do not use shared artifacts may omit the provider; context resolves to `nil`.
    convenience init(
        dataStore: DataStore,
        semanticProvider: SemanticCandidateProviding? = nil,
        reranker: RetrievalRerankProviding? = nil,
        nowProvider: @escaping () -> Date = { Date() }
    ) {
        self.init(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            reranker: reranker,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: nowProvider
        )
    }

    @MainActor
    static func makeConversationSearchService(
        dataStore: DataStore,
        settingsManager: SettingsManager = .shared,
        providerAPIKeyStore: ProviderAPIKeyStore = .shared,
        nowProvider: @escaping () -> Date = { Date() }
    ) -> SearchService {
        let selection = resolvedEmbeddingSelection(
            dataStore: dataStore,
            preferredEmbeddingVersionID: settingsManager.preferredIndexEmbeddingVersionIDValue
        )
        let preferredVersionID = selection?.version.id
        let queryEmbedder = makeQueryEmbedder(
            selection: selection,
            providerAPIKeyStore: providerAPIKeyStore
        )
        let semanticProvider = VectorSemanticCandidateProvider(
            dataStore: dataStore,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: preferredVersionID
        )

        // Construct reranker if cross-encoder is enabled and API key is available
        let reranker: RetrievalRerankProviding? = Self.makeReranker(
            settingsManager: settingsManager,
            providerAPIKeyStore: providerAPIKeyStore
        )

        return SearchService(
            dataStore: dataStore,
            semanticProvider: semanticProvider,
            reranker: reranker,
            sharedArtifactAccessContextProvider: SearchService.defaultSharedArtifactAccessContext,
            nowProvider: nowProvider
        )
    }

    @MainActor
    private static func makeReranker(
        settingsManager: SettingsManager,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> RetrievalRerankProviding? {
        guard settingsManager.crossEncoderRerankEnabled else {
            return nil
        }

        let provider = settingsManager.crossEncoderProvider
        let model = CrossEncoderCatalog.normalizedModel(
            settingsManager.crossEncoderModel,
            provider: provider
        )

        switch provider {
        case .codexCLI:
            guard settingsManager.cliAssistantAllowed else {
                return nil
            }
            return CLICrossEncoderReranker(
                provider: .codex,
                modelName: model,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .claudeCLI:
            guard settingsManager.cliAssistantAllowed else {
                return nil
            }
            return CLICrossEncoderReranker(
                provider: .claude,
                modelName: model,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .hermes:
            guard let baseURL = provider.baseURL else {
                return nil
            }
            return OpenAICompatibleCrossEncoderReranker(
                apiKey: "",
                requiresAPIKey: false,
                modelName: model,
                baseURL: baseURL,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )

        case .minimax, .zai, .openrouter:
            guard
                let apiKey = resolveCrossEncoderAPIKey(
                    for: provider,
                    providerAPIKeyStore: providerAPIKeyStore
                ),
                let baseURL = provider.baseURL
            else {
                return nil
            }

            var extraHeaders: [String: String] = [:]
            if provider.includesOpenRouterHeaders {
                extraHeaders["X-Title"] = "OpenBurnBar"
            }

            return OpenAICompatibleCrossEncoderReranker(
                apiKey: apiKey,
                modelName: model,
                baseURL: baseURL,
                extraHeaders: extraHeaders,
                maxCharsPerCandidate: settingsManager.crossEncoderMaxCharsPerCandidate,
                maxCandidatesPerRequest: settingsManager.crossEncoderMaxCandidates
            )
        }
    }

    @MainActor
    private static func resolveCrossEncoderAPIKey(
        for provider: CrossEncoderProviderID,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> String? {
        func nonEmpty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.isEmpty == false else {
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
        case .codexCLI, .claudeCLI, .hermes:
            return nil
        }
    }

    @MainActor
    private static func makeQueryEmbedder(
        selection: (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)?,
        providerAPIKeyStore: ProviderAPIKeyStore
    ) -> any QueryEmbeddingProviding {
        guard let selection else {
            return DeterministicQueryEmbeddingProvider()
        }

        if selection.model.provider.caseInsensitiveCompare("openai") == .orderedSame {
            if let provider = try? OpenAIEmbeddingProvider(
                apiKey: providerAPIKeyStore.apiKey(for: "openai") ?? "",
                modelName: selection.model.modelName,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            ) {
                return provider
            }
        }

        return DeterministicQueryEmbeddingProvider(
            embedder: DeterministicFakeEmbeddingProvider(
                provider: selection.model.provider,
                modelName: selection.model.modelName,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric,
                versionTag: selection.version.versionTag,
                chunkerVersion: selection.version.chunkerVersion,
                normalizationVersion: selection.version.normalizationVersion,
                promptVersion: selection.version.promptVersion
            )
        )
    }

    private static func resolvedEmbeddingSelection(
        dataStore: DataStore,
        preferredEmbeddingVersionID: String?
    ) -> (model: EmbeddingModelRecord, version: EmbeddingVersionRecord)? {
        guard
            let models = try? dataStore.fetchEmbeddingModels(),
            models.isEmpty == false,
            let versions = try? dataStore.fetchEmbeddingVersions(),
            versions.isEmpty == false
        else {
            return nil
        }

        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let preferred = preferredEmbeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versions.first(where: { $0.id == preferred })
            ?? versions.first(where: \.isActive)
            ?? versions.first

        guard let version, let model = modelByID[version.modelID] else {
            return nil
        }
        return (model, version)
    }

    @MainActor private static func defaultSharedArtifactAccessContext() -> SharedArtifactAccessContext? {
        guard
            let userID = AccountManager.shared.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
            userID.isEmpty == false
        else {
            return nil
        }
        return SharedArtifactAccessContext.defaultScope(for: userID)
    }

    /// `nonisolated` because `dataStore` is an immutable `let` and `fetchConversations`
    /// uses GRDB's synchronous `read` — no actor isolation needed.
    public nonisolated func recentConversations(limit: Int = 80) -> [ConversationRecord] {
        let bounded = max(1, min(limit, 1_000))
        return (try? dataStore.fetchConversations(limit: bounded)) ?? []
    }

    public nonisolated func latestConversation(limit: Int = 200) -> ConversationRecord? {
        latestConversation(in: recentConversations(limit: limit))
    }

    public nonisolated func latestConversation(in conversations: [ConversationRecord]) -> ConversationRecord? {
        conversations.max(by: { a, b in
            let ad = a.endTime ?? a.startTime ?? .distantPast
            let bd = b.endTime ?? b.startTime ?? .distantPast
            return ad < bd
        })
    }

    public func runBurnBarQuery(_ query: RetrievalQuery) async -> OpenBurnBarQueryRunResult {
        let start = Date()
        let result = await runBurnBarQueryInGate(query)
        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        let status: TelemetryOutcome = result.retrievalResults.isEmpty && result.aggregateOccurrenceCount == nil ? .degraded : .success
        TelemetryService.shared.record(feature: .searchRetrieval, outcome: status, durationMs: durationMs)
        OpenBurnBarMetrics.histogram(name: "search_latency_ms", value: Double(durationMs), labels: ["mode": result.plan.mode.rawValue])
        return result
    }

    private func runBurnBarQueryInGate(_ query: RetrievalQuery) async -> OpenBurnBarQueryRunResult {
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
            aggregateCount = (try? dataStore.countOccurrencesInConversationFullText(
                patterns: plan.aggregatePatterns,
                provider: filters.provider,
                projectName: filters.projectName,
                dateRange: filters.dateRange,
                conversationSources: filters.conversationSources
            )) ?? 0
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

    public func retrieve(_ query: RetrievalQuery) async -> [RetrievalResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }
        let accessContext = await MainActor.run { self.sharedArtifactAccessContextProvider() }
        return await retrieveInGate(query, sharedArtifactAccessContext: accessContext)
    }

    /// Core retrieval, invoked on the actor's serial executor; `sharedArtifactAccessContext` is
    /// pre-snapshoted on the main actor by callers.
    private func retrieveInGate(_ query: RetrievalQuery, sharedArtifactAccessContext: SharedArtifactAccessContext?) async -> [RetrievalResult] {
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

    private func lexicalHealthStatus(indexStale: Bool, semanticFallbackUsed: Bool) -> RetrievalHealthStatus {
        if indexStale {
            return .degraded
        }
        if semanticFallbackUsed {
            return .degraded
        }
        return .healthy
    }

    private func lexicalHealthError(
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

    private func persistLexicalHealth(
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

    private func persistSemanticFallbackHealth(
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

    private func normalizedSourceKinds(_ kinds: Set<SearchSourceKind>?) -> [SearchSourceKind]? {
        guard let kinds, kinds.isEmpty == false else { return nil }
        return kinds.sorted { $0.rawValue < $1.rawValue }
    }

    private func normalizedSourceIDs(_ ids: Set<String>?) -> [String]? {
        guard let ids else { return nil }
        let cleaned = ids
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        return cleaned.isEmpty ? nil : cleaned
    }

    private func matchesFilters(
        document: SearchDocumentRecord,
        conversation: ConversationRecord?,
        filters: RetrievalFilters,
        readableSharedSourceIDs: Set<String>?
    ) -> Bool {
        if let provider = filters.provider, document.provider != provider.rawValue {
            return false
        }

        if let projectName = filters.projectName?.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty == false {
            if (document.projectName ?? "").caseInsensitiveCompare(projectName) != .orderedSame {
                return false
            }
        }

        if let artifactTypes = filters.artifactTypes, artifactTypes.isEmpty == false, artifactTypes.contains(document.sourceKind) == false {
            return false
        }

        if let sourceIDs = filters.sourceIDs, sourceIDs.isEmpty == false, sourceIDs.contains(document.sourceID) == false {
            return false
        }

        if document.sourceKind == .sharedArtifact {
            guard
                let readableSharedSourceIDs,
                readableSharedSourceIDs.contains(document.sourceID)
            else {
                return false
            }
        }

        switch filters.ownership {
        case .any:
            break
        case .personal:
            if document.sourceKind == .sharedArtifact { return false }
        case .shared:
            if document.sourceKind != .sharedArtifact { return false }
        }

        if let dateRange = filters.dateRange {
            let date = document.sourceUpdatedAt ?? document.indexedAt
            if date < dateRange.lowerBound || date > dateRange.upperBound {
                return false
            }
        }

        if let conversationSources = filters.conversationSources, conversationSources.isEmpty == false {
            guard document.sourceKind == .conversation, let conversation else { return false }
            if conversationSources.contains(conversation.sourceType) == false {
                return false
            }
        }

        return true
    }

    private func shouldEnforceSharedArtifactAccess(
        filters: RetrievalFilters,
        sourceKinds: [SearchSourceKind]?
    ) -> Bool {
        if filters.ownership == .personal {
            return false
        }

        if let sourceKinds, sourceKinds.contains(.sharedArtifact) == false {
            return false
        }

        if let artifactTypes = filters.artifactTypes,
           artifactTypes.isEmpty == false,
           artifactTypes.contains(.sharedArtifact) == false {
            return false
        }

        return true
    }

    private func recencyScore(_ date: Date) -> Double {
        let ageSeconds = max(0, nowProvider().timeIntervalSince(date))
        let ageDays = ageSeconds / 86_400
        return 1.0 / (1.0 + (ageDays / 30.0))
    }

    private func preliminaryScore(for candidate: CandidateAccumulator) -> Double {
        (Self.normalizedLexicalScore(candidate.lexicalRank) * 0.7) + (max(0, candidate.semanticScore ?? 0) * 0.3)
    }

    /// Reciprocal rank fusion across sparse (lexical) and dense (semantic) orderings.
    private static func reciprocalRankFusion(
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        var score = 0.0
        if let r = lexicalRank { score += 1.0 / (k + Double(r)) }
        if let r = semanticRank { score += 1.0 / (k + Double(r)) }
        return score
    }

    /// Maps RRF raw score to \[0, 1\] given how many retrievers matched this chunk (at rank 1 each would contribute `1/(k+1)`).
    private static func normalizedRRFForRerank(
        _ raw: Double,
        lexicalRank: Int?,
        semanticRank: Int?,
        k: Double
    ) -> Double {
        let lists = (lexicalRank != nil ? 1 : 0) + (semanticRank != nil ? 1 : 0)
        guard lists > 0 else { return 0 }
        let maxPossible = Double(lists) / (k + 1.0)
        guard maxPossible > 0 else { return 0 }
        return min(1.0, raw / maxPossible)
    }

    private static func normalizedLexicalScore(_ lexicalRank: Double?) -> Double {
        guard let lexicalRank else { return 0 }
        return 1.0 / (1.0 + abs(lexicalRank))
    }

    private static func queryTokens(from query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 2 }
    }

    private static func exactTokenCoverageScore(tokens: [String], title: String, chunkText: String) -> Double {
        guard tokens.isEmpty == false else { return 0 }
        let loweredTitle = title.lowercased()
        let loweredChunk = chunkText.lowercased()

        var weightedMatches = 0.0
        for token in tokens {
            if loweredTitle.contains(token) {
                weightedMatches += 2.0
            } else if loweredChunk.contains(token) {
                weightedMatches += 1.0
            }
        }

        let denominator = Double(tokens.count) * 2.0
        guard denominator > 0 else { return 0 }
        return min(1.0, weightedMatches / denominator)
    }

    private static func makeSnippet(lexicalSnippet: String?, chunkText: String, fallback: String) -> String {
        let cleanedLexical = lexicalSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleanedLexical.isEmpty == false {
            return cleanedLexical
        }

        let cleanedChunk = chunkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedChunk.isEmpty == false {
            return String(cleanedChunk.prefix(220))
        }

        return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }

    static func looksLikeSensitiveExactLookup(_ query: String) -> Bool {
        let lower = query.lowercased()
        let patterns = [
            #"\bapi[\s_\-]?keys?\b"#,
            #"\btoken\b"#,
            #"\bsecret\b"#,
            #"\bpassword\b"#,
            #"\.env\b"#,
            #"\bopenai\b"#,
            #"\banthropic\b"#,
            #"\bglm[\s_\-]?api[\s_\-]?key\b"#
        ]
        return patterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}

private struct CandidateAccumulator {
    var lexicalRank: Double?
    var semanticScore: Double?
    var lexicalSnippet: String?
}
