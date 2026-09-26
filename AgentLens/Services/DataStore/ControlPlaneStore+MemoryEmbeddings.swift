import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarInsights
import OpenBurnBarKernel
import OpenBurnBarVectorKit

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

    // NOTE: `memory_embedding_refs` is daemon-written (ADR-005); the app reads it
    // via `memoryEmbeddingMatches` below and must not upsert. An app-side
    // upsert existed here with zero callers and was removed (Wave 0.3) to
    // enforce single-writer ownership.

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
}
