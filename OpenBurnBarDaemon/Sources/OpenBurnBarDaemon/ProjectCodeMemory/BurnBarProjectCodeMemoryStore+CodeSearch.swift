import Foundation
import OpenBurnBarEngine

// Hybrid (BM25 + cosine, RRF-fused) code search, stale-blob filtering,
// complete-symbol context selection and index-age degradation signals.
extension BurnBarProjectCodeMemoryStore {
    func codeSearchHits(query: String, root: URL, projectID: String, limit: Int) throws -> CodeSearchEvaluation {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyQuery }
        let capped = max(1, min(limit, 100))
        return try databaseSync {
            // Pull a wider candidate pool from each retriever than the final limit so RRF
            // has room to reorder lexical (BM25) and semantic (cosine) hits.
            let pool = min(200, max(capped * 5, capped))
            let lexicalIDs = try self.lexicalCodeChunkIDs(query: trimmed, projectID: projectID, limit: pool)
            let semanticIDs = Self.isExactIdentifierSearchIntent(trimmed)
                ? []
                : try self.semanticCodeChunkIDs(query: trimmed, projectID: projectID, limit: pool)
            // Hybrid when both retrievers return; lexical-only when embeddings are
            // unavailable so search never regresses below the keyword baseline.
            let fusedIDs = semanticIDs.isEmpty
                ? lexicalIDs
                : BurnBarReciprocalRankFusion.fuse([lexicalIDs, semanticIDs])
            return try self.resolveCodeHits(chunkIDs: fusedIDs, root: root, projectID: projectID, query: trimmed, limit: capped)
        }
    }

    /// Lexical (FTS5 BM25) chunk ids, with a LIKE fallback if the MATCH query is rejected.
    private func lexicalCodeChunkIDs(query: String, projectID: String, limit: Int) throws -> [String] {
        let fts = Self.ftsQuery(for: query)
        do {
            return try queryRows(
                """
                SELECT c.id
                FROM search_chunks_fts
                JOIN search_chunks c ON c.id = search_chunks_fts.chunkID
                JOIN search_documents d ON d.id = c.documentID
                JOIN code_artifacts a ON a.id = d.sourceID
                WHERE search_chunks_fts MATCH ?
                  AND d.sourceKind = ?
                  AND a.project_id = ?
                ORDER BY bm25(search_chunks_fts) ASC
                LIMIT ?
                """,
                [.text(fts), .text(Self.codeSourceKind), .text(projectID), .int(limit)]
            ).map { $0.string(0) }
        } catch {
            return try queryRows(
                """
                SELECT c.id
                FROM search_chunks c
                JOIN search_documents d ON d.id = c.documentID
                JOIN code_artifacts a ON a.id = d.sourceID
                WHERE d.sourceKind = ?
                  AND a.project_id = ?
                  AND c.text LIKE ?
                ORDER BY a.file_path ASC, c.ordinal ASC
                LIMIT ?
                """,
                [.text(Self.codeSourceKind), .text(projectID), .text("%\(query)%"), .int(limit)]
            ).map { $0.string(0) }
        }
    }

    /// Semantic (cosine) chunk ids over the daemon-owned embeddings, restricted to the
    /// ACTIVE embedding version (the §5.9 floor — vectors from a different generation are
    /// ignored, never silently compared). Empty when embeddings are unavailable.
    private func semanticCodeChunkIDs(query: String, projectID: String, limit: Int) throws -> [String] {
        guard embeddingProvider.isAvailable, let queryVector = embeddingProvider.embed(query) else { return [] }
        let dimension = queryVector.count
        let rows = try queryRows(
            """
            SELECT chunk_id, vector
            FROM code_chunk_embeddings
            WHERE project_id = ? AND embedding_version = ? AND dimension = ?
            """,
            [.text(projectID), .text(embeddingProvider.versionID), .int(dimension)]
        )
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

    /// Resolve fused chunk ids to hits, preserving fused order, dropping rows whose file no
    /// longer matches the indexed blob (stale), up to `limit`.
    private func resolveCodeHits(chunkIDs: [String], root: URL, projectID: String, query: String, limit: Int) throws -> CodeSearchEvaluation {
        guard chunkIDs.isEmpty == false else {
            return CodeSearchEvaluation(
                hits: [],
                staleCandidateCount: 0,
                totalCandidateCount: 0,
                degradation: nil
            )
        }
        let placeholders = chunkIDs.map { _ in "?" }.joined(separator: ",")
        var binds: [SQLiteBind] = chunkIDs.map { .text($0) }
        binds.append(.text(Self.codeSourceKind))
        binds.append(.text(projectID))
        let rows = try queryRows(
            """
            SELECT c.id, a.file_path, a.blob_sha, c.contentHash, c.text
            FROM search_chunks c
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE c.id IN (\(placeholders))
              AND d.sourceKind = ?
              AND a.project_id = ?
            """,
            binds
        )
        var byID: [String: (filePath: String, blobSHA: String, contentHash: String?, text: String)] = [:]
        for row in rows {
            byID[row.string(0)] = (row.string(1), row.string(2), row.optionalString(3), row.string(4))
        }
        var hits: [BurnBarProjectCodeSearchHit] = []
        var staleCount = 0
        for (fusedRank, chunkID) in chunkIDs.enumerated() {
            guard let meta = byID[chunkID] else { continue }
            guard Self.isCurrentBlob(root: root, filePath: meta.filePath, blobSHA: meta.blobSHA) else {
                staleCount += 1
                continue
            }
            if hits.count < limit {
                let wrapped = Self.wrapUntrustedCode(
                    Self.codeSnippet(text: meta.text, query: query),
                    sourceTool: "daemon.code.search",
                    projectID: projectID,
                    filePath: meta.filePath,
                    chunkID: chunkID,
                    blobSHA: meta.blobSHA,
                    contentHash: meta.contentHash
                )
                hits.append(
                    BurnBarProjectCodeSearchHit(
                        chunkID: chunkID,
                        filePath: meta.filePath,
                        snippet: wrapped,
                        rank: Double(fusedRank),
                        rankFeatures: [
                            "fusedRank": Double(fusedRank),
                            "candidatePool": Double(chunkIDs.count)
                        ],
                        blobSHA: meta.blobSHA,
                        contentHash: meta.contentHash
                    )
                )
            }
        }
        return CodeSearchEvaluation(
            hits: hits,
            staleCandidateCount: staleCount,
            totalCandidateCount: rows.count,
            degradation: try staleDegradation(
                projectID: projectID,
                staleCandidateCount: staleCount,
                totalCandidateCount: rows.count
            )
        )
    }

    /// A short snippet windowed around the first query-token match, else the text head.
    private static func codeSnippet(text: String, query: String) -> String {
        let tokens = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for token in tokens where token.isEmpty == false {
            if let range = text.range(of: token, options: .caseInsensitive) {
                let start = text.index(range.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(range.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
                let prefix = start > text.startIndex ? "..." : ""
                let suffix = end < text.endIndex ? "..." : ""
                return prefix + String(text[start..<end]) + suffix
            }
        }
        return String(text.prefix(240))
    }

    func contextSelection(
        for hit: BurnBarProjectCodeSearchHit,
        root: URL,
        projectID: String
    ) throws -> CodeContextSelection {
        let rows = try queryRows(
            """
            SELECT c.text, c.startOffset, c.endOffset, c.sourceID, a.file_path, a.blob_sha, c.contentHash
            FROM search_chunks c
            JOIN search_documents d ON d.id = c.documentID
            JOIN code_artifacts a ON a.id = d.sourceID
            WHERE c.id = ?
            LIMIT 1
            """,
            [.text(hit.chunkID)]
        )
        guard let row = rows.first else {
            return CodeContextSelection(
                text: "",
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: hit.contentHash
            )
        }
        let chunkText = row.string(0)
        let chunkStart = Int(row.int64(1))
        let chunkEnd = Int(row.int64(2))
        let artifactID = row.string(3)
        let filePath = row.string(4)
        let blobSHA = row.string(5)
        let fallbackHash = row.optionalString(6) ?? Self.sha256Hex(chunkText)
        let fileURL = root.appendingPathComponent(filePath, isDirectory: false)
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return CodeContextSelection(
                text: chunkText,
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: fallbackHash
            )
        }
        let symbolRows = try queryRows(
            """
            SELECT name, kind, range_json, confidence_tier
            FROM code_symbols
            WHERE project_id = ? AND artifact_id = ? AND blob_sha = ?
            """,
            [.text(projectID), .text(artifactID), .text(blobSHA)]
        )
        var best: (start: Int, end: Int, name: String, confidenceTier: String)?
        for symbol in symbolRows {
            let range = Self.decodeRange(symbol.string(2))
            guard let offsets = Self.rangeOffsets(for: range, in: text),
                  offsets.start < chunkEnd,
                  offsets.end > chunkStart else { continue }
            let length = offsets.end - offsets.start
            guard length > 0, length <= 16_000 else { continue }
            if best == nil || length < ((best?.end ?? 0) - (best?.start ?? 0)) {
                best = (offsets.start, offsets.end, symbol.string(0), symbol.string(3))
            }
        }
        guard let best else {
            return CodeContextSelection(
                text: chunkText,
                contentKind: "chunk",
                confidenceTier: "lexical_fallback",
                symbolName: nil,
                contentHash: fallbackHash
            )
        }
        let startIndex = text.index(text.startIndex, offsetBy: best.start)
        let endIndex = text.index(text.startIndex, offsetBy: best.end)
        let symbolText = String(text[startIndex..<endIndex])
        return CodeContextSelection(
            text: symbolText,
            contentKind: "complete_symbol",
            confidenceTier: best.confidenceTier,
            symbolName: best.name,
            contentHash: Self.sha256Hex(symbolText)
        )
    }

    func staleDegradation(
        projectID: String,
        staleCandidateCount: Int,
        totalCandidateCount: Int
    ) throws -> BurnBarProjectCodeDegradation? {
        guard totalCandidateCount > 0, staleCandidateCount * 2 >= totalCandidateCount else { return nil }
        return BurnBarProjectCodeDegradation(
            code: "STALE_INDEX",
            message: "At least half of the candidate rows point at files whose current blob no longer matches the indexed blob.",
            staleCandidateCount: staleCandidateCount,
            totalCandidateCount: totalCandidateCount,
            indexAgeSeconds: try indexAgeSeconds(projectID: projectID),
            reindexHint: "Run burnbar_index_project for this project before relying on code-memory results."
        )
    }

    private func indexAgeSeconds(projectID: String) throws -> Double? {
        guard let indexedAt = try queryRows(
            "SELECT indexed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
            [.text(projectID)]
        ).first?.optionalString(0) else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: indexedAt) else { return nil }
        return max(0, Date().timeIntervalSince(date))
    }
}
