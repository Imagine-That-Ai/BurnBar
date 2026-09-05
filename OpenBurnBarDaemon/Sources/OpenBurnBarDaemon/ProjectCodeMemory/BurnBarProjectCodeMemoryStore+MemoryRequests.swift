import Foundation
import OpenBurnBarEngine

// Agent-memory request handlers: remember / recall / forget / analytics.
// Quarantine + blind-sync body placement lives in +MemoryPersistence; the
// hash-chained audit row each mutation appends lives in +AuditTrail.
extension BurnBarProjectCodeMemoryStore {
    func remember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyText }
        guard request.reviewStatus == .approved || request.reviewStatus == .quarantined else {
            throw BurnBarProjectCodeMemoryStoreError.invalidMemoryReviewStatus(request.reviewStatus.rawValue)
        }
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let freeformFields = ([body, request.kind, request.scope] + request.tags + [request.sourcePath].compactMap { $0 })
            .joined(separator: "\n")
        let labels = Self.secretLabels(in: freeformFields)
        if labels.isEmpty == false {
            let hash = try databaseSync {
                try auditEvent(action: "memory.secret_rejected", domain: "memory", projectID: projectID, subjectID: nil, labels: labels)
            }
            logger.warning("project_memory_secret_rejected", metadata: ["project_id": projectID, "audit_hash": hash])
            throw BurnBarProjectCodeMemoryStoreError.secretRejected(labels: labels)
        }
        let injectionLabels = Self.memoryInjectionLabels(in: freeformFields)
        let reviewStatus: MemoryReviewStatus = injectionLabels.isEmpty ? request.reviewStatus : .quarantined
        // Keep semantic vectors body-only, matching the Python engine. Tags are
        // lexical evidence and must not distort the mirrored row's embedding.
        let memoryVector = embeddingProvider.isAvailable ? embeddingProvider.embed(body) : nil

        return try databaseSync {
            let bodyRef = Self.sha256Hex(body)
            let memoryID = "mem_" + String(Self.sha256Hex("\(projectID):\(request.scope):\(bodyRef)").prefix(32))
            let now = Self.isoNow()
            // Only the Memory MCP engine sends an id of its own, and it sends one
            // only for rows it wants mirrored as syncable. Its presence is therefore
            // the partition: callers that predate blind sync keep writing repository
            // knowledge, which never leaves the device.
            let engineMemoryID = request.engineMemoryID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let resolvedSourceKind = engineMemoryID == nil
                ? MemorySourceKind.code.rawValue
                : MemorySourceKind.agent.rawValue
            // The engine's taxonomy is richer than the app's `MemoryKind`, and the
            // app drops any row whose kind it cannot decode. A mirrored row is
            // therefore stored under the nearest app kind; the engine store keeps
            // the precise one, and it stays a tag here.
            let storedKind = engineMemoryID == nil
                ? request.kind
                : (MemoryKind(rawValue: request.kind)?.rawValue ?? MemoryKind.other.rawValue)
            // A normalised kind loses the engine's precise one, so keep it as a tag:
            // the mirrored row still says what it is, and nothing is lost locally.
            let storedTags = storedKind == request.kind ? request.tags : request.tags + ["engine-kind:\(request.kind)"]
            let tagsJSON = try encodeJSONString(storedTags)
            try execute("BEGIN IMMEDIATE", [])
            do {
                if reviewStatus == .approved {
                    try upsertProjectMemorySection(
                        projectID: projectID,
                        projectDisplayName: root.lastPathComponent,
                        memoryID: memoryID,
                        body: body,
                        kind: request.kind,
                        scope: request.scope,
                        tags: request.tags,
                        sourcePath: request.sourcePath,
                        now: now
                    )
                    try removeQuarantineMemoryBody(projectID: projectID, memoryID: memoryID)
                    // Blind sync: an approved memory the Memory MCP engine mirrored keeps
                    // its body in the shared encrypted database so the app's sync lane can
                    // seal and upload it. Nothing else writes here, so repository knowledge
                    // and quarantined input can never reach the cloud lane.
                    if let engineMemoryID {
                        try upsertAgentMemoryBody(
                            projectID: projectID,
                            memoryID: memoryID,
                            engineMemoryID: engineMemoryID,
                            body: body,
                            bodyHash: bodyRef,
                            now: now
                        )
                    } else {
                        try removeAgentMemoryBody(projectID: projectID, memoryID: memoryID)
                    }
                } else {
                    // Quarantined input remains reviewable in a dedicated
                    // encrypted-at-rest holding table, never in the default
                    // project-memory snapshot returned to agents.
                    try removeProjectMemorySection(
                        projectID: projectID,
                        projectDisplayName: root.lastPathComponent,
                        memoryID: memoryID,
                        now: now
                    )
                    try upsertQuarantineMemoryBody(projectID: projectID, memoryID: memoryID, body: body, now: now)
                    // Remirrored as unapproved after an upload: blank, never delete, so
                    // the sync lane can still address the sealed copy (see the helper).
                    try blankAgentMemoryBody(projectID: projectID, memoryID: memoryID, now: now)
                }
                let bodyReference = reviewStatus == .approved
                    ? Self.memoryBodyReference(memoryID: memoryID, projectID: projectID)
                    : Self.quarantineBodyReference(memoryID: memoryID, projectID: projectID)
                try execute(
                    """
                    INSERT INTO agent_memories
                        (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path, valid_from, review_status, source_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        source_kind = excluded.source_kind,
                        kind = excluded.kind,
                        scope = excluded.scope,
                        confidence = excluded.confidence,
                        body_ref = excluded.body_ref,
                        body_redacted = excluded.body_redacted,
                        tags_json = excluded.tags_json,
                        source_path = excluded.source_path,
                        review_status = excluded.review_status,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(memoryID), .text(projectID), .text(storedKind), .text(request.scope),
                        .double(request.confidence), .text(bodyRef), .text(bodyReference),
                        .text(tagsJSON), request.sourcePath.map(SQLiteBind.text) ?? .null, .text(now),
                        .text(reviewStatus.rawValue), .text(resolvedSourceKind), .text(now), .text(now)
                    ]
                )
                if let memoryVector, memoryVector.count == embeddingProvider.dimension {
                    let norm = memoryVector.reduce(0.0) { partial, value in
                        partial + Double(value * value)
                    }.squareRoot()
                    try execute(
                        """
                        INSERT INTO memory_embedding_refs
                            (memory_id, embedding_version_id, dimension, vector, norm, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(memory_id, embedding_version_id) DO UPDATE SET
                            dimension = excluded.dimension,
                            vector = excluded.vector,
                            norm = excluded.norm,
                            created_at = excluded.created_at
                        """,
                        [
                            .text(memoryID), .text(embeddingProvider.versionID), .int(memoryVector.count),
                            .blob(BurnBarCodeVectorCodec.encode(memoryVector)), .double(norm), .text(now)
                        ]
                    )
                }
                let salience = BurnBarMemoryRanking.salience(
                    kind: request.kind,
                    confidence: request.confidence,
                    accessCount: 0
                )
                try execute(
                    """
                    INSERT INTO memory_salience
                        (memory_id, salience, hit_count, last_reinforced_at, corroboration, source_trust, computed_at, updated_at)
                    VALUES (?, ?, 0, NULL, 1, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        salience = excluded.salience,
                        computed_at = excluded.computed_at,
                        updated_at = excluded.updated_at
                    """,
                    [.text(memoryID), .double(salience), .double(1.0), .text(now), .text(now)]
                )
                let auditHash = try auditEvent(
                    action: "memory.remember",
                    domain: "memory",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: ["review_status:\(reviewStatus.rawValue)"] + injectionLabels
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemoryRememberResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func recall(_ request: BurnBarProjectMemoryRecallRequest) throws -> BurnBarProjectMemoryRecallResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyQuery }
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let limit = max(1, min(request.limit, 100))
        let scope = request.scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = Self.searchTokens(in: query)
        let queryVector = embeddingProvider.isAvailable ? embeddingProvider.embed(query) : nil

        let hits = try databaseSync { () -> [BurnBarProjectMemoryHit] in
            var clauses: [String] = []
            var binds: [SQLiteBind] = []
            if request.includeCrossProject == false {
                clauses.append("m.project_id = ?")
                binds.append(.text(projectID))
            }
            if scope != "all", scope.isEmpty == false {
                clauses.append("m.scope = ?")
                binds.append(.text(scope))
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
            let sql = """
                SELECT m.id, m.project_id, m.kind, m.scope, m.confidence, m.body_redacted,
                       m.tags_json, m.source_path, m.updated_at, m.review_status
                FROM agent_memories AS m
                \(whereClause.isEmpty ? "WHERE 1 = 1" : whereClause)
                AND (
                    m.review_status = 'approved'
                    OR (? = 1 AND m.review_status IN ('quarantined', 'rejected'))
                    OR (? = 1 AND m.review_status = 'forgotten')
                )
                ORDER BY m.updated_at DESC
                LIMIT 1000
            """
            let queryBinds = binds + [.int(request.includeQuarantined ? 1 : 0), .int(request.includeForgotten ? 1 : 0)]
            let candidates = try queryRows(sql, queryBinds)
                .map { row in
                    MemoryIndexRow(
                        id: row.string(0),
                        projectID: row.string(1),
                        kind: row.string(2),
                        scope: row.string(3),
                        confidence: row.double(4),
                        bodyReference: row.string(5),
                        tags: decodeStringArray(row.string(6)),
                        sourcePath: row.optionalString(7),
                        updatedAt: row.string(8),
                        reviewStatus: MemoryReviewStatus(rawValue: row.string(9)) ?? .approved
                    )
                }
                .compactMap { row -> MemoryRecallCandidate? in
                    let body: String?
                    if row.reviewStatus == .approved {
                        body = try projectMemorySectionBody(projectID: row.projectID, memoryID: row.id)
                    } else {
                        body = try quarantineMemoryBody(projectID: row.projectID, memoryID: row.id)
                    }
                    if body == nil, row.reviewStatus != .forgotten || request.includeForgotten == false {
                        return nil
                    }
                    let searchable = ([body ?? ""] + row.tags + [row.sourcePath ?? ""]).joined(separator: " ")
                    return MemoryRecallCandidate(row: row, body: body ?? "", searchableTokens: BurnBarMemoryRanking.tokenize(searchable))
                }
            if request.includeQuarantined || request.includeForgotten {
                return Array(candidates.prefix(limit).map { candidate in
                    BurnBarProjectMemoryHit(
                        memoryID: candidate.row.id,
                        projectID: candidate.row.projectID,
                        kind: candidate.row.kind,
                        scope: candidate.row.scope,
                        confidence: candidate.row.confidence,
                        bodyRedacted: candidate.body,
                        tags: candidate.row.tags,
                        sourcePath: candidate.row.sourcePath,
                        snippet: candidate.body.isEmpty ? "" : Self.memorySnippet(body: candidate.body, tokens: tokens, fallbackQuery: query),
                        rank: nil,
                        reviewStatus: candidate.row.reviewStatus
                    )
                })
            }
            let candidatesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.row.id, $0) })
            let salienceRows = try salienceRows(candidateIDs: candidatesByID.keys.sorted())
            let salienceByID = Dictionary(uniqueKeysWithValues: salienceRows.map { row in
                (row.string(0), (hitCount: Int(row.int64(1)), lastReinforcedAt: row.optionalString(2)))
            })
            let lexical = BurnBarMemoryRanking.bm25Rank(
                documents: candidates.reduce(into: [:]) { $0[$1.row.id] = $1.searchableTokens },
                queryTokens: BurnBarMemoryRanking.tokenize(query),
                limit: max(limit * 4, 50)
            )
            var semantic: [(id: String, score: Double)] = []
            if let queryVector, queryVector.count == embeddingProvider.dimension {
                let ranked = try semanticCandidateScores(candidateIDs: candidatesByID.keys.sorted(), queryVector: queryVector)
                semantic = Array(ranked.prefix(max(limit * 4, 50)))
            }
            let fusedScores = BurnBarMemoryRanking.reciprocalRankScores(
                lexical: lexical.map(\.id),
                semantic: semantic.map(\.id)
            )
            let now = Date()
            let finalScores = fusedScores.reduce(into: [String: Double]()) { scores, entry in
                guard let candidate = candidatesByID[entry.key] else { return }
                let state = salienceByID[entry.key] ?? (hitCount: 0, lastReinforcedAt: nil)
                let salience = BurnBarMemoryRanking.salience(
                    kind: candidate.row.kind,
                    confidence: candidate.row.confidence,
                    accessCount: state.hitCount
                )
                let recency = BurnBarMemoryRanking.recencyFactor(
                    kind: candidate.row.kind,
                    updatedAt: candidate.row.updatedAt,
                    lastAccessedAt: state.lastReinforcedAt,
                    now: now
                )
                scores[entry.key] = entry.value * (0.6 + 0.4 * min(1.0, max(0.0, salience))) * recency
            }
            let rankedIDs = finalScores.keys.sorted { lhs, rhs in
                let lhsScore = finalScores[lhs] ?? 0
                let rhsScore = finalScores[rhs] ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                let lhsUpdatedAt = candidatesByID[lhs]?.row.updatedAt ?? ""
                let rhsUpdatedAt = candidatesByID[rhs]?.row.updatedAt ?? ""
                return lhsUpdatedAt == rhsUpdatedAt ? lhs < rhs : lhsUpdatedAt < rhsUpdatedAt
            }
            let selectedIDs = Array(rankedIDs.prefix(limit))
            let reinforcedAt = Self.isoNow()
            for id in selectedIDs {
                guard let candidate = candidatesByID[id] else { continue }
                let nextHitCount = (salienceByID[id]?.hitCount ?? 0) + 1
                let nextSalience = BurnBarMemoryRanking.salience(
                    kind: candidate.row.kind,
                    confidence: candidate.row.confidence,
                    accessCount: nextHitCount
                )
                try execute(
                    """
                    INSERT INTO memory_salience
                        (memory_id, salience, hit_count, last_reinforced_at, corroboration, source_trust, computed_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        salience = excluded.salience,
                        hit_count = excluded.hit_count,
                        last_reinforced_at = excluded.last_reinforced_at,
                        computed_at = excluded.computed_at,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(id), .double(nextSalience), .int(nextHitCount), .text(reinforcedAt),
                        .double(1.0), .text(reinforcedAt), .text(reinforcedAt)
                    ]
                )
            }
            return selectedIDs.enumerated().compactMap { index, id in
                guard let candidate = candidatesByID[id] else { return nil }
                return BurnBarProjectMemoryHit(
                    memoryID: candidate.row.id,
                    projectID: candidate.row.projectID,
                    kind: candidate.row.kind,
                    scope: candidate.row.scope,
                    confidence: candidate.row.confidence,
                    bodyRedacted: candidate.body,
                    tags: candidate.row.tags,
                    sourcePath: candidate.row.sourcePath,
                    snippet: Self.memorySnippet(body: candidate.body, tokens: tokens, fallbackQuery: query),
                    rank: Double(index),
                    reviewStatus: candidate.row.reviewStatus
                )
            }
        }
        return BurnBarProjectMemoryRecallResponse(traceID: traceID, projectID: projectID, hits: hits)
    }

    func forget(_ request: BurnBarProjectMemoryForgetRequest) throws -> BurnBarProjectMemoryForgetResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let memoryID = request.memoryID.trimmingCharacters(in: .whitespacesAndNewlines)
        return try databaseSync {
            let rows = try queryRows(
                "SELECT id, review_status FROM agent_memories WHERE id = ? AND project_id = ? LIMIT 1",
                [.text(memoryID), .text(projectID)]
            )
            let existed = rows.isEmpty == false
            try execute("BEGIN IMMEDIATE", [])
            do {
                try removeProjectMemorySection(
                    projectID: projectID,
                    projectDisplayName: root.lastPathComponent,
                    memoryID: memoryID,
                    now: Self.isoNow()
                )
                try removeQuarantineMemoryBody(projectID: projectID, memoryID: memoryID)
                // A mirrored memory's body is content the member deleted, so it goes
                // now; its engine id stays so the sealed cloud copy is still
                // addressable when the forget reaches the sync lane.
                try blankAgentMemoryBody(projectID: projectID, memoryID: memoryID, now: Self.isoNow())
                // Keep a metadata tombstone so every forget remains visible to the
                // daemon-owned review/audit feed across reloads and devices. The sealed
                // body is removed above and the row is excluded from normal recall.
                try execute(
                    "UPDATE agent_memories SET body_ref = '', body_redacted = '', review_status = 'forgotten', updated_at = ? WHERE id = ? AND project_id = ?",
                    [.text(Self.isoNow()), .text(memoryID), .text(projectID)]
                )
                try execute("DELETE FROM memory_salience WHERE memory_id = ?", [.text(memoryID)])
                try execute("DELETE FROM memory_embedding_refs WHERE memory_id = ?", [.text(memoryID)])
                let auditHash = try auditEvent(
                    action: "memory.forget",
                    domain: "memory",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: ["local body delete", "metadata tombstone", "review_status:forgotten", "snapshot section removed"]
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemoryForgetResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    localDeleted: existed,
                    cloudDeletePending: false,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func memoryAnalytics(_ request: BurnBarProjectMemoryAnalyticsRequest) throws -> BurnBarProjectMemoryAnalyticsResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        return try databaseSync {
            BurnBarProjectMemoryAnalyticsResponse(
                traceID: traceID,
                projectID: projectID,
                total: try fetchInt("SELECT COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten'", [.text(projectID)]),
                byKind: try groupedCounts("SELECT kind, COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten' GROUP BY kind", [.text(projectID)]),
                byScope: try groupedCounts("SELECT scope, COUNT(*) FROM agent_memories WHERE project_id = ? AND review_status != 'forgotten' GROUP BY scope", [.text(projectID)]),
                lastAuditHash: try queryRows("SELECT hash FROM memory_audit ORDER BY seq DESC LIMIT 1", []).first?.optionalString(0)
            )
        }
    }

    private func recallLikeFallback(
        query: String,
        projectID: String,
        scope: String,
        includeCrossProject: Bool,
        limit: Int
    ) throws -> [BurnBarProjectMemoryHit] {
        var clauses = ["body_redacted LIKE ?"]
        var binds: [SQLiteBind] = [.text("%\(query)%")]
        if includeCrossProject == false {
            clauses.append("project_id = ?")
            binds.append(.text(projectID))
        }
        if scope != "all", scope.isEmpty == false {
            clauses.append("scope = ?")
            binds.append(.text(scope))
        }
        binds.append(.int(limit))
        return try queryRows(
            """
            SELECT id, project_id, kind, scope, confidence, body_redacted, tags_json, source_path
            FROM agent_memories
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            binds
        ).map { row in
            BurnBarProjectMemoryHit(
                memoryID: row.string(0),
                projectID: row.string(1),
                kind: row.string(2),
                scope: row.string(3),
                confidence: row.double(4),
                bodyRedacted: row.string(5),
                tags: decodeStringArray(row.string(6)),
                sourcePath: row.optionalString(7),
                snippet: row.string(5),
                rank: nil
            )
        }
    }
}
