import Foundation
import OpenBurnBarCore

// MARK: - Semantic Candidate

/// A candidate from semantic search with its relevance score.
struct SemanticCandidate: Sendable {
    let chunkID: String
    let score: Double
}

// MARK: - Performance Metrics

private struct SemanticQueryPerformanceMetrics: Codable {
    let queryEmbeddingLatencyMs: Double?
    let indexRefreshLatencyMs: Double?
    let candidateGenerationLatencyMs: Double?
    let annCandidateGenerationLatencyMs: Double?
    let exactRerankLatencyMs: Double?
    let fallbackExactLatencyMs: Double?
    let totalQueryLatencyMs: Double?
}

private struct SemanticRetrievalHealthDetails: Codable {
    let backend: String
    let configuredBackend: String
    let embeddingVersionID: String?
    let indexedVectorCount: Int
    let indexedDimensions: Int
    let queryDimensions: Int?
    let candidateCount: Int
    let fallbackToExact: Bool
    let exactRerankEnabled: Bool
    let queryEmbeddingLatencyMs: Double?
    let indexRefreshLatencyMs: Double?
    let candidateGenerationLatencyMs: Double?
    let annCandidateGenerationLatencyMs: Double?
    let exactRerankLatencyMs: Double?
    let fallbackExactLatencyMs: Double?
    let totalQueryLatencyMs: Double?
}

// MARK: - Vector Semantic Candidate Provider

/// Provider that uses vector similarity for semantic search.
/// Manages ANN/exact backends and handles embedding resolution.

final class VectorSemanticCandidateProvider: SemanticCandidateProviding {
    private struct ActiveEmbeddingSelection {
        let model: EmbeddingModelRecord
        let version: EmbeddingVersionRecord
    }

    private struct CandidateGatherMetrics {
        var candidateGenerationLatencyMs: Double?
        var annCandidateGenerationLatencyMs: Double?
        var exactRerankLatencyMs: Double?
        var fallbackExactLatencyMs: Double?
    }

    private let dataStore: DataStore
    private let queryEmbedder: QueryEmbeddingProviding
    private let configuredEmbeddingVersionID: String?
    private let backend: VectorBackendKind
    private let exactRerankEnabled: Bool
    private let exactRerankLimit: Int
    private let nowProvider: () -> Date
    private let annBackend: SignpostANNVectorCandidateBackend
    private let exactBackend: ExactVectorCandidateBackend

    private var vectorsByChunkID: [String: [Float]] = [:]
    private var indexFingerprint: String?
    private var indexedEmbeddingVersionID: String?
    private var indexedDistanceMetric: EmbeddingDistanceMetric = .cosine
    private var indexedVectorCount = 0
    private var indexedDimensions = 0
    private(set) var lastHealthWriteError: String?

    init(
        dataStore: DataStore,
        queryEmbedder: QueryEmbeddingProviding,
        embeddingVersionID: String? = nil,
        backend: VectorBackendKind = .ann,
        exactRerankEnabled: Bool = true,
        exactRerankLimit: Int = 320,
        annCandidateMultiplier: Int = 6,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.dataStore = dataStore
        self.queryEmbedder = queryEmbedder
        self.configuredEmbeddingVersionID = embeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.backend = backend
        self.exactRerankEnabled = exactRerankEnabled
        self.exactRerankLimit = max(1, min(exactRerankLimit, 5_000))
        self.nowProvider = nowProvider
        self.annBackend = SignpostANNVectorCandidateBackend(candidateMultiplier: annCandidateMultiplier)
        self.exactBackend = ExactVectorCandidateBackend()
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        guard limit > 0 else { return [] }
        let queryStartedAt = OpenBurnBarPerformanceTimer.now()
        var queryEmbeddingLatencyMs: Double?
        var indexRefreshLatencyMs: Double?
        var gatherMetrics = CandidateGatherMetrics()

        let queryVector: [Float]
        let queryEmbeddingStartedAt = OpenBurnBarPerformanceTimer.now()
        do {
            queryVector = try await queryEmbedder.embedding(for: query)
            queryEmbeddingLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryEmbeddingStartedAt)
        } catch {
            await persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: nil,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_QUERY_EMBEDDING_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryEmbeddingStartedAt),
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }
        guard queryVector.isEmpty == false else { return [] }

        let indexRefreshStartedAt = OpenBurnBarPerformanceTimer.now()
        do {
            try await refreshIndexIfNeeded(queryDimensions: queryVector.count)
            indexRefreshLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: indexRefreshStartedAt)
        } catch {
            await persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_INDEX_BUILD_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: indexRefreshStartedAt),
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }

        guard indexedVectorCount > 0 else {
            await persistSemanticHealth(
                status: .degraded,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_NO_EMBEDDINGS",
                errorMessage: "No chunk embeddings are available for semantic retrieval.",
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            return []
        }

        do {
            let (candidates, fallbackUsed, metrics) = try gatherCandidates(queryVector: queryVector, limit: limit)
            gatherMetrics = metrics
            let semanticCandidates = candidates.map { SemanticCandidate(chunkID: $0.chunkID, score: $0.score) }
            await persistSemanticHealth(
                status: fallbackUsed ? .degraded : .healthy,
                backendUsed: fallbackUsed ? VectorBackendKind.exact.rawValue : backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: semanticCandidates.count,
                fallbackUsed: fallbackUsed,
                errorCode: fallbackUsed ? "SEMANTIC_ANN_FALLBACK_TO_EXACT" : nil,
                errorMessage: fallbackUsed ? "ANN candidate generation failed; exact fallback path served the query." : nil,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: metrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: metrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: metrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: metrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            return semanticCandidates
        } catch {
            await persistSemanticHealth(
                status: .failed,
                backendUsed: backend.rawValue,
                embeddingVersionID: indexedEmbeddingVersionID,
                vectorCount: indexedVectorCount,
                queryDimensions: queryVector.count,
                candidateCount: 0,
                fallbackUsed: false,
                errorCode: "SEMANTIC_BACKEND_QUERY_FAILED",
                errorMessage: error.localizedDescription,
                performanceMetrics: SemanticQueryPerformanceMetrics(
                    queryEmbeddingLatencyMs: queryEmbeddingLatencyMs,
                    indexRefreshLatencyMs: indexRefreshLatencyMs,
                    candidateGenerationLatencyMs: gatherMetrics.candidateGenerationLatencyMs,
                    annCandidateGenerationLatencyMs: gatherMetrics.annCandidateGenerationLatencyMs,
                    exactRerankLatencyMs: gatherMetrics.exactRerankLatencyMs,
                    fallbackExactLatencyMs: gatherMetrics.fallbackExactLatencyMs,
                    totalQueryLatencyMs: OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: queryStartedAt)
                )
            )
            throw error
        }
    }

    private func persistSemanticHealth(
        status: RetrievalHealthStatus,
        backendUsed: String,
        embeddingVersionID: String?,
        vectorCount: Int,
        queryDimensions: Int?,
        candidateCount: Int,
        fallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        performanceMetrics: SemanticQueryPerformanceMetrics?
    ) async {
        do {
            try await upsertSemanticHealth(
                status: status,
                backendUsed: backendUsed,
                embeddingVersionID: embeddingVersionID,
                vectorCount: vectorCount,
                queryDimensions: queryDimensions,
                candidateCount: candidateCount,
                fallbackUsed: fallbackUsed,
                errorCode: errorCode,
                errorMessage: errorMessage,
                performanceMetrics: performanceMetrics
            )
            lastHealthWriteError = nil
        } catch {
            lastHealthWriteError = error.localizedDescription
        }
    }

    private func gatherCandidates(queryVector: [Float], limit: Int) throws -> ([VectorIndexCandidate], Bool, CandidateGatherMetrics) {
        let boundedLimit = min(limit, indexedVectorCount)
        var metrics = CandidateGatherMetrics()
        switch backend {
        case .exact:
            let exactStartedAt = OpenBurnBarPerformanceTimer.now()
            let candidates = try exactBackend.candidates(for: queryVector, limit: boundedLimit)
            metrics.candidateGenerationLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: exactStartedAt)
            return (candidates, false, metrics)
        case .ann:
            let annStartedAt = OpenBurnBarPerformanceTimer.now()
            do {
                let candidateLimit = min(indexedVectorCount, max(boundedLimit, exactRerankEnabled ? exactRerankLimit : boundedLimit))
                let annCandidates = try annBackend.candidates(for: queryVector, limit: candidateLimit)
                let annLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: annStartedAt)
                metrics.annCandidateGenerationLatencyMs = annLatencyMs
                metrics.candidateGenerationLatencyMs = annLatencyMs
                if exactRerankEnabled {
                    let rerankStartedAt = OpenBurnBarPerformanceTimer.now()
                    let reranked = exactRerank(candidates: annCandidates, queryVector: queryVector, limit: boundedLimit)
                    metrics.exactRerankLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: rerankStartedAt)
                    return (reranked, false, metrics)
                }
                return (Array(annCandidates.prefix(boundedLimit)), false, metrics)
            } catch {
                let annLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: annStartedAt)
                metrics.annCandidateGenerationLatencyMs = annLatencyMs
                let fallbackStartedAt = OpenBurnBarPerformanceTimer.now()
                let fallbackCandidates = try exactBackend.candidates(for: queryVector, limit: boundedLimit)
                let fallbackLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: fallbackStartedAt)
                metrics.fallbackExactLatencyMs = fallbackLatencyMs
                metrics.candidateGenerationLatencyMs = annLatencyMs + fallbackLatencyMs
                return (fallbackCandidates, true, metrics)
            }
        }
    }

    private func exactRerank(candidates: [VectorIndexCandidate], queryVector: [Float], limit: Int) -> [VectorIndexCandidate] {
        guard candidates.isEmpty == false else { return [] }
        var reranked: [VectorIndexCandidate] = []
        reranked.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let vector = vectorsByChunkID[candidate.chunkID] else { continue }
            let exactScore = VectorMath.similarity(lhs: queryVector, rhs: vector, metric: indexedDistanceMetric)
            guard exactScore.isFinite else { continue }
            reranked.append(VectorIndexCandidate(chunkID: candidate.chunkID, score: exactScore))
        }

        reranked.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }
        if reranked.count > limit {
            return Array(reranked.prefix(limit))
        }
        return reranked
    }

    private func refreshIndexIfNeeded(queryDimensions: Int) async throws {
        guard let selection = try await resolveEmbeddingSelection() else {
            resetIndex()
            return
        }

        let embeddings = try dataStore.fetchChunkEmbeddings(embeddingVersionID: selection.version.id)
        let sortedEmbeddings = embeddings.sorted {
            if $0.chunkID == $1.chunkID {
                return $0.updatedAt < $1.updatedAt
            }
            return $0.chunkID < $1.chunkID
        }
        let newestEmbeddingEpoch = sortedEmbeddings.map(\.updatedAt.timeIntervalSince1970).max() ?? 0
        let fingerprint = [
            selection.version.id,
            selection.model.distanceMetric.rawValue,
            String(selection.model.dimensions),
            String(sortedEmbeddings.count),
            String(Int(newestEmbeddingEpoch))
        ].joined(separator: "|")

        if fingerprint == indexFingerprint,
           indexedDimensions == selection.model.dimensions,
           indexedEmbeddingVersionID == selection.version.id {
            if indexedDimensions != queryDimensions {
                throw VectorIndexBackendError.dimensionMismatch(expected: indexedDimensions, actual: queryDimensions)
            }
            return
        }

        var entries: [VectorIndexEntry] = []
        entries.reserveCapacity(sortedEmbeddings.count)
        var vectors: [String: [Float]] = [:]
        vectors.reserveCapacity(sortedEmbeddings.count)

        for embedding in sortedEmbeddings {
            guard let vector = VectorBlobCodec.decode(embedding.vectorBlob) else { continue }
            guard vector.count == selection.model.dimensions else { continue }
            entries.append(VectorIndexEntry(chunkID: embedding.chunkID, vector: vector))
            vectors[embedding.chunkID] = vector
        }

        guard entries.isEmpty == false else {
            resetIndex()
            indexedEmbeddingVersionID = selection.version.id
            indexedDistanceMetric = selection.model.distanceMetric
            indexedDimensions = selection.model.dimensions
            return
        }

        try annBackend.rebuild(entries: entries, distanceMetric: selection.model.distanceMetric)
        try exactBackend.rebuild(entries: entries, distanceMetric: selection.model.distanceMetric)

        vectorsByChunkID = vectors
        indexFingerprint = fingerprint
        indexedEmbeddingVersionID = selection.version.id
        indexedDistanceMetric = selection.model.distanceMetric
        indexedVectorCount = entries.count
        indexedDimensions = selection.model.dimensions

        if indexedDimensions != queryDimensions {
            throw VectorIndexBackendError.dimensionMismatch(expected: indexedDimensions, actual: queryDimensions)
        }
    }

    private func resolveEmbeddingSelection() async throws -> ActiveEmbeddingSelection? {
        let models = try dataStore.fetchEmbeddingModels()
        guard models.isEmpty == false else { return nil }
        let modelByID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let versions = try dataStore.fetchEmbeddingVersions()
        guard versions.isEmpty == false else { return nil }

        let selectedVersion: EmbeddingVersionRecord?
        if let configuredEmbeddingVersionID, configuredEmbeddingVersionID.isEmpty == false {
            selectedVersion = versions.first(where: { $0.id == configuredEmbeddingVersionID })
        } else {
            selectedVersion = versions.first(where: \.isActive) ?? versions.first
        }
        guard let version = selectedVersion, let model = modelByID[version.modelID] else {
            return nil
        }
        return ActiveEmbeddingSelection(model: model, version: version)
    }

    private func resetIndex() {
        vectorsByChunkID = [:]
        indexFingerprint = nil
        indexedEmbeddingVersionID = nil
        indexedDistanceMetric = .cosine
        indexedVectorCount = 0
        indexedDimensions = 0
    }

    private func upsertSemanticHealth(
        status: RetrievalHealthStatus,
        backendUsed: String,
        embeddingVersionID: String?,
        vectorCount: Int,
        queryDimensions: Int?,
        candidateCount: Int,
        fallbackUsed: Bool,
        errorCode: String?,
        errorMessage: String?,
        performanceMetrics: SemanticQueryPerformanceMetrics?
    ) async throws {
        let now = nowProvider()
        let details = SemanticRetrievalHealthDetails(
            backend: backendUsed,
            configuredBackend: backend.rawValue,
            embeddingVersionID: embeddingVersionID,
            indexedVectorCount: vectorCount,
            indexedDimensions: indexedDimensions,
            queryDimensions: queryDimensions,
            candidateCount: candidateCount,
            fallbackToExact: fallbackUsed,
            exactRerankEnabled: exactRerankEnabled,
            queryEmbeddingLatencyMs: performanceMetrics?.queryEmbeddingLatencyMs,
            indexRefreshLatencyMs: performanceMetrics?.indexRefreshLatencyMs,
            candidateGenerationLatencyMs: performanceMetrics?.candidateGenerationLatencyMs,
            annCandidateGenerationLatencyMs: performanceMetrics?.annCandidateGenerationLatencyMs,
            exactRerankLatencyMs: performanceMetrics?.exactRerankLatencyMs,
            fallbackExactLatencyMs: performanceMetrics?.fallbackExactLatencyMs,
            totalQueryLatencyMs: performanceMetrics?.totalQueryLatencyMs
        )
        let detailsData = try JSONEncoder().encode(details)
        let detailsJSON = String(data: detailsData, encoding: .utf8)
        try dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
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
