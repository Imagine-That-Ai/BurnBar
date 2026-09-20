import Foundation
import OpenBurnBarEngine

extension BurnBarProjectCodeMemoryStore {
    /// Semantic chunk ids over the daemon-owned embeddings, restricted to the
    /// ACTIVE embedding version (the §5.9 floor — vectors from a different generation are
    /// ignored, never silently compared). Empty when embeddings are unavailable.
    /// Query path uses an HNSW snapshot rebuilt from `code_chunk_embeddings`; cosine
    /// scan is only the fallback if HNSW construction fails.
    func semanticCodeChunkIDs(query: String, projectID: String, limit: Int) throws -> [String] {
        guard embeddingProvider.isAvailable, let queryVector = embeddingProvider.embed(query) else {
            lastSemanticCodeSearchBackend = "none"
            return []
        }
        let dimension = queryVector.count
        let rows = try queryRows(
            """
            SELECT chunk_id, vector
            FROM code_chunk_embeddings
            WHERE project_id = ? AND embedding_version = ? AND dimension = ?
            """,
            [.text(projectID), .text(embeddingProvider.versionID), .int(dimension)]
        )
        if let hnswHits = try semanticCodeChunkIDsUsingHNSW(
            queryVector: queryVector,
            dimension: dimension,
            rows: rows,
            projectID: projectID,
            limit: limit
        ) {
            lastSemanticCodeSearchBackend = "hnsw"
            return hnswHits
        }
        lastSemanticCodeSearchBackend = "cosine-scan"
        let scored: [(id: String, score: Double)] = rows.compactMap { row in
            guard let data = Data(base64Encoded: row.string(1)),
                  let vector = BurnBarCodeVectorCodec.decode(data, dimension: dimension) else { return nil }
            return (row.string(0), BurnBarCodeVectorCodec.cosine(queryVector, vector))
        }
        return scored
            .filter { $0.score >= Self.minimumSemanticCodeCosineScore }
            .sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
            .prefix(limit)
            .map { $0.id }
    }

    private func semanticCodeChunkIDsUsingHNSW(
        queryVector: [Float],
        dimension: Int,
        rows: [SQLiteRow],
        projectID: String,
        limit: Int
    ) throws -> [String]? {
        guard rows.isEmpty == false else { return [] }
        let versionID = embeddingProvider.versionID
        if codeHNSWSnapshot?.projectID != projectID || codeHNSWSnapshot?.embeddingVersion != versionID {
            try rebuildCodeHNSWSnapshot(projectID: projectID, versionID: versionID, dimension: dimension, rows: rows)
        }
        guard let snapshot = codeHNSWSnapshot, snapshot.projectID == projectID else { return nil }
        let (keys, scores) = try snapshot.reader.search(vector: queryVector, limit: max(limit, 1))
        var hits: [String] = []
        for (index, key) in keys.enumerated() {
            guard index < scores.count else { break }
            guard scores[index] >= Float(Self.minimumSemanticCodeCosineScore) else { continue }
            if let chunkID = snapshot.keyToChunk[key] {
                hits.append(chunkID)
            }
            if hits.count >= limit { break }
        }
        return hits
    }

    private func rebuildCodeHNSWSnapshot(
        projectID: String,
        versionID: String,
        dimension: Int,
        rows: [SQLiteRow]
    ) throws {
        if let existing = codeHNSWSnapshot {
            try? FileManager.default.removeItem(at: existing.directoryURL)
            codeHNSWSnapshot = nil
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pcm-hnsw-\(projectID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = BurnBarPersistentVectorIndexFiles(directoryURL: directory)
        let backend = BurnBarHNSWVectorIndexBackend(m: 12, efConstruction: 64, efSearch: 32)
        let writer = try backend.makeWritable(dimensions: dimension, distanceMetric: .cosine)
        try writer.reserve(rows.count)
        var keyToChunk: [UInt64: String] = [:]
        var nextKey: UInt64 = 1
        for row in rows {
            guard let data = Data(base64Encoded: row.string(1)),
                  let vector = BurnBarCodeVectorCodec.decode(data, dimension: dimension) else { continue }
            let key = nextKey
            nextKey += 1
            try writer.add(key: key, vector: vector)
            keyToChunk[key] = row.string(0)
        }
        try writer.save(to: files.indexURL)
        let reader = try backend.makeReadable(dimensions: dimension, distanceMetric: .cosine)
        try reader.load(from: files.indexURL)
        codeHNSWSnapshot = CodeHNSWSnapshot(
            projectID: projectID,
            embeddingVersion: versionID,
            directoryURL: directory,
            reader: reader,
            keyToChunk: keyToChunk
        )
    }
}
