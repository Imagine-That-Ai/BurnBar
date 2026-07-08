import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    func registerMemoryEmbeddingVersion(
        descriptor: EmbeddingModelDescriptor,
        isActive: Bool = true,
        now: Date = Date()
    ) async throws -> MemoryEmbeddingRegistration {
        let modelID = EmbeddingIdentity.modelID(for: descriptor)
        let versionID = EmbeddingIdentity.versionID(for: descriptor)
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO embedding_models (
                    id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    provider = excluded.provider,
                    modelName = excluded.modelName,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    modelID,
                    descriptor.provider,
                    descriptor.modelName,
                    descriptor.dimensions,
                    descriptor.distanceMetric.rawValue,
                    now,
                    now
                ]
            )
            if isActive {
                try db.execute(
                    sql: "UPDATE embedding_versions SET isActive = 0, updatedAt = ? WHERE modelID = ?",
                    arguments: [now, modelID]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion,
                    promptVersion, isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    modelID = excluded.modelID,
                    versionTag = excluded.versionTag,
                    chunkerVersion = excluded.chunkerVersion,
                    normalizationVersion = excluded.normalizationVersion,
                    promptVersion = excluded.promptVersion,
                    isActive = excluded.isActive,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    versionID,
                    modelID,
                    descriptor.versionTag,
                    descriptor.chunkerVersion,
                    descriptor.normalizationVersion,
                    descriptor.promptVersion,
                    isActive,
                    now,
                    now
                ]
            )
        }
        return MemoryEmbeddingRegistration(
            modelID: modelID,
            versionID: versionID,
            dimension: descriptor.dimensions
        )
    }

    func upsertMemoryEmbeddingRef(
        memoryID: MemoryID,
        embeddingVersionID: String,
        vector: [Float],
        now: Date = Date()
    ) async throws {
        guard vector.isEmpty == false else { throw MemoryEmbeddingStoreError.emptyVector }
        try await dbQueue.write { db in
            let expectedDimension = try Int.fetchOne(
                db,
                sql: """
                SELECT embedding_models.dimensions
                FROM embedding_versions
                JOIN embedding_models ON embedding_models.id = embedding_versions.modelID
                WHERE embedding_versions.id = ?
                """,
                arguments: [embeddingVersionID]
            )
            guard let expectedDimension else {
                throw MemoryEmbeddingStoreError.unknownEmbeddingVersion(embeddingVersionID)
            }
            guard vector.count == expectedDimension else {
                throw MemoryEmbeddingStoreError.dimensionMismatch(expected: expectedDimension, actual: vector.count)
            }
            let vectorBlob = BurnBarVectorBlobCodec.encode(vector)
            let norm = Self.vectorNorm(vector)
            try db.execute(
                sql: """
                INSERT INTO memory_embedding_refs (
                    memory_id, embedding_version_id, dimension, vector, norm, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(memory_id, embedding_version_id) DO UPDATE SET
                    dimension = excluded.dimension,
                    vector = excluded.vector,
                    norm = excluded.norm,
                    created_at = excluded.created_at
                """,
                arguments: [memoryID, embeddingVersionID, expectedDimension, vectorBlob, norm, now]
            )
        }
    }

    func memoryEmbeddingMatches(
        queryVector: [Float],
        embeddingVersionID: String,
        dimension: Int,
        limit: Int = 20
    ) async throws -> [MemoryEmbeddingMatch] {
        guard queryVector.count == dimension else {
            throw MemoryEmbeddingStoreError.dimensionMismatch(expected: dimension, actual: queryVector.count)
        }
        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT memory_id, vector
                FROM memory_embedding_refs
                WHERE embedding_version_id = ? AND dimension = ?
                """,
                arguments: [embeddingVersionID, dimension]
            )
            let matches = rows.compactMap { row -> MemoryEmbeddingMatch? in
                guard let memoryID: String = row["memory_id"],
                      let data: Data = row["vector"],
                      let vector = BurnBarVectorBlobCodec.decode(data),
                      vector.count == dimension else {
                    return nil
                }
                return MemoryEmbeddingMatch(
                    memoryID: memoryID,
                    score: BurnBarVectorMath.similarity(lhs: queryVector, rhs: vector, metric: .cosine)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.memoryID < rhs.memoryID }
                return lhs.score > rhs.score
            }
            return Array(matches.prefix(max(1, limit)))
        }
    }

    private static func vectorNorm(_ vector: [Float]) -> Double {
        vector.reduce(0.0) { partial, value in
            partial + Double(value * value)
        }.squareRoot()
    }
}
