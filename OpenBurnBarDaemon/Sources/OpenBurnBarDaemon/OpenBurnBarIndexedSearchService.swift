import OpenBurnBarCore
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Indexed search for the OpenBurnBar daemon.
/// Supports both lexical FTS and semantic vector search with hybrid RRF fusion.
// AUDIT(@unchecked Sendable): Mutable state (snapshotContext) and raw SQLite pointer
// are serialized through dbQueue DispatchQueue; manual thread safety is correct.
final class BurnBarIndexedSearchService: @unchecked Sendable {
    private struct SnapshotContext {
        let embeddingVersionID: String
        let fingerprint: String
        let snapshot: BurnBarPersistentVectorIndexSnapshot?
        let record: DaemonVectorIndexSnapshotRecord?
    }

    private struct DaemonVectorIndexSnapshotRecord {
        let embeddingVersionID: String
        let backendID: String
        let state: String
        let fingerprint: String
        let dimensions: Int
        let distanceMetric: BurnBarEmbeddingDistanceMetric
        let vectorCount: Int
        let storageRelativePath: String?
        let fileBytes: Int64
        let backendVersion: String
        let errorCode: String?
        let errorMessage: String?
        let createdAt: Date
        let updatedAt: Date
        let lastBuiltAt: Date?
    }

    private let db: OpaquePointer?
    private let dbQueue = DispatchQueue(label: "com.openburnbar.daemon.indexed-search.sqlite")
    private let logger: BurnBarDaemonLogger
    private let semanticConfig: BurnBarSemanticSearchConfig
    private let snapshotBackend: any BurnBarPersistentVectorIndexBackend
    private let snapshotPageSize: Int
    private let storageRootURL: URL
    private let storageNamespace: String
    private var snapshotContext: SnapshotContext?

    init(
        databasePath: String,
        logger: BurnBarDaemonLogger,
        semanticConfig: BurnBarSemanticSearchConfig = .default,
        snapshotBackend: (any BurnBarPersistentVectorIndexBackend)? = nil,
        snapshotPageSize: Int = 1_000
    ) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databasePath, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let handle { sqlite3_close(handle) }
            throw NSError(
                domain: "BurnBarIndexedSearchService",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "Failed to open SQLite database: \(message)"]
            )
        }
        self.db = handle
        self.logger = logger
        self.semanticConfig = semanticConfig
        self.snapshotBackend = snapshotBackend ?? BurnBarPersistentVectorIndexFactory.hnswBackend(
            m: semanticConfig.hnswM,
            efConstruction: semanticConfig.hnswEfConstruction,
            efSearch: semanticConfig.hnswEfSearch,
            quantization: semanticConfig.quantization
        )
        self.snapshotPageSize = max(1, snapshotPageSize)
        let databaseURL = URL(fileURLWithPath: databasePath)
        self.storageRootURL = databaseURL.deletingLastPathComponent().appendingPathComponent("VectorIndexes", isDirectory: true)
        self.storageNamespace = "daemon-" + databaseURL.lastPathComponent.replacingOccurrences(of: ".", with: "-")
    }

    deinit {
        guard let db else { return }
        _ = dbQueue.sync {
            sqlite3_close(db)
        }
    }

    // MARK: - Public Search API

    func search(query: BurnBarSearchQueryRequest) throws -> BurnBarSearchQueryResult {
        let trimmed = query.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            let plan = BurnBarSearchPlan(
                mode: .retrieve,
                lexicalFTSQuery: "",
                semanticText: "",
                aggregatePatterns: [],
                note: "empty"
            )
            return BurnBarSearchQueryResult(
                plan: plan,
                aggregateOccurrenceCount: nil,
                hits: [],
                degradedMessage: nil,
                semanticSearchPerformed: false,
                semanticHitCount: nil
            )
        }

        let plan = BurnBarSearchPlan.plan(userText: trimmed)
        let limit = max(1, min(query.resultLimit, 200))

        // Aggregate count
        var aggregate: Int?
        if (plan.mode == .mixed || plan.mode == .aggregate), plan.aggregatePatterns.isEmpty == false {
            aggregate = try countOccurrences(
                patterns: plan.aggregatePatterns,
                providerRaw: query.providerRaw,
                projectName: query.projectName,
                dateRange: dateRange(from: query)
            )
        }

        // Determine if we can perform semantic search
        let canDoSemantic = Self.shouldPerformSemanticSearch(
            plan: plan,
            query: query,
            semanticEnabled: semanticConfig.enabled
        )

        // Perform search based on available data
        let (hits, degradedMessage, semanticPerformed, semanticCount) = try dbQueue.sync {
            return try performHybridSearch(
                plan: plan,
                query: query,
                limit: limit,
                canDoSemantic: canDoSemantic
            )
        }

        logger.debug(
            "indexed_search_complete",
            metadata: [
                "mode": plan.mode.rawValue,
                "hit_count": "\(hits.count)",
                "aggregate": aggregate.map { "\($0)" } ?? "nil",
                "semantic_performed": "\(semanticPerformed)",
                "semantic_hit_count": "\(semanticCount ?? 0)",
                "degraded": degradedMessage ?? "nil"
            ]
        )

        return BurnBarSearchQueryResult(
            plan: plan,
            aggregateOccurrenceCount: aggregate,
            hits: hits,
            degradedMessage: degradedMessage,
            semanticSearchPerformed: semanticPerformed,
            semanticHitCount: semanticCount
        )
    }

    // MARK: - Hybrid Search Implementation

    private struct SearchFilters {
        let providerRaw: String?
        let projectName: String?
        let dateRange: ClosedRange<Date>?
    }

    static func shouldPerformSemanticSearch(
        plan: BurnBarSearchPlan,
        query: BurnBarSearchQueryRequest,
        semanticEnabled: Bool
    ) -> Bool {
        semanticEnabled
            && !query.skipSemanticSearch
            && query.queryEmbedding != nil
            && plan.allowsSemanticSearch
    }

    private func performHybridSearch(
        plan: BurnBarSearchPlan,
        query: BurnBarSearchQueryRequest,
        limit: Int,
        canDoSemantic: Bool
    ) throws -> (hits: [BurnBarIndexedSearchHit], degradedMessage: String?, semanticPerformed: Bool, semanticCount: Int?) {
        let filters = SearchFilters(
            providerRaw: query.providerRaw,
            projectName: query.projectName,
            dateRange: dateRange(from: query)
        )

        // Get lexical results
        let lexicalResults: [String: (hit: BurnBarIndexedSearchHit, lexicalRank: Int)]
        let fts = plan.lexicalFTSQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if fts.isEmpty {
            lexicalResults = [:]
        } else {
            let rawHits = try lexicalHits(
                ftsQuery: fts,
                filters: filters,
                limit: semanticConfig.maxCandidates
            )
            lexicalResults = Dictionary(uniqueKeysWithValues: rawHits.enumerated().map { index, hit in
                (hit.chunkID, (hit, index + 1))
            })
        }

        // Semantic search if available
        var semanticResults: [String: (semanticScore: Double, semanticRank: Int)] = [:]
        var semanticPerformed = false
        var semanticCount: Int? = nil

        if canDoSemantic, let queryEmbedding = query.queryEmbedding {
            let resolvedMetric = query.embeddingDistanceMetric ?? .cosine
            let resolvedVersionID = query.embeddingVersionID

            let candidates = try semanticCandidates(
                queryEmbedding: queryEmbedding,
                versionID: resolvedVersionID,
                expectedDimension: query.embeddingDimension,
                filters: filters,
                metric: resolvedMetric,
                limit: semanticConfig.maxCandidates
            )

            if !candidates.isEmpty {
                semanticPerformed = true
                semanticResults = Dictionary(uniqueKeysWithValues: candidates.map { ($0.chunkID, ($0.score, $0.rank)) })
                semanticCount = candidates.count
            }
        }

        // Merge results using RRF
        let allChunkIDs = Set(lexicalResults.keys).union(Set(semanticResults.keys))
        var rankedHits: [(chunkID: String, fusedScore: Double, hitSource: BurnBarHitSource)] = []

        for chunkID in allChunkIDs {
            let lexicalRank = lexicalResults[chunkID]?.lexicalRank
            let semanticRank = semanticResults[chunkID]?.semanticRank

            let fusedScore: Double
            let hitSource: BurnBarHitSource

            if lexicalRank != nil && semanticRank != nil {
                // Both - hybrid RRF
                fusedScore = BurnBarHybridRankFusion.fusedScore(
                    lexicalRank: lexicalRank,
                    semanticRank: semanticRank,
                    k: semanticConfig.rrfK
                )
                hitSource = .hybrid
            } else if semanticRank != nil {
                // Semantic only
                fusedScore = BurnBarHybridRankFusion.fusedScore(
                    lexicalRank: nil,
                    semanticRank: semanticRank,
                    k: semanticConfig.rrfK
                )
                hitSource = .semantic
            } else {
                // Lexical only
                fusedScore = BurnBarHybridRankFusion.fusedScore(
                    lexicalRank: lexicalRank,
                    semanticRank: nil,
                    k: semanticConfig.rrfK
                )
                hitSource = .lexical
            }

            rankedHits.append((chunkID, fusedScore, hitSource))
        }

        // Sort by fused score (descending)
        rankedHits.sort { $0.fusedScore > $1.fusedScore }

        // Take top 'limit' and construct full hit objects
        var hits: [BurnBarIndexedSearchHit] = []
        hits.reserveCapacity(limit)

        // Build hit objects using lexical hits with enriched metadata
        for ranked in rankedHits.prefix(limit) {
            if let existing = lexicalResults[ranked.chunkID] {
                // Use existing lexical hit with enriched metadata
                hits.append(BurnBarIndexedSearchHit(
                    chunkID: existing.hit.chunkID,
                    sourceKind: existing.hit.sourceKind,
                    sourceID: existing.hit.sourceID,
                    title: existing.hit.title,
                    snippet: existing.hit.snippet,
                    provider: existing.hit.provider,
                    projectName: existing.hit.projectName,
                    relevanceScore: ranked.fusedScore,
                    hitSource: ranked.hitSource
                ))
            } else if semanticResults[ranked.chunkID] != nil {
                // Semantic-only hit - need to fetch metadata
                do {
                    if let enriched = try enrichSemanticHit(
                        chunkID: ranked.chunkID,
                        fusedScore: ranked.fusedScore,
                        hitSource: ranked.hitSource,
                        filters: filters
                    ) {
                        hits.append(enriched)
                    }
                } catch {
                    logger.silentFailure("enrich_semantic_hit", error: error)
                }
            }
        }

        // Determine degraded message
        var degradedMessage: String? = nil
        if !canDoSemantic && !semanticConfig.enabled {
            degradedMessage = "Semantic search is disabled in daemon configuration."
        } else if !canDoSemantic && semanticConfig.enabled {
            if query.skipSemanticSearch {
                degradedMessage = "Semantic search was explicitly skipped by the client."
            } else if plan.prefersLookupPrecision {
                degradedMessage = "Semantic search was skipped for a lookup-style query to preserve precision."
            } else {
                degradedMessage = "No query embedding provided; results are lexical FTS only. Provide a queryEmbedding for hybrid semantic search."
            }
        }

        return (hits, degradedMessage, semanticPerformed, semanticCount)
    }

    private func enrichSemanticHit(
        chunkID: String,
        fusedScore: Double,
        hitSource: BurnBarHitSource,
        filters: SearchFilters
    ) throws -> BurnBarIndexedSearchHit? {
        guard db != nil else { return nil }

        var sql = """
            SELECT
                c.id AS chunkID,
                snippet(search_chunks_fts, 3, '<b>', '</b>', '…', 16) AS snippet,
                d.sourceKind AS sourceKind,
                d.sourceID AS sourceID,
                d.title AS title,
                d.provider AS provider,
                d.projectName AS projectName
            FROM search_chunks AS c
            LEFT JOIN search_chunks_fts ON search_chunks_fts.chunkID = c.id
            JOIN search_documents AS d ON d.id = c.documentID
            WHERE c.id = ?
            """
        var args: [SQLiteBindValue] = [.text(chunkID)]

        if let providerRaw = filters.providerRaw, !providerRaw.isEmpty {
            sql += " AND d.provider = ?"
            args.append(.text(providerRaw))
        }
        if let projectName = filters.projectName, !projectName.isEmpty {
            sql += " AND d.projectName = ?"
            args.append(.text(projectName))
        }

        return try dbQueue.sync {
            guard let statement = try prepareStatement(sql: sql) else { return nil }
            defer { sqlite3_finalize(statement) }
            try bind(args, to: statement)

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

            let retrievedChunkID = stringColumn(statement, index: 0) ?? chunkID
            let snippet = stringColumn(statement, index: 1) ?? ""
            let sourceKind = stringColumn(statement, index: 2) ?? "unknown"
            let sourceID = stringColumn(statement, index: 3) ?? ""
            let title = stringColumn(statement, index: 4) ?? ""
            let provider = stringColumn(statement, index: 5)
            let project = stringColumn(statement, index: 6)

            return BurnBarIndexedSearchHit(
                chunkID: retrievedChunkID,
                sourceKind: sourceKind,
                sourceID: sourceID,
                title: title,
                snippet: snippet,
                provider: provider,
                projectName: project,
                relevanceScore: fusedScore,
                hitSource: hitSource
            )
        }
    }

    // MARK: - Semantic Search

    private func semanticCandidates(
        queryEmbedding: [Float],
        versionID: String?,
        expectedDimension: Int?,
        filters: SearchFilters,
        metric: BurnBarEmbeddingDistanceMetric,
        limit: Int
    ) throws -> [BurnBarSemanticCandidate] {
        guard db != nil else { return [] }

        // Resolve version ID
        let resolvedVersionID: String?
        if let versionID, !versionID.isEmpty {
            resolvedVersionID = versionID
        } else {
            resolvedVersionID = try resolveActiveEmbeddingVersion()
        }

        guard let targetVersionID = resolvedVersionID else {
            logger.debug("semantic_search_skipped", metadata: ["reason": "no_embedding_version"])
            return []
        }

        try refreshVectorSnapshotIfNeeded(
            versionID: targetVersionID,
            expectedDimension: expectedDimension,
            metric: metric
        )

        let annLimit = min(limit * semanticConfig.maxCandidates, limit * 10)
        let annCandidates: [BurnBarSemanticCandidate]
        if let snapshot = snapshotContext?.snapshot {
            annCandidates = try snapshot.candidates(for: queryEmbedding, limit: max(annLimit, limit))
                .enumerated()
                .map { index, candidate in
                    BurnBarSemanticCandidate(chunkID: candidate.chunkID, score: candidate.score, rank: index + 1)
                }
        } else {
            annCandidates = try streamingExactSemanticCandidates(
                queryEmbedding: queryEmbedding,
                versionID: targetVersionID,
                metric: metric,
                limit: max(annLimit, limit)
            )
        }
        guard annCandidates.isEmpty == false else { return [] }

        let candidateChunkIDs = annCandidates.map(\.chunkID)

        // Fetch metadata and apply filters in SQL for the candidate set only
        let filtered = try fetchFilteredCandidates(
            chunkIDs: candidateChunkIDs,
            filters: filters
        )

        let filteredSet = Set(filtered)
        var scored = annCandidates.filter { filteredSet.contains($0.chunkID) }
        scored.sort {
            if $0.score == $1.score {
                return $0.chunkID < $1.chunkID
            }
            return $0.score > $1.score
        }
        return Array(scored.prefix(limit)).enumerated().map { index, candidate in
            BurnBarSemanticCandidate(chunkID: candidate.chunkID, score: candidate.score, rank: index + 1)
        }
    }

    private func fetchFilteredCandidates(
        chunkIDs: [String],
        filters: SearchFilters
    ) throws -> [String] {
        guard db != nil, chunkIDs.isEmpty == false else { return [] }

        let placeholders = Array(repeating: "?", count: chunkIDs.count).joined(separator: ", ")
        var sql = """
            SELECT c.id
            FROM search_chunks AS c
            JOIN search_documents AS d ON d.id = c.documentID
            WHERE c.id IN (\(placeholders))
            """
        var args: [SQLiteBindValue] = chunkIDs.map { .text($0) }

        if let providerRaw = filters.providerRaw, !providerRaw.isEmpty {
            sql += " AND d.provider = ?"
            args.append(.text(providerRaw))
        }
        if let projectName = filters.projectName, !projectName.isEmpty {
            sql += " AND d.projectName = ?"
            args.append(.text(projectName))
        }
        if let dateRange = filters.dateRange {
            sql += " AND COALESCE(unixepoch(d.sourceUpdatedAt), unixepoch(d.indexedAt)) >= ?"
            sql += " AND COALESCE(unixepoch(d.sourceUpdatedAt), unixepoch(d.indexedAt)) <= ?"
            args.append(.int(Int64(dateRange.lowerBound.timeIntervalSince1970)))
            args.append(.int(Int64(dateRange.upperBound.timeIntervalSince1970)))
        }

        return try dbQueue.sync {
            guard let statement = try prepareStatement(sql: sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            try bind(args, to: statement)

            var results: [String] = []
            results.reserveCapacity(chunkIDs.count)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = stringColumn(statement, index: 0) {
                    results.append(id)
                }
            }
            return results
        }
    }

    private func refreshVectorSnapshotIfNeeded(
        versionID: String,
        expectedDimension: Int?,
        metric: BurnBarEmbeddingDistanceMetric
    ) throws {
        guard db != nil else { return }

        let stats = try chunkEmbeddingVersionStats(versionID: versionID)
        let fingerprint = "\(versionID)|\(stats.vectorCount)|\(Int(stats.newestUpdatedAt?.timeIntervalSince1970 ?? 0))"

        if let expectedDimension, stats.dimensions > 0, expectedDimension != stats.dimensions {
            throw NSError(
                domain: "BurnBarIndexedSearchService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Query embedding dimension \(expectedDimension) does not match indexed dimension \(stats.dimensions)."]
            )
        }

        if let snapshotContext,
           snapshotContext.embeddingVersionID == versionID,
           snapshotContext.fingerprint == fingerprint {
            return
        }

        let record = try fetchVectorSnapshot(versionID: versionID, backendID: snapshotBackend.backendID)
        if let record,
           record.state == "ready",
           record.fingerprint == fingerprint,
           let snapshot = try loadSnapshotIfPresent(record: record) {
            snapshotContext = SnapshotContext(
                embeddingVersionID: versionID,
                fingerprint: fingerprint,
                snapshot: snapshot,
                record: record
            )
            return
        }

        let rebuilt = try rebuildSnapshot(
            versionID: versionID,
            metric: metric,
            fingerprint: fingerprint,
            stats: stats,
            existingRecord: record
        )
        snapshotContext = SnapshotContext(
            embeddingVersionID: versionID,
            fingerprint: fingerprint,
            snapshot: try loadSnapshotIfPresent(record: rebuilt),
            record: rebuilt
        )

        logger.debug(
            "semantic_index_rebuilt",
            metadata: [
                "version_id": versionID,
                "entry_count": "\(stats.vectorCount)",
                "fingerprint": fingerprint
            ]
        )
    }

    private func resolveActiveEmbeddingVersion() throws -> String? {
        guard db != nil else { return nil }

        let sql = """
            SELECT v.id
            FROM embedding_versions AS v
            JOIN embedding_models AS m ON m.id = v.modelID
            WHERE v.isActive = 1
            ORDER BY v.updatedAt DESC
            LIMIT 1
            """

        return try dbQueue.sync {
            guard let statement = try prepareStatement(sql: sql) else { return nil }
            defer { sqlite3_finalize(statement) }

            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return stringColumn(statement, index: 0)
        }
    }

    private func chunkEmbeddingVersionStats(versionID: String) throws -> (vectorCount: Int, newestUpdatedAt: Date?, dimensions: Int) {
        try dbQueue.sync {
            let sql = """
                SELECT COUNT(*) AS cnt, MAX(e.updatedAt) AS maxUpdated, MAX(m.dimensions) AS dims
                FROM chunk_embeddings AS e
                JOIN embedding_versions AS v ON v.id = e.embeddingVersionID
                JOIN embedding_models AS m ON m.id = v.modelID
                WHERE e.embeddingVersionID = ?
                """
            guard let stmt = try prepareStatement(sql: sql) else {
                return (0, nil, 0)
            }
            defer { sqlite3_finalize(stmt) }
            try bind([.text(versionID)], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil, 0) }
            return (
                vectorCount: Int(sqlite3_column_int64(stmt, 0)),
                newestUpdatedAt: parseSQLiteDate(stringColumn(stmt, index: 1)),
                dimensions: Int(sqlite3_column_int64(stmt, 2))
            )
        }
    }

    private func fetchVectorSnapshot(versionID: String, backendID: String) throws -> DaemonVectorIndexSnapshotRecord? {
        try dbQueue.sync {
            let sql = """
                SELECT *
                FROM vector_index_snapshots
                WHERE embeddingVersionID = ? AND backendID = ?
                LIMIT 1
                """
            guard let stmt = try prepareStatement(sql: sql) else { return nil }
            defer { sqlite3_finalize(stmt) }
            try bind([.text(versionID), .text(backendID)], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return vectorSnapshotRecord(from: stmt)
        }
    }

    private func upsertVectorSnapshot(_ record: DaemonVectorIndexSnapshotRecord) throws {
        try dbQueue.sync {
            let sql = """
                INSERT INTO vector_index_snapshots (
                    embeddingVersionID, backendID, state, fingerprint, dimensions, distanceMetric,
                    vectorCount, storageRelativePath, fileBytes, backendVersion, errorCode, errorMessage,
                    createdAt, updatedAt, lastBuiltAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(embeddingVersionID, backendID) DO UPDATE SET
                    state = excluded.state,
                    fingerprint = excluded.fingerprint,
                    dimensions = excluded.dimensions,
                    distanceMetric = excluded.distanceMetric,
                    vectorCount = excluded.vectorCount,
                    storageRelativePath = excluded.storageRelativePath,
                    fileBytes = excluded.fileBytes,
                    backendVersion = excluded.backendVersion,
                    errorCode = excluded.errorCode,
                    errorMessage = excluded.errorMessage,
                    updatedAt = excluded.updatedAt,
                    lastBuiltAt = excluded.lastBuiltAt
                """
            guard let stmt = try prepareStatement(sql: sql) else { return }
            defer { sqlite3_finalize(stmt) }
            try bind([
                .text(record.embeddingVersionID),
                .text(record.backendID),
                .text(record.state),
                .text(record.fingerprint),
                .int(Int64(record.dimensions)),
                .text(record.distanceMetric.rawValue),
                .int(Int64(record.vectorCount)),
                record.storageRelativePath.map(SQLiteBindValue.text) ?? .null,
                .int(record.fileBytes),
                .text(record.backendVersion),
                record.errorCode.map(SQLiteBindValue.text) ?? .null,
                record.errorMessage.map(SQLiteBindValue.text) ?? .null,
                .text(Self.sqliteTimestamp(record.createdAt)),
                .text(Self.sqliteTimestamp(record.updatedAt)),
                record.lastBuiltAt.map { .text(Self.sqliteTimestamp($0)) } ?? .null
            ], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw sqliteError(db: db, code: sqlite3_errcode(db), context: "vector_snapshot_upsert")
            }
        }
    }

    private func rebuildSnapshot(
        versionID: String,
        metric: BurnBarEmbeddingDistanceMetric,
        fingerprint: String,
        stats: (vectorCount: Int, newestUpdatedAt: Date?, dimensions: Int),
        existingRecord: DaemonVectorIndexSnapshotRecord?
    ) throws -> DaemonVectorIndexSnapshotRecord {
        let builtAt = Date()
        let generation = UUID().uuidString
        let relativeParent = "\(storageNamespace)/\(versionID)/\(snapshotBackend.backendID)"
        let finalRelativePath = "\(relativeParent)/\(generation)"
        let tempRelativePath = "\(relativeParent)/tmp-\(generation)"
        let tempFiles = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(tempRelativePath, isDirectory: true)
        )
        let finalFiles = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(finalRelativePath, isDirectory: true)
        )

        try upsertVectorSnapshot(
            DaemonVectorIndexSnapshotRecord(
                embeddingVersionID: versionID,
                backendID: snapshotBackend.backendID,
                state: "building",
                fingerprint: fingerprint,
                dimensions: stats.dimensions,
                distanceMetric: metric,
                vectorCount: stats.vectorCount,
                storageRelativePath: existingRecord?.storageRelativePath,
                fileBytes: existingRecord?.fileBytes ?? 0,
                backendVersion: snapshotBackend.backendVersion,
                errorCode: nil,
                errorMessage: nil,
                createdAt: existingRecord?.createdAt ?? builtAt,
                updatedAt: builtAt,
                lastBuiltAt: existingRecord?.lastBuiltAt
            )
        )

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: tempFiles.directoryURL)
        try fileManager.createDirectory(at: tempFiles.directoryURL, withIntermediateDirectories: true, attributes: nil)

        do {
            let chunkIDs = try fetchAllChunkIDs(versionID: versionID)
            let keyByChunkID = try BurnBarPersistentVectorIndexKeyCodec.makeMapping(chunkIDs: chunkIDs)
            let writer = try snapshotBackend.makeWritable(dimensions: stats.dimensions, distanceMetric: metric)
            try writer.reserve(stats.vectorCount)

            var offset = 0
            while true {
                let page = try fetchChunkEmbeddingPage(versionID: versionID, limit: snapshotPageSize, offset: offset)
                guard page.isEmpty == false else { break }
                for item in page {
                    guard let key = keyByChunkID[item.chunkID] else { continue }
                    try writer.add(key: key, vector: item.vector)
                }
                offset += page.count
                if page.count < snapshotPageSize { break }
            }

            try writer.save(to: tempFiles.indexURL)
            let manifest = BurnBarPersistentVectorIndexManifest(
                backendID: snapshotBackend.backendID,
                backendVersion: snapshotBackend.backendVersion,
                embeddingVersionID: versionID,
                fingerprint: fingerprint,
                dimensions: stats.dimensions,
                distanceMetric: metric,
                vectorCount: stats.vectorCount,
                builtAt: builtAt
            )
            try BurnBarPersistentVectorIndexSnapshotIO.writeManifest(manifest, to: tempFiles.manifestURL)
            try BurnBarPersistentVectorIndexSnapshotIO.writeKeyMapping(keyByChunkID, to: tempFiles.keyMappingURL)

            try fileManager.createDirectory(at: finalFiles.directoryURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try? fileManager.removeItem(at: finalFiles.directoryURL)
            try fileManager.moveItem(at: tempFiles.directoryURL, to: finalFiles.directoryURL)

            let ready = DaemonVectorIndexSnapshotRecord(
                embeddingVersionID: versionID,
                backendID: snapshotBackend.backendID,
                state: "ready",
                fingerprint: fingerprint,
                dimensions: stats.dimensions,
                distanceMetric: metric,
                vectorCount: stats.vectorCount,
                storageRelativePath: finalRelativePath,
                fileBytes: BurnBarPersistentVectorIndexSnapshotIO.fileByteCount(at: finalFiles.indexURL),
                backendVersion: snapshotBackend.backendVersion,
                errorCode: nil,
                errorMessage: nil,
                createdAt: existingRecord?.createdAt ?? builtAt,
                updatedAt: builtAt,
                lastBuiltAt: builtAt
            )
            try upsertVectorSnapshot(ready)

            if let previous = existingRecord?.storageRelativePath, previous != finalRelativePath {
                try? fileManager.removeItem(at: storageRootURL.appendingPathComponent(previous, isDirectory: true))
            }

            return ready
        } catch {
            try? fileManager.removeItem(at: tempFiles.directoryURL)
            let failed = DaemonVectorIndexSnapshotRecord(
                embeddingVersionID: versionID,
                backendID: snapshotBackend.backendID,
                state: "failed",
                fingerprint: fingerprint,
                dimensions: stats.dimensions,
                distanceMetric: metric,
                vectorCount: stats.vectorCount,
                storageRelativePath: existingRecord?.storageRelativePath,
                fileBytes: existingRecord?.fileBytes ?? 0,
                backendVersion: snapshotBackend.backendVersion,
                errorCode: "VECTOR_SNAPSHOT_BUILD_FAILED",
                errorMessage: error.localizedDescription,
                createdAt: existingRecord?.createdAt ?? builtAt,
                updatedAt: builtAt,
                lastBuiltAt: existingRecord?.lastBuiltAt
            )
            try upsertVectorSnapshot(failed)
            throw error
        }
    }

    private func loadSnapshotIfPresent(record: DaemonVectorIndexSnapshotRecord) throws -> BurnBarPersistentVectorIndexSnapshot? {
        guard let relativePath = record.storageRelativePath, relativePath.isEmpty == false else { return nil }
        let files = BurnBarPersistentVectorIndexFiles(
            directoryURL: storageRootURL.appendingPathComponent(relativePath, isDirectory: true)
        )
        guard FileManager.default.fileExists(atPath: files.indexURL.path) else { return nil }
        return try BurnBarPersistentVectorIndexSnapshot.open(files: files, backend: snapshotBackend)
    }

    private func fetchAllChunkIDs(versionID: String) throws -> [String] {
        var ids: [String] = []
        var offset = 0
        while true {
            let page = try fetchChunkIDPage(versionID: versionID, limit: snapshotPageSize, offset: offset)
            guard page.isEmpty == false else { break }
            ids.append(contentsOf: page)
            offset += page.count
            if page.count < snapshotPageSize { break }
        }
        return ids
    }

    private func fetchChunkIDPage(versionID: String, limit: Int, offset: Int) throws -> [String] {
        try dbQueue.sync {
            let sql = """
                SELECT chunkID
                FROM chunk_embeddings
                WHERE embeddingVersionID = ?
                ORDER BY chunkID ASC
                LIMIT ? OFFSET ?
                """
            guard let stmt = try prepareStatement(sql: sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            try bind([.text(versionID), .int(Int64(limit)), .int(Int64(offset))], to: stmt)
            var result: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let chunkID = stringColumn(stmt, index: 0) {
                    result.append(chunkID)
                }
            }
            return result
        }
    }

    private func fetchChunkEmbeddingPage(
        versionID: String,
        limit: Int,
        offset: Int
    ) throws -> [(chunkID: String, vector: [Float])] {
        try dbQueue.sync {
            let sql = """
                SELECT chunkID, vectorBlob
                FROM chunk_embeddings
                WHERE embeddingVersionID = ?
                ORDER BY chunkID ASC
                LIMIT ? OFFSET ?
                """
            guard let stmt = try prepareStatement(sql: sql) else { return [] }
            defer { sqlite3_finalize(stmt) }
            try bind([.text(versionID), .int(Int64(limit)), .int(Int64(offset))], to: stmt)
            var result: [(chunkID: String, vector: [Float])] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let chunkID = stringColumn(stmt, index: 0),
                      let blob = dataColumn(stmt, index: 1),
                      let vector = BurnBarVectorBlobCodec.decode(blob) else { continue }
                result.append((chunkID, vector))
            }
            return result
        }
    }

    private func streamingExactSemanticCandidates(
        queryEmbedding: [Float],
        versionID: String,
        metric: BurnBarEmbeddingDistanceMetric,
        limit: Int
    ) throws -> [BurnBarSemanticCandidate] {
        var best: [BurnBarSemanticCandidate] = []
        var offset = 0

        while true {
            let page = try fetchChunkEmbeddingPage(versionID: versionID, limit: snapshotPageSize, offset: offset)
            guard page.isEmpty == false else { break }

            for item in page {
                let score = BurnBarVectorMath.similarity(lhs: queryEmbedding, rhs: item.vector, metric: metric)
                guard score.isFinite else { continue }
                let candidate = BurnBarSemanticCandidate(chunkID: item.chunkID, score: score, rank: 0)
                if best.count < limit {
                    best.append(candidate)
                    best.sort(by: semanticCandidateOrder)
                } else if let last = best.last, semanticCandidateOrder(candidate, last) {
                    best.removeLast()
                    best.append(candidate)
                    best.sort(by: semanticCandidateOrder)
                }
            }

            offset += page.count
            if page.count < snapshotPageSize { break }
        }

        return best.enumerated().map { index, candidate in
            BurnBarSemanticCandidate(chunkID: candidate.chunkID, score: candidate.score, rank: index + 1)
        }
    }

    private func semanticCandidateOrder(_ lhs: BurnBarSemanticCandidate, _ rhs: BurnBarSemanticCandidate) -> Bool {
        if lhs.score == rhs.score {
            return lhs.chunkID < rhs.chunkID
        }
        return lhs.score > rhs.score
    }

    // MARK: - Lexical Search (Enriched)

    private func lexicalHits(
        ftsQuery: String,
        filters: SearchFilters,
        limit: Int
    ) throws -> [BurnBarIndexedSearchHit] {
        var clauses: [String] = ["search_chunks_fts MATCH ?"]
        var args: [SQLiteBindValue] = [.text(ftsQuery)]

        clauses.append("d.sourceKind IN ('conversation', 'skill_doc', 'agent_doc')")

        if let providerRaw = filters.providerRaw, !providerRaw.isEmpty {
            clauses.append("d.provider = ?")
            args.append(.text(providerRaw))
        }

        if let projectName = filters.projectName, !projectName.isEmpty {
            let normalized = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty == false {
                clauses.append("d.projectName = ?")
                args.append(.text(normalized))
            }
        }

        if let dateRange = filters.dateRange {
            clauses.append("COALESCE(unixepoch(d.sourceUpdatedAt), unixepoch(d.indexedAt)) >= ?")
            clauses.append("COALESCE(unixepoch(d.sourceUpdatedAt), unixepoch(d.indexedAt)) <= ?")
            args.append(.int(Int64(dateRange.lowerBound.timeIntervalSince1970)))
            args.append(.int(Int64(dateRange.upperBound.timeIntervalSince1970)))
        }

        let whereSQL = clauses.joined(separator: " AND ")
        args.append(.int(Int64(limit)))

        return try dbQueue.sync {
            let sql = """
                SELECT
                    search_chunks_fts.chunkID AS chunkID,
                    snippet(search_chunks_fts, 3, '<b>', '</b>', '…', 16) AS snippet,
                    d.sourceKind AS sourceKind,
                    d.sourceID AS sourceID,
                    d.title AS title,
                    d.provider AS provider,
                    d.projectName AS projectName
                FROM search_chunks_fts
                JOIN search_chunks AS c ON c.id = search_chunks_fts.chunkID
                JOIN search_documents AS d ON d.id = search_chunks_fts.documentID
                WHERE \(whereSQL)
                ORDER BY bm25(search_chunks_fts) ASC, d.indexedAt DESC, c.ordinal ASC
                LIMIT ?
                """

            guard let statement = try prepareStatement(sql: sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            try bind(args, to: statement)

            var hits: [BurnBarIndexedSearchHit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let chunkID = stringColumn(statement, index: 0),
                    let snippet = stringColumn(statement, index: 1),
                    let sourceKind = stringColumn(statement, index: 2),
                    let sourceID = stringColumn(statement, index: 3),
                    let title = stringColumn(statement, index: 4)
                else {
                    continue
                }
                let provider = stringColumn(statement, index: 5)
                let project = stringColumn(statement, index: 6)
                hits.append(
                    BurnBarIndexedSearchHit(
                        chunkID: chunkID,
                        sourceKind: sourceKind,
                        sourceID: sourceID,
                        title: title,
                        snippet: snippet,
                        provider: provider,
                        projectName: project
                    )
                )
            }
            return hits
        }
    }

    // MARK: - Aggregate Search

    private func dateRange(from query: BurnBarSearchQueryRequest) -> ClosedRange<Date>? {
        if query.dateRangeStartEpoch != nil || query.dateRangeEndEpoch != nil {
            let lower = Date(timeIntervalSince1970: query.dateRangeStartEpoch ?? 0)
            let upper = Date(timeIntervalSince1970: query.dateRangeEndEpoch ?? Date().timeIntervalSince1970)
            if lower <= upper {
                return lower ... upper
            }
            return upper ... lower
        }
        return BurnBarSearchTimeWindow.inferredDateRange(from: query.query)
    }

    private func countOccurrences(
        patterns: [String],
        providerRaw: String?,
        projectName: String?,
        dateRange: ClosedRange<Date>?
    ) throws -> Int {
        let cleaned = patterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return 0 }

        return try dbQueue.sync {
            var total = 0
            for raw in cleaned {
                let pattern = raw.lowercased()
                guard pattern.isEmpty == false else { continue }

                var sql = """
                    SELECT COALESCE(SUM(
                        (LENGTH(COALESCE(c.fullText,'')) - LENGTH(REPLACE(LOWER(COALESCE(c.fullText,'')), ?, ''))) / LENGTH(?)
                    ), 0)
                    FROM conversations AS c
                    WHERE 1 = 1
                    """
                var args: [SQLiteBindValue] = [.text(pattern), .text(pattern)]
                if let providerRaw, providerRaw.isEmpty == false {
                    sql += " AND c.provider = ?"
                    args.append(.text(providerRaw))
                }
                if let projectName, projectName.isEmpty == false {
                    sql += " AND c.projectName = ?"
                    args.append(.text(projectName))
                }
                if let range = dateRange {
                    sql += """
                     AND unixepoch(COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt)) >= ?
                     AND unixepoch(COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt)) <= ?
                    """
                    args.append(.int(Int64(range.lowerBound.timeIntervalSince1970)))
                    args.append(.int(Int64(range.upperBound.timeIntervalSince1970)))
                }

                let count = try fetchSingleInt(sql: sql, args: args)
                total += count
            }
            return total
        }
    }

    // MARK: - SQLite Utilities

    private enum SQLiteBindValue {
        case text(String)
        case int(Int64)
        case null
    }

    private func prepareStatement(sql: String) throws -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw sqliteError(db: db, code: rc, context: "prepare")
        }
        return statement
    }

    private func bind(_ args: [SQLiteBindValue], to statement: OpaquePointer) throws {
        for (index, arg) in args.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch arg {
            case .text(let value):
                rc = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .int(let value):
                rc = sqlite3_bind_int64(statement, position, value)
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else {
                throw sqliteError(db: db, code: rc, context: "bind")
            }
        }
    }

    private func fetchSingleInt(sql: String, args: [SQLiteBindValue]) throws -> Int {
        guard let statement = try prepareStatement(sql: sql) else { return 0 }
        defer { sqlite3_finalize(statement) }
        try bind(args, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func stringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func dataColumn(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let blobPtr = sqlite3_column_blob(statement, index) else { return nil }
        let blobSize = sqlite3_column_bytes(statement, index)
        return Data(bytes: blobPtr, count: Int(blobSize))
    }

    private func parseSQLiteDate(_ string: String?) -> Date? {
        guard let string, string.isEmpty == false else { return nil }
        if let date = Self.sqliteDateFormatter.date(from: string) {
            return date
        }
        return Self.iso8601Fractional.date(from: string) ?? Self.iso8601Basic.date(from: string)
    }

    private func vectorSnapshotRecord(from statement: OpaquePointer) -> DaemonVectorIndexSnapshotRecord? {
        guard
            let embeddingVersionID = stringColumn(statement, index: 0),
            let backendID = stringColumn(statement, index: 1),
            let state = stringColumn(statement, index: 2),
            let fingerprint = stringColumn(statement, index: 3),
            let distanceMetricRaw = stringColumn(statement, index: 5),
            let distanceMetric = BurnBarEmbeddingDistanceMetric(rawValue: distanceMetricRaw),
            let backendVersion = stringColumn(statement, index: 9)
        else {
            return nil
        }

        return DaemonVectorIndexSnapshotRecord(
            embeddingVersionID: embeddingVersionID,
            backendID: backendID,
            state: state,
            fingerprint: fingerprint,
            dimensions: Int(sqlite3_column_int64(statement, 4)),
            distanceMetric: distanceMetric,
            vectorCount: Int(sqlite3_column_int64(statement, 6)),
            storageRelativePath: stringColumn(statement, index: 7),
            fileBytes: sqlite3_column_int64(statement, 8),
            backendVersion: backendVersion,
            errorCode: stringColumn(statement, index: 10),
            errorMessage: stringColumn(statement, index: 11),
            createdAt: parseSQLiteDate(stringColumn(statement, index: 12)) ?? Date(),
            updatedAt: parseSQLiteDate(stringColumn(statement, index: 13)) ?? Date(),
            lastBuiltAt: parseSQLiteDate(stringColumn(statement, index: 14))
        )
    }

    private static func sqliteTimestamp(_ date: Date) -> String {
        sqliteDateFormatter.string(from: date)
    }

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func sqliteError(db: OpaquePointer?, code: Int32, context: String) -> NSError {
        let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error"
        return NSError(
            domain: "BurnBarIndexedSearchService",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(context) failed (\(code)): \(message)"]
        )
    }
}
