import Foundation
import GRDB
@testable import OpenBurnBarData

// MARK: - Search fixture seeder (test-only)
//
// Moved out of `OpenBurnBarLocalDatabase` (Wave 2.1c-ii): the only
// callers are the DataTests rank/decoding suites, and keeping fixture
// INSERTs in Sources made the dual-writer ratchet count test seeding
// as production writes. Seeding semantics are unchanged.
extension OpenBurnBarLocalDatabase {

    func indexSearchFixture(_ fixture: OpenBurnBarSearchFixture) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName,
                    title, subtitle, bodyPreview, sourceUpdatedAt, indexedAt,
                    contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    bodyPreview = excluded.bodyPreview,
                    indexedAt = excluded.indexedAt
                """,
                arguments: fixture.documentArguments
            )
            for chunk in fixture.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks (
                        id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                        startOffset, endOffset, messageStartOffset, messageEndOffset,
                        sectionPath, text, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: chunk.chunkArguments(documentID: fixture.documentID)
                )
                try db.execute(
                    sql: """
                    INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id,
                        fixture.documentID,
                        fixture.title,
                        chunk.text,
                        fixture.projectName,
                        fixture.provider
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO embedding_models (id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    fixture.embeddingModelID,
                    "fixture",
                    "fixture-embedding",
                    fixture.embeddingDimension,
                    "cosine",
                    fixture.now,
                    fixture.now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO embedding_versions (
                    id, modelID, versionTag, chunkerVersion, normalizationVersion,
                    promptVersion, isActive, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    fixture.embeddingVersionID,
                    fixture.embeddingModelID,
                    "fixture-v1",
                    "fixture-chunker-v1",
                    "fixture-l2-v1",
                    "fixture-prompt-v1",
                    true,
                    fixture.now,
                    fixture.now
                ]
            )
            for chunk in fixture.chunks {
                try db.execute(
                    sql: """
                    INSERT INTO chunk_embeddings (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        chunk.id,
                        fixture.embeddingVersionID,
                        chunk.vectorBlob,
                        fixture.now,
                        fixture.now
                    ]
                )
            }
            try db.execute(
                sql: """
                INSERT INTO vector_index_snapshots (
                    embeddingVersionID, backendID, state, fingerprint, dimensions,
                    distanceMetric, vectorCount, storageRelativePath, fileBytes,
                    backendVersion, errorCode, errorMessage, createdAt, updatedAt, lastBuiltAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(embeddingVersionID, backendID) DO UPDATE SET
                    fingerprint = excluded.fingerprint,
                    vectorCount = excluded.vectorCount,
                    state = excluded.state,
                    fileBytes = excluded.fileBytes,
                    updatedAt = excluded.updatedAt,
                    lastBuiltAt = excluded.lastBuiltAt
                """,
                arguments: [
                    fixture.embeddingVersionID,
                    fixture.vectorBackendID,
                    "ready",
                    fixture.vectorFingerprint,
                    fixture.embeddingDimension,
                    "cosine",
                    fixture.chunks.count,
                    fixture.snapshotPath,
                    fixture.vectorMetadataJSON.utf8.count,
                    "fixture-backend-v1",
                    nil,
                    nil,
                    fixture.now,
                    fixture.now,
                    fixture.now
                ]
            )
        }
    }
}
