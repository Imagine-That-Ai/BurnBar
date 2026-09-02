import Foundation
import OpenBurnBarEngine

extension BurnBarProjectCodeMemoryStore {
    func searchCode(_ request: BurnBarProjectCodeSearchRequest) throws -> BurnBarProjectCodeSearchResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let evaluated = try codeSearchHits(query: request.query, root: root, projectID: projectID, limit: request.limit)
        if evaluated.degradation != nil {
            logger.warning(
                "project_code_memory_stale_degraded",
                metadata: [
                    "project_id": projectID,
                    "stale_candidates": String(evaluated.staleCandidateCount),
                    "total_candidates": String(evaluated.totalCandidateCount)
                ]
            )
        }
        return BurnBarProjectCodeSearchResponse(
            traceID: traceID,
            projectID: projectID,
            hits: evaluated.hits,
            status: evaluated.degradation == nil ? "ok" : "degraded",
            semanticAvailable: false,
            degradation: evaluated.degradation,
            trustSignal: BurnBarProjectCodeTrustSignal(
                untrustedContentWrapped: true,
                sourceTool: "daemon.code.search",
                wrappedCount: evaluated.hits.count
            )
        )
    }

    func contextPack(_ request: BurnBarProjectCodeContextPackRequest) throws -> BurnBarProjectCodeContextPackResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let evaluated = try codeSearchHits(query: request.query, root: root, projectID: projectID, limit: request.limit)
        let hits = evaluated.hits
        let maxBytes = max(1_000, min(request.maxBytes, 250_000))
        var output = ""
        var truncated = false
        try databaseSync {
            for hit in hits {
                let selection = try contextSelection(for: hit, root: root, projectID: projectID)
                let wrapped = Self.wrapUntrustedCode(
                    selection.text,
                    sourceTool: "daemon.code.context_pack",
                    projectID: projectID,
                    filePath: hit.filePath,
                    chunkID: hit.chunkID,
                    blobSHA: hit.blobSHA,
                    contentHash: selection.contentHash ?? hit.contentHash
                )
                let symbolSuffix = selection.symbolName.map { " symbol=\"\(Self.xmlAttributeEscaped($0))\"" } ?? ""
                let block = """
                <file path="\(Self.xmlAttributeEscaped(hit.filePath))" tier="\(Self.xmlAttributeEscaped(selection.confidenceTier))" contentKind="\(Self.xmlAttributeEscaped(selection.contentKind))"\(symbolSuffix)>
                \(wrapped)
                </file>

                """
                if output.utf8.count + block.utf8.count > maxBytes {
                    truncated = true
                    break
                }
                output += block
            }
        }
        return BurnBarProjectCodeContextPackResponse(
            traceID: traceID,
            projectID: projectID,
            context: output,
            hits: hits,
            truncated: truncated,
            status: evaluated.degradation == nil ? "ok" : "degraded",
            semanticAvailable: false,
            degradation: evaluated.degradation,
            trustSignal: BurnBarProjectCodeTrustSignal(
                untrustedContentWrapped: true,
                sourceTool: "daemon.code.context_pack",
                wrappedCount: hits.count
            )
        )
    }

    private static func xmlAttributeEscaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&":
                escaped += "&amp;"
            case "\"":
                escaped += "&quot;"
            case "'":
                escaped += "&apos;"
            case "<":
                escaped += "&lt;"
            case ">":
                escaped += "&gt;"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    func getSymbol(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeSymbolResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let (symbols, degradation) = try databaseSync {
            let rows = try querySymbols(
                """
                SELECT s.id, s.artifact_id, a.file_path, s.name, s.kind, s.range_json, s.confidence_tier,
                       s.blob_sha, s.tier_evidence_json
                FROM code_symbols s
                JOIN code_artifacts a ON a.id = s.artifact_id
                WHERE s.project_id = ? AND (s.name = ? OR s.name LIKE ?)
                ORDER BY CASE WHEN s.name = ? THEN 0 ELSE 1 END, a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .text(request.name), .text("%\(request.name)%"), .text(request.name), .int(max(1, min(request.limit, 100)))]
            )
            var staleCount = 0
            let current = rows.compactMap { row -> BurnBarProjectCodeSymbol? in
                guard Self.isCurrentBlob(root: root, filePath: row.filePath, blobSHA: row.blobSHA) else {
                    staleCount += 1
                    return nil
                }
                return Self.publicSymbol(row)
            }
            return (
                current,
                try staleDegradation(projectID: projectID, staleCandidateCount: staleCount, totalCandidateCount: rows.count)
            )
        }
        return BurnBarProjectCodeSymbolResponse(
            traceID: traceID,
            projectID: projectID,
            symbols: symbols,
            status: degradation == nil ? "ok" : "degraded",
            degradation: degradation
        )
    }

    func findReferences(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeReferencesResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let exactReferences = try self.exactLSPReferences(
            symbolName: request.name,
            root: root,
            projectID: projectID,
            limit: request.limit
        )
        if exactReferences.isEmpty == false {
            return BurnBarProjectCodeReferencesResponse(traceID: traceID, projectID: projectID, references: exactReferences)
        }
        let (references, degradation): ([BurnBarProjectCodeReference], BurnBarProjectCodeDegradation?) = try databaseSync {
            let rows = try queryRows(
                """
                SELECT r.id, a.file_path, target.id, target.artifact_id, target_art.file_path,
                       target.name, target.kind, target.range_json, target.confidence_tier,
                       r.range_json, r.confidence_tier, r.blob_sha, target.blob_sha,
                       target.tier_evidence_json
                FROM code_references r
                JOIN code_symbols target ON target.id = r.to_symbol_id
                JOIN code_artifacts target_art ON target_art.id = target.artifact_id
                JOIN code_artifacts a ON a.id = r.from_artifact_id
                WHERE r.project_id = ? AND target.name = ?
                ORDER BY a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .text(request.name), .int(max(1, min(request.limit, 200)))]
            )
            var staleCount = 0
            let current = rows.compactMap { row -> BurnBarProjectCodeReference? in
                guard Self.isCurrentBlob(root: root, filePath: row.string(1), blobSHA: row.string(11)),
                      Self.isCurrentBlob(root: root, filePath: row.string(4), blobSHA: row.string(12)) else {
                    staleCount += 1
                    return nil
                }
                return BurnBarProjectCodeReference(
                    referenceID: row.string(0),
                    fromFilePath: row.string(1),
                    targetSymbol: BurnBarProjectCodeSymbol(
                        symbolID: row.string(2),
                        name: row.string(5),
                        kind: row.string(6),
                        filePath: row.string(4),
                        range: Self.decodeRange(row.string(7)),
                        confidenceTier: row.string(8),
                        tierEvidence: Self.decodeTierEvidence(row.optionalString(13))
                    ),
                    range: Self.decodeRange(row.string(9)),
                    confidenceTier: row.string(10)
                )
            }
            return (
                current,
                try staleDegradation(projectID: projectID, staleCandidateCount: staleCount, totalCandidateCount: rows.count)
            )
        }
        return BurnBarProjectCodeReferencesResponse(
            traceID: traceID,
            projectID: projectID,
            references: references,
            status: degradation == nil ? "ok" : "degraded",
            degradation: degradation
        )
    }

    func callGraph(_ request: BurnBarProjectCodeSymbolRequest) throws -> BurnBarProjectCodeCallGraphResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let (edges, degradation): ([BurnBarProjectCodeCallEdge], BurnBarProjectCodeDegradation?) = try databaseSync {
            struct CandidateEdge {
                let edge: BurnBarProjectCodeCallEdge
                let callerName: String
                let calleeName: String
                let stale: Bool
            }

            let rows = try queryRows(
                """
                SELECT e.id,
                       caller.id, caller.name, caller.kind, caller_art.file_path, caller.range_json, caller.confidence_tier, caller.blob_sha, caller.tier_evidence_json,
                       callee.id, callee.name, callee.kind, callee_art.file_path, callee.range_json, callee.confidence_tier, callee.blob_sha, callee.tier_evidence_json,
                       e.confidence_tier
                FROM code_call_edges e
                JOIN code_symbols caller ON caller.id = e.caller_symbol_id
                JOIN code_symbols callee ON callee.id = e.callee_symbol_id
                JOIN code_artifacts caller_art ON caller_art.id = caller.artifact_id
                JOIN code_artifacts callee_art ON callee_art.id = callee.artifact_id
                WHERE e.project_id = ?
                ORDER BY caller.name ASC, callee.name ASC, caller_art.file_path ASC
                """,
                [.text(projectID)]
            )
            var staleCount = 0
            var totalCandidateCount = 0
            let candidates = rows.map { row -> CandidateEdge in
                let isCurrent = Self.isCurrentBlob(root: root, filePath: row.string(4), blobSHA: row.string(7))
                    && Self.isCurrentBlob(root: root, filePath: row.string(12), blobSHA: row.string(15))
                return CandidateEdge(
                    edge: BurnBarProjectCodeCallEdge(
                        edgeID: row.string(0),
                        caller: BurnBarProjectCodeSymbol(
                            symbolID: row.string(1),
                            name: row.string(2),
                            kind: row.string(3),
                            filePath: row.string(4),
                            range: Self.decodeRange(row.string(5)),
                            confidenceTier: row.string(6),
                            tierEvidence: Self.decodeTierEvidence(row.optionalString(8))
                        ),
                        callee: BurnBarProjectCodeSymbol(
                            symbolID: row.string(9),
                            name: row.string(10),
                            kind: row.string(11),
                            filePath: row.string(12),
                            range: Self.decodeRange(row.string(13)),
                            confidenceTier: row.string(14),
                            tierEvidence: Self.decodeTierEvidence(row.optionalString(16))
                        ),
                        confidenceTier: row.string(17)
                    ),
                    callerName: row.string(2),
                    calleeName: row.string(10),
                    stale: isCurrent == false
                )
            }
            let byCaller = Dictionary(grouping: candidates, by: \.callerName)
            let effectiveDepth = max(1, min(request.depth, 3))
            let edgeLimit = max(1, min(request.limit, 200))
            var selected: [BurnBarProjectCodeCallEdge] = []
            var seenEdgeIDs = Set<String>()
            var visitedSymbols = Set([request.name])

            func addCandidates(_ edges: [CandidateEdge]) -> [String] {
                var discovered: [String] = []
                for candidate in edges {
                    totalCandidateCount += 1
                    if candidate.stale {
                        staleCount += 1
                        continue
                    }
                    guard seenEdgeIDs.insert(candidate.edge.edgeID).inserted else { continue }
                    selected.append(candidate.edge)
                    for symbolName in [candidate.callerName, candidate.calleeName] where visitedSymbols.insert(symbolName).inserted {
                        discovered.append(symbolName)
                    }
                    if selected.count >= edgeLimit {
                        break
                    }
                }
                return discovered
            }

            var frontier = addCandidates(candidates.filter { $0.callerName == request.name || $0.calleeName == request.name })
            if effectiveDepth > 1 {
                for _ in 2...effectiveDepth {
                    guard selected.count < edgeLimit, frontier.isEmpty == false else { break }
                    let hopCandidates = frontier.flatMap { byCaller[$0] ?? [] }
                    frontier = addCandidates(hopCandidates)
                }
            }
            return (
                Array(selected.prefix(edgeLimit)),
                try staleDegradation(projectID: projectID, staleCandidateCount: staleCount, totalCandidateCount: totalCandidateCount)
            )
        }
        return BurnBarProjectCodeCallGraphResponse(
            traceID: traceID,
            projectID: projectID,
            edges: edges,
            status: degradation == nil ? "ok" : "degraded",
            degradation: degradation
        )
    }

    func diagnostics(_ request: BurnBarProjectCodeDiagnosticsRequest) throws -> BurnBarProjectCodeDiagnosticsResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let diagnostics = try databaseSync {
            var sql = "SELECT file_path, tool, payload_json, cached_at FROM code_diagnostics_cache WHERE project_id = ?"
            var binds: [SQLiteBind] = [.text(projectID)]
            if let filePath = request.filePath?.trimmingCharacters(in: .whitespacesAndNewlines), filePath.isEmpty == false {
                sql += " AND file_path = ?"
                binds.append(.text(filePath))
            }
            sql += " ORDER BY cached_at DESC LIMIT 200"
            return try queryRows(sql, binds).map {
                BurnBarProjectCodeDiagnostic(
                    filePath: $0.string(0),
                    tool: $0.string(1),
                    payloadJSON: $0.string(2),
                    cachedAt: $0.string(3)
                )
            }
        }
        return BurnBarProjectCodeDiagnosticsResponse(traceID: traceID, projectID: projectID, diagnostics: diagnostics)
    }

    func indexStatus(_ request: BurnBarProjectCodeIndexStatusRequest) throws -> BurnBarProjectCodeIndexStatusResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        return try databaseSync {
            let checkpoint = try queryRows(
                """
                SELECT project_root, indexed_at, artifact_count, chunk_count, rejected_count,
                       last_commit_sha, storage_byte_count, storage_budget_bytes, vacuumed_at
                FROM code_index_checkpoints
                WHERE project_id = ?
                LIMIT 1
                """,
                [.text(projectID)]
            ).first
            let storageByteCount = try projectStorageByteCount(projectID: projectID)
            let storedBudgetBytes = checkpoint.map { Int($0.int64(7)) } ?? 0
            let storageBudgetBytes = storedBudgetBytes > 0 ? storedBudgetBytes : Self.defaultProjectStorageBudgetBytes
            return BurnBarProjectCodeIndexStatusResponse(
                traceID: traceID,
                projectID: projectID,
                projectRoot: checkpoint?.optionalString(0),
                indexedAt: checkpoint?.optionalString(1),
                artifactCount: try fetchInt("SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?", [.text(projectID)]),
                chunkCount: checkpoint.map { Int($0.int64(3)) } ?? 0,
                symbolCount: try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", [.text(projectID)]),
                referenceCount: try fetchInt("SELECT COUNT(*) FROM code_references WHERE project_id = ?", [.text(projectID)]),
                callEdgeCount: try fetchInt("SELECT COUNT(*) FROM code_call_edges WHERE project_id = ?", [.text(projectID)]),
                rejectedCount: checkpoint.map { Int($0.int64(4)) } ?? 0,
                lastCommitSHA: checkpoint?.optionalString(5),
                pendingForgetCount: try fetchInt("SELECT COUNT(*) FROM memory_audit WHERE project_id = ? AND action = 'memory.forget'", [.text(projectID)]),
                storageByteCount: storageByteCount,
                storageBudgetBytes: storageBudgetBytes,
                storageWithinBudget: storageByteCount <= storageBudgetBytes,
                lastVacuumedAt: checkpoint?.optionalString(8),
                productionReady: false,
                productionReadinessReasons: projectCodeMemoryProductionReadinessReasons(),
                parserAvailable: Self.staticParserExecutablePath() != nil,
                databaseEncrypted: BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: databasePath),
                hostedCodeToolsEnabled: false,
                semanticAvailable: false
            )
        }
    }

    func opsDiagnostics(_ request: BurnBarProjectCodeOpsDiagnosticsRequest) throws -> BurnBarProjectCodeOpsDiagnosticsResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        return try databaseSync {
            let projectRows = try queryRows(
                """
                SELECT project_id, project_root, indexed_at, storage_byte_count, storage_budget_bytes
                FROM code_index_checkpoints
                ORDER BY indexed_at DESC
                """,
                []
            )
            let projects = try projectRows.map { row -> BurnBarProjectCodeStoreProjectStat in
                let projectID = row.string(0)
                let storedBudget = Int(row.int64(4))
                return BurnBarProjectCodeStoreProjectStat(
                    projectID: projectID,
                    projectRoot: row.optionalString(1),
                    artifactCount: try fetchInt("SELECT COUNT(*) FROM code_artifacts WHERE project_id = ?", [.text(projectID)]),
                    symbolCount: try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE project_id = ?", [.text(projectID)]),
                    referenceCount: try fetchInt("SELECT COUNT(*) FROM code_references WHERE project_id = ?", [.text(projectID)]),
                    storageByteCount: Int(row.int64(3)),
                    storageBudgetBytes: storedBudget > 0 ? storedBudget : Self.defaultProjectStorageBudgetBytes,
                    pendingForgetCount: try fetchInt("SELECT COUNT(*) FROM memory_audit WHERE project_id = ? AND action = 'memory.forget'", [.text(projectID)]),
                    indexedAt: row.optionalString(2)
                )
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath)
            let databaseFileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            return BurnBarProjectCodeOpsDiagnosticsResponse(
                traceID: traceID,
                schemaVersion: Self.schemaVersion,
                databaseFileBytes: databaseFileBytes,
                totalArtifactCount: try fetchInt("SELECT COUNT(*) FROM code_artifacts", []),
                totalSymbolCount: try fetchInt("SELECT COUNT(*) FROM code_symbols", []),
                totalStorageByteCount: try fetchInt("SELECT COALESCE(SUM(byte_count), 0) FROM code_artifacts", []),
                agentMemoryCount: try fetchInt("SELECT COUNT(*) FROM agent_memories", []),
                pendingCloudForgetCount: 0,
                projects: projects
            )
        }
    }

    func explore(_ request: BurnBarProjectCodeExploreRequest) throws -> BurnBarProjectCodeExploreResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try readOnlyProjectIdentity(root: root).projectID
        let hasCheckpoint = try databaseSync {
            try fetchInt("SELECT COUNT(*) FROM code_index_checkpoints WHERE project_id = ?", [.text(projectID)]) > 0
        }
        if hasCheckpoint == false {
            return BurnBarProjectCodeExploreResponse(
                traceID: traceID,
                projectID: projectID,
                files: [],
                repoMap: nil,
                context: nil,
                hits: [],
                truncated: false,
                status: "degraded",
                degradation: missingIndexDegradation(projectID: projectID)
            )
        }
        let files = try databaseSync {
            try queryRows(
                """
                SELECT a.file_path, a.lang, COUNT(s.id) AS symbol_count
                FROM code_artifacts a
                LEFT JOIN code_symbols s ON s.artifact_id = a.id
                WHERE a.project_id = ?
                GROUP BY a.id
                ORDER BY symbol_count DESC, a.file_path ASC
                LIMIT ?
                """,
                [.text(projectID), .int(max(1, min(request.limit, 500)))]
            ).map {
                BurnBarProjectCodeExploreFile(filePath: $0.string(0), lang: $0.optionalString(1), symbolCount: Int($0.int64(2)))
            }
        }
        let repoMap = try databaseSync {
            try projectRepoMap(projectID: projectID, topFiles: files)
        }
        if let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), query.isEmpty == false {
            let pack = try contextPack(
                BurnBarProjectCodeContextPackRequest(
                    query: query,
                    projectPath: root.path,
                    limit: request.limit,
                    maxBytes: request.maxBytes
                )
            )
            return BurnBarProjectCodeExploreResponse(
                traceID: traceID,
                projectID: projectID,
                files: files,
                repoMap: repoMap,
                context: pack.context,
                hits: pack.hits,
                truncated: pack.truncated
            )
        }
        return BurnBarProjectCodeExploreResponse(traceID: traceID, projectID: projectID, files: files, repoMap: repoMap)
    }

    /// Cosine scores for the recall candidates' stored vectors, best first.
    ///
    /// Only the candidates' rows are read: on a multi-project store
    /// `memory_embedding_refs` holds every project's vectors and most of them
    /// cannot rank for this query, so the candidate ids are bound into the
    /// query in chunks instead of filtering after a full-table read.
    func semanticCandidateScores(candidateIDs: [String], queryVector: [Float]) throws -> [(id: String, score: Double)] {
        var ranked: [(id: String, score: Double)] = []
        for chunkStart in stride(from: 0, to: candidateIDs.count, by: 500) {
            let chunk = Array(candidateIDs[chunkStart..<min(chunkStart + 500, candidateIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let rows = try queryRows(
                """
                SELECT memory_id, vector
                FROM memory_embedding_refs
                WHERE embedding_version_id = ? AND dimension = ? AND memory_id IN (\(placeholders))
                """,
                [.text(embeddingProvider.versionID), .int(embeddingProvider.dimension)] + chunk.map { SQLiteBind.text($0) }
            )
            ranked += rows.compactMap { row -> (id: String, score: Double)? in
                guard let data = row.data(1) else { return nil }
                guard let vector = BurnBarCodeVectorCodec.decode(data, dimension: embeddingProvider.dimension) else { return nil }
                let score = BurnBarCodeVectorCodec.cosine(queryVector, vector)
                return score > 0 ? (row.string(0), score) : nil
            }
        }
        ranked.sort { lhs, rhs in lhs.score == rhs.score ? lhs.id < rhs.id : lhs.score > rhs.score }
        return ranked
    }

    /// Salience state for only the rows that can participate in this recall.
    func salienceRows(candidateIDs: [String]) throws -> [SQLiteRow] {
        var result: [SQLiteRow] = []
        for chunkStart in stride(from: 0, to: candidateIDs.count, by: 500) {
            let chunk = Array(candidateIDs[chunkStart..<min(chunkStart + 500, candidateIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            result += try queryRows(
                "SELECT memory_id, hit_count, last_reinforced_at FROM memory_salience WHERE memory_id IN (\(placeholders))",
                chunk.map { SQLiteBind.text($0) }
            )
        }
        return result
    }

    private func missingIndexDegradation(projectID: String) -> BurnBarProjectCodeDegradation {
        BurnBarProjectCodeDegradation(
            code: "INDEX_MISSING",
            message: "No project code index exists for this project, so the read-only explore request did not index files.",
            staleCandidateCount: 0,
            totalCandidateCount: 0,
            indexAgeSeconds: nil,
            reindexHint: "Run burnbar_index_project for this project before relying on code-memory results."
        )
    }
}
