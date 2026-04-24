import Foundation
import OpenBurnBarCore

struct SemanticCandidate: Sendable {
    let chunkID: String
    let score: Double
}

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
    let snapshotState: String?
    let snapshotFileBytes: Int64?
    let snapshotBuiltAt: Date?
    let snapshotBackendVersion: String?
    let queryEmbeddingLatencyMs: Double?
    let indexRefreshLatencyMs: Double?
    let candidateGenerationLatencyMs: Double?
    let annCandidateGenerationLatencyMs: Double?
    let exactRerankLatencyMs: Double?
    let fallbackExactLatencyMs: Double?
    let totalQueryLatencyMs: Double?
}

private extension EmbeddingDistanceMetric {
    var burnBarCoreMetric: BurnBarEmbeddingDistanceMetric {
        switch self {
        case .cosine:
            return .cosine
        case .dotProduct:
            return .dotProduct
        case .euclidean:
            return .euclidean
        }
    }
}

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

    private struct SnapshotContext {
        let embeddingVersionID: String
        let fingerprint: String
        let snapshot: BurnBarPersistentVectorIndexSnapshot?
        let snapshotRecord: VectorIndexSnapshotRecord?
    }

    private let dataStore: DataStore
    private let queryEmbedder: QueryEmbeddingProviding
    private let configuredEmbeddingVersionID: String?
    private let backend: VectorBackendKind
    private let exactRerankEnabled: Bool
    private let exactRerankLimit: Int
    private let nowProvider: () -> Date
    private let storageRootURL: URL
    private let storageNamespace: String
    private let snapshotBackend: any BurnBarPersistentVectorIndexBackend
    private let snapshotPageSize: Int

    private var snapshotContext: SnapshotContext?
    private var indexedEmbeddingVersionID: String?
    private var indexedDistanceMetric: EmbeddingDistanceMetric = .cosine
    private var indexedVectorCount = 0
    private var indexedDimensions = 0
    private var lastSnapshotState: VectorIndexSnapshotState?
    private var lastSnapshotFileBytes: Int64?
    private var lastSnapshotBuiltAt: Date?
    private var lastSnapshotBackendVersion: String?
    private(set) var lastHealthWriteError: String?

    init(
        dataStore: DataStore,
        queryEmbedder: QueryEmbeddingProviding,
        embeddingVersionID: String? = nil,
        backend: VectorBackendKind = .ann,
        exactRerankEnabled: Bool = true,
        exactRerankLimit: Int = 320,
        nowProvider: @escaping () -> Date = Date.init,
        storageRootURL: URL = OpenBurnBarAppPaths.live().vectorIndexesRootURL,
        storageNamespace: String = "app",
        snapshotBackend: any BurnBarPersistentVectorIndexBackend = BurnBarPersistentVectorIndexFactory.defaultBackend(),
        snapshotPageSize: Int = 1_000
    ) {
        self.dataStore = dataStore
        self.queryEmbedder = queryEmbedder
        self.configuredEmbeddingVersionID = embeddingVersionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.backend = backend
        self.exactRerankEnabled = exactRerankEnabled
        self.exactRerankLimit = max(1, min(exactRerankLimit, 5_000))
        self.nowProvider = nowProvider
        self.storageRootURL = storageRootURL
        self.storageNamespace = storageNamespace
        self.snapshotBackend = snapshotBackend
        self.snapshotPageSize = max(1, snapshotPageSize)
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
                errorMessage: fallbackUsed ? "Persistent ANN snapshot was unavailable; streaming exact fallback served the query." : nil,
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
        guard boundedLimit > 0 else { return ([], false, CandidateGatherMetrics()) }

        var metrics = CandidateGatherMetrics()
        switch backend {
        case .exact:
            let startedAt = OpenBurnBarPerformanceTimer.now()
            let candidates = try streamingExactCandidates(queryVector: queryVector, limit: boundedLimit)
            let elapsed = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: startedAt)
            metrics.fallbackExactLatencyMs = elapsed
            metrics.candidateGenerationLatencyMs = elapsed
            return (candidates, false, metrics)

        case .ann:
            if let snapshot = snapshotContext?.snapshot {
                let annStartedAt = OpenBurnBarPerformanceTimer.now()
                let candidateLimit = min(indexedVectorCount, max(boundedLimit, exactRerankEnabled ? exactRerankLimit : boundedLimit))
                let annCandidates = try snapshot.candidates(for: queryVector, limit: candidateLimit).map {
                    VectorIndexCandidate(chunkID: $0.chunkID, score: $0.score)
                }
                let annLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: annStartedAt)
                metrics.annCandidateGenerationLatencyMs = annLatencyMs
                metrics.candidateGenerationLatencyMs = annLatencyMs

                if exactRerankEnabled {
                    let rerankStartedAt = OpenBurnBarPerformanceTimer.now()
                    let reranked = try exactRerank(
                        candidates: annCandidates,
                        queryVector: queryVector,
                        limit: boundedLimit
                    )
                    metrics.exactRerankLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: rerankStartedAt)
                    metrics.candidateGenerationLatencyMs = annLatencyMs + (metrics.exactRerankLatencyMs ?? 0)
                    return (reranked, false, metrics)
                }

                return (Array(annCandidates.prefix(boundedLimit)), false, metrics)
            }

            let fallbackStartedAt = OpenBurnBarPerformanceTimer.now()
            let fallback = try streamingExactCandidates(queryVector: queryVector, limit: boundedLimit)
            let fallbackLatencyMs = OpenBurnBarPerformanceTimer.elapsedMilliseconds(since: fallbackStartedAt)
            metrics.fallbackExactLatencyMs = fallbackLatencyMs
            metrics.candidateGenerationLatencyMs = fallbackLatencyMs
            return (fallback, true, metrics)
        }
    }

    private func exactRerank(
        candidates: [VectorIndexCandidate],
        queryVector: [Float],
        limit: Int
    ) throws -> [VectorIndexCandidate] {
        guard let embeddingVersionID = indexedEmbeddingVersionID, candidates.isEmpty == false else { return [] }
        let chunkIDs = candidates.map(\.chunkID)
        let embeddings = try dataStore.fetchChunkEmbeddings(chunkIDs: chunkIDs, embeddingVersionID: embeddingVersionID)
        let vectorByChunkID = Dictionary(uniqueKeysWithValues: embeddings.compactMap { embedding in
            VectorBlobCodec.decode(embedding.vectorBlob).map { (embedding.chunkID, $0) }
        })

        var reranked: [VectorIndexCandidate] = []
        reranked.reserveCapacity(candidates.count)

        for candidate in candidates {
            guard let vector = vectorByChunkID[candidate.chunkID] else { continue }
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
        return Array(reranked.prefix(limit))
    }

    private func streamingExactCandidates(queryVector: [Float], limit: Int) throws -> [VectorIndexCandidate] {
        guard let embeddingVersionID = indexedEmbeddingVersionID else { return [] }

        var best: [VectorIndexCandidate] = []
        best.reserveCapacity(limit)
        var offset = 0

        while true {
            let page = try dataStore.fetchChunkEmbeddings(
                embeddingVersionID: embeddingVersionID,
                limit: snapshotPageSize,
                offset: offset
            )
            guard page.isEmpty == false else { break }

            for record in page {
                guard let vector = VectorBlobCodec.decode(record.vectorBlob) else { continue }
                let score = VectorMath.similarity(lhs: queryVector, rhs: vector, metric: indexedDistanceMetric)
                guard score.isFinite else { continue }
                let candidate = VectorIndexCandidate(chunkID: record.chunkID, score: score)
                if best.count < limit {
                    best.append(candidate)
                    best.sort(by: candidateSort)
                } else if let last = best.last, candidateSort(candidate, last) {
                    best.removeLast()
                    best.append(candidate)
                    best.sort(by: candidateSort)
                }
            }

            offset += page.count
            if page.count < snapshotPageSize { break }
        }

        return best
    }

    private func refreshIndexIfNeeded(queryDimensions: Int) async throws {
        guard let selection = try await resolveEmbeddingSelection() else {
            resetIndex()
            return
        }

        let stats = try dataStore.chunkEmbeddingVersionStats(embeddingVersionID: selection.version.id)
        let newestEmbeddingEpoch = Int(stats.newestUpdatedAt?.timeIntervalSince1970 ?? 0)
        let fingerprint = [
            selection.version.id,
            selection.model.distanceMetric.rawValue,
            String(selection.model.dimensions),
            String(stats.vectorCount),
            String(newestEmbeddingEpoch)
        ].joined(separator: "|")

        indexedEmbeddingVersionID = selection.version.id
        indexedDistanceMetric = selection.model.distanceMetric
        indexedVectorCount = stats.vectorCount
        indexedDimensions = selection.model.dimensions

        if queryDimensions != indexedDimensions {
            throw VectorIndexBackendError.dimensionMismatch(expected: indexedDimensions, actual: queryDimensions)
        }

        if stats.vectorCount == 0 {
            snapshotContext = SnapshotContext(
                embeddingVersionID: selection.version.id,
                fingerprint: fingerprint,
                snapshot: nil,
                snapshotRecord: nil
            )
            lastSnapshotState = nil
            lastSnapshotFileBytes = nil
            lastSnapshotBuiltAt = nil
            lastSnapshotBackendVersion = nil
            return
        }

        if let snapshotContext,
           snapshotContext.embeddingVersionID == selection.version.id,
           snapshotContext.fingerprint == fingerprint {
            syncSnapshotMetadata(from: snapshotContext.snapshotRecord)
            return
        }

        let record = try dataStore.fetchVectorIndexSnapshot(
            embeddingVersionID: selection.version.id,
            backendID: snapshotBackend.backendID
        )

        if let record,
           record.state == .ready,
           record.fingerprint == fingerprint,
           let snapshot = try loadSnapshotIfPresent(from: record) {
            snapshotContext = SnapshotContext(
                embeddingVersionID: selection.version.id,
                fingerprint: fingerprint,
                snapshot: snapshot,
                snapshotRecord: record
            )
            syncSnapshotMetadata(from: record)
            return
        }

        let builtRecord = try rebuildSnapshot(selection: selection, fingerprint: fingerprint, existingRecord: record)
        let builtSnapshot = try loadSnapshotIfPresent(from: builtRecord)
        snapshotContext = SnapshotContext(
            embeddingVersionID: selection.version.id,
            fingerprint: fingerprint,
            snapshot: builtSnapshot,
            snapshotRecord: builtRecord
        )
        syncSnapshotMetadata(from: builtRecord)
    }

    private func rebuildSnapshot(
        selection: ActiveEmbeddingSelection,
        fingerprint: String,
        existingRecord: VectorIndexSnapshotRecord?
    ) throws -> VectorIndexSnapshotRecord {
        let builtAt = nowProvider()
        let generation = UUID().uuidString
        let databasePrefix = storageNamespace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "app" : storageNamespace
        let relativeParent = "\(databasePrefix)/\(selection.version.id)/\(snapshotBackend.backendID)"
        let finalRelativePath = "\(relativeParent)/\(generation)"
        let tempRelativePath = "\(relativeParent)/tmp-\(generation)"
        let tempFiles = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(tempRelativePath, isDirectory: true)
        )
        let finalFiles = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(finalRelativePath, isDirectory: true)
        )

        let buildingRecord = VectorIndexSnapshotRecord(
            embeddingVersionID: selection.version.id,
            backendID: snapshotBackend.backendID,
            state: .building,
            fingerprint: fingerprint,
            dimensions: selection.model.dimensions,
            distanceMetric: selection.model.distanceMetric,
            vectorCount: indexedVectorCount,
            storageRelativePath: existingRecord?.storageRelativePath,
            fileBytes: existingRecord?.fileBytes ?? 0,
            backendVersion: snapshotBackend.backendVersion,
            errorCode: nil,
            errorMessage: nil,
            createdAt: existingRecord?.createdAt ?? builtAt,
            updatedAt: builtAt,
            lastBuiltAt: existingRecord?.lastBuiltAt
        )
        try dataStore.upsertVectorIndexSnapshot(buildingRecord)

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: tempFiles.directoryURL)
        try fileManager.createDirectory(at: tempFiles.directoryURL, withIntermediateDirectories: true, attributes: nil)

        do {
            let chunkIDs = try allChunkIDs(for: selection.version.id)
            let keyByChunkID = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: chunkIDs)
            let writer = try snapshotBackend.makeWritable(
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric.burnBarCoreMetric
            )
            try writer.reserve(indexedVectorCount)

            var offset = 0
            while true {
                let page = try dataStore.fetchChunkEmbeddings(
                    embeddingVersionID: selection.version.id,
                    limit: snapshotPageSize,
                    offset: offset
                )
                guard page.isEmpty == false else { break }

                for record in page {
                    guard
                        let key = keyByChunkID[record.chunkID],
                        let vector = VectorBlobCodec.decode(record.vectorBlob),
                        vector.count == selection.model.dimensions
                    else { continue }
                    try writer.add(key: key, vector: vector)
                }

                offset += page.count
                if page.count < snapshotPageSize { break }
            }

            try writer.save(to: tempFiles.indexURL)
            let manifest = BurnBarPersistentVectorIndexManifest(
                backendID: snapshotBackend.backendID,
                backendVersion: snapshotBackend.backendVersion,
                embeddingVersionID: selection.version.id,
                fingerprint: fingerprint,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric.burnBarCoreMetric,
                vectorCount: indexedVectorCount,
                builtAt: builtAt
            )
            try BurnBarPersistentVectorIndexSnapshotIO.writeManifest(manifest, to: tempFiles.manifestURL)
            try BurnBarPersistentVectorIndexSnapshotIO.writeKeyMapping(keyByChunkID, to: tempFiles.keyMappingURL)

            try fileManager.createDirectory(
                at: finalFiles.directoryURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? fileManager.removeItem(at: finalFiles.directoryURL)
            try fileManager.moveItem(at: tempFiles.directoryURL, to: finalFiles.directoryURL)

            let readyRecord = VectorIndexSnapshotRecord(
                embeddingVersionID: selection.version.id,
                backendID: snapshotBackend.backendID,
                state: .ready,
                fingerprint: fingerprint,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric,
                vectorCount: indexedVectorCount,
                storageRelativePath: finalRelativePath,
                fileBytes: BurnBarPersistentVectorIndexSnapshotIO.fileByteCount(at: finalFiles.indexURL),
                backendVersion: snapshotBackend.backendVersion,
                errorCode: nil,
                errorMessage: nil,
                createdAt: existingRecord?.createdAt ?? builtAt,
                updatedAt: builtAt,
                lastBuiltAt: builtAt
            )
            try dataStore.upsertVectorIndexSnapshot(readyRecord)

            if let previousPath = existingRecord?.storageRelativePath, previousPath != finalRelativePath {
                try? fileManager.removeItem(at: storageRootURL.appendingPathComponent(previousPath, isDirectory: true))
            }

            return readyRecord
        } catch {
            try? fileManager.removeItem(at: tempFiles.directoryURL)
            let failedRecord = VectorIndexSnapshotRecord(
                embeddingVersionID: selection.version.id,
                backendID: snapshotBackend.backendID,
                state: .failed,
                fingerprint: fingerprint,
                dimensions: selection.model.dimensions,
                distanceMetric: selection.model.distanceMetric,
                vectorCount: indexedVectorCount,
                storageRelativePath: existingRecord?.storageRelativePath,
                fileBytes: existingRecord?.fileBytes ?? 0,
                backendVersion: snapshotBackend.backendVersion,
                errorCode: "VECTOR_SNAPSHOT_BUILD_FAILED",
                errorMessage: error.localizedDescription,
                createdAt: existingRecord?.createdAt ?? builtAt,
                updatedAt: builtAt,
                lastBuiltAt: existingRecord?.lastBuiltAt
            )
            try dataStore.upsertVectorIndexSnapshot(failedRecord)
            throw error
        }
    }

    private func allChunkIDs(for embeddingVersionID: String) throws -> [String] {
        var result: [String] = []
        var offset = 0
        while true {
            let page = try dataStore.fetchChunkEmbeddings(
                embeddingVersionID: embeddingVersionID,
                limit: snapshotPageSize,
                offset: offset
            )
            guard page.isEmpty == false else { break }
            result.append(contentsOf: page.map(\.chunkID))
            offset += page.count
            if page.count < snapshotPageSize { break }
        }
        return result
    }

    private func loadSnapshotIfPresent(from record: VectorIndexSnapshotRecord) throws -> BurnBarPersistentVectorIndexSnapshot? {
        guard let relativePath = record.storageRelativePath, relativePath.isEmpty == false else { return nil }
        let files = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(relativePath, isDirectory: true)
        )
        guard FileManager.default.fileExists(atPath: files.indexURL.path) else { return nil }
        return try BurnBarPersistentVectorIndexSnapshot.open(files: files, backend: snapshotBackend)
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
        snapshotContext = nil
        indexedEmbeddingVersionID = nil
        indexedDistanceMetric = .cosine
        indexedVectorCount = 0
        indexedDimensions = 0
        lastSnapshotState = nil
        lastSnapshotFileBytes = nil
        lastSnapshotBuiltAt = nil
        lastSnapshotBackendVersion = nil
    }

    private func syncSnapshotMetadata(from record: VectorIndexSnapshotRecord?) {
        lastSnapshotState = record?.state
        lastSnapshotFileBytes = record?.fileBytes
        lastSnapshotBuiltAt = record?.lastBuiltAt
        lastSnapshotBackendVersion = record?.backendVersion
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
            snapshotState: lastSnapshotState?.rawValue,
            snapshotFileBytes: lastSnapshotFileBytes,
            snapshotBuiltAt: lastSnapshotBuiltAt,
            snapshotBackendVersion: lastSnapshotBackendVersion,
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

    private func candidateSort(_ lhs: VectorIndexCandidate, _ rhs: VectorIndexCandidate) -> Bool {
        if lhs.score == rhs.score {
            return lhs.chunkID < rhs.chunkID
        }
        return lhs.score > rhs.score
    }
}
