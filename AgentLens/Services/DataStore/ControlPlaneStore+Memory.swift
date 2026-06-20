import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - ControlPlaneStore chat-memory subsystem
//
// This file was split out of ControlPlaneStore.swift to keep both files under the
// 2000-line debt ceiling. It owns the chat-memory authority CRUD, recall/search/page,
// the extraction-job queue, embedding refs, the chat-memory private helpers and nested
// types, the Array.uniqued() helper, and the extraction worker/admission actors.
//
// Shared, single-sourced helpers (iso8601String, insertMemoryAuditEvent, auditLabelsJSON,
// auditPayloadData, sha256Hex(_:Data)) intentionally remain in ControlPlaneStore.swift
// because they are also called by ControlPlaneStore+MemoryForget.swift; Swift `internal`
// access keeps them reachable across the split. Likewise, this file calls back into
// +MemoryForget's `insertMemoryFactTombstone` / `memoryHasTombstonedSource` (both internal).

extension ControlPlaneStore {
    // MARK: - Chat Memory Authority (flagged off)

    enum ChatMemoryAuthorityError: Error, LocalizedError, Equatable {
        case disabled
        case emptyBody
        case secretRejected(labels: [String])

        var errorDescription: String? {
            switch self {
            case .disabled:
                "Chat memory authority writes are disabled."
            case .emptyBody:
                "Chat memory body is empty."
            case .secretRejected(let labels):
                "Chat memory body was rejected by the secret scanner: \(labels.joined(separator: ", "))."
            }
        }
    }

    enum MemoryEmbeddingStoreError: Error, LocalizedError, Equatable {
        case emptyVector
        case unknownEmbeddingVersion(String)
        case dimensionMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .emptyVector:
                "Memory embedding vector is empty."
            case .unknownEmbeddingVersion(let versionID):
                "Memory embedding version is not registered: \(versionID)."
            case .dimensionMismatch(let expected, let actual):
                "Memory embedding dimension mismatch: expected \(expected), got \(actual)."
            }
        }
    }

    struct MemoryEmbeddingRegistration: Equatable, Sendable {
        let modelID: String
        let versionID: String
        let dimension: Int
    }

    struct MemoryEmbeddingMatch: Equatable, Sendable {
        let memoryID: MemoryID
        let score: Double
    }

    struct MemoryExtractionJob: Equatable, Sendable {
        static let defaultLeaseDuration: TimeInterval = 15 * 60

        let id: String
        let idempotencyKey: String
        let threadID: String
        let threadLogicalID: String
        let messageID: String
        let promptVersion: String
        let scope: MemoryScope
        let status: MemoryEventStatus
        let attempts: Int
        let lastError: String?
        let notBefore: Date?
        let leaseExpiresAt: Date?
        let createdAt: Date
        let updatedAt: Date
    }

    // Chat-memory secret/PII gating is delegated to the shared, fail-closed
    // `MemorySecretPIIGate` in OpenBurnBarCore (single source of truth, shared
    // with the daemon). The chat persistence + audit contract keys off the
    // stable dashed finding id (e.g. `openai-api-key`), so chat call sites
    // project `MemoryGateFinding.id` via `memoryGateFindingIDs(in:)`. The legacy
    // 6-regex `MemorySecretScanner` was removed in PR-C1 to kill the two-scanner
    // drift; the gate adds entropy + decode-rescan + Luhn/IPv4 validation.
    static func memoryGateFindingIDs(in text: String) -> [String] {
        MemorySecretPIIGate.findingIDs(in: text)
    }

    func addChatMemoryAuthorityRecord(
        _ request: MemoryAddRequest,
        id: MemoryID = UUID().uuidString,
        now: Date = Date(),
        enabled: Bool = ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
    ) async throws -> Memory {
        guard enabled else { throw ChatMemoryAuthorityError.disabled }
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw ChatMemoryAuthorityError.emptyBody }

        let secretLabels = Self.memoryGateFindingIDs(in: body)
        if secretLabels.isEmpty == false {
            try await appendMemoryAuditEvent(
                action: "memory.secret_rejected",
                projectID: Self.memoryStorageProjectID(for: request.scope),
                subjectID: id,
                labels: [
                    "memory_id": id,
                    "source_kind": MemorySourceKind.chat.rawValue,
                    "labels": secretLabels.joined(separator: ",")
                ],
                now: now
            )
            throw ChatMemoryAuthorityError.secretRejected(labels: secretLabels)
        }

        let bodyHash = Self.sha256Hex(body)
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let bodyRef = Self.memorySnapshotRef(snapshotSlug)
        let storageProjectID = Self.memoryStorageProjectID(for: request.scope)
        let nowString = Self.iso8601String(now)
        let citations = request.citations
        let snapshotJSON = try Self.memoryBodySnapshotJSON(
            memoryID: id,
            body: body,
            bodyHash: bodyHash,
            citations: citations,
            createdAt: now
        )
        let auditLabels = [
            "body_ref:\(bodyRef)",
            "memory_id:\(id)",
            "review_status:\(request.reviewStatus.rawValue)",
            "source_kind:\(MemorySourceKind.chat.rawValue)"
        ].sorted()

        let dedupState = try await dbQueue.write { db -> (validTo: Date?, supersededBy: MemoryID?) in
            let duplicateRows = try Self.chatMemoryDuplicateCandidates(
                db: db,
                bodyHash: bodyHash,
                storageProjectID: storageProjectID,
                kind: request.kind,
                scope: request.scope,
                excludingID: id
            )
            let winnerID = Self.memoryDedupWinnerID(
                duplicateRows: duplicateRows,
                newID: id,
                newConfidence: request.confidence,
                newReviewStatus: request.reviewStatus,
                newValidFrom: now
            )
            let newSupersededBy = winnerID == id ? nil : winnerID
            let newValidTo = newSupersededBy == nil ? nil : now
            try db.execute(
                sql: """
                INSERT INTO memory_body_snapshots (
                    id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(memory_id) DO UPDATE SET
                    body_ref = excluded.body_ref,
                    snapshot_json = excluded.snapshot_json,
                    body_hash = excluded.body_hash,
                    source_kind = excluded.source_kind,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    snapshotSlug,
                    id,
                    bodyRef,
                    snapshotJSON,
                    bodyHash,
                    MemorySourceKind.chat.rawValue,
                    now,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at,
                    source_kind, review_status, user_id, agent_id, run_id, app_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    id,
                    storageProjectID,
                    request.kind.rawValue,
                    "chat",
                    request.confidence,
                    bodyRef,
                    bodyRef,
                    "[]",
                    nil,
                    now,
                    newValidTo,
                    newSupersededBy,
                    now,
                    now,
                    MemorySourceKind.chat.rawValue,
                    request.reviewStatus.rawValue,
                    request.scope.userID,
                    request.scope.agentID,
                    request.scope.runID,
                    request.scope.appID
                ]
            )
            for citation in citations {
                try db.execute(
                    sql: """
                    INSERT INTO memory_provenance (
                        id, memory_id, source_kind, thread_logical_id, message_id, role,
                        authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        Self.memoryProvenanceID(memoryID: id, citationID: citation.id),
                        id,
                        "chat_message",
                        citation.threadLogicalID,
                        citation.messageID,
                        citation.role,
                        citation.authoredAt,
                        citation.contentHash,
                        citation.occurrence,
                        citation.crossDeviceHMAC,
                        citation.citationState.rawValue,
                        now
                    ]
                )
            }
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.add",
                projectID: storageProjectID,
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
            try Self.mergeDuplicateChatMemories(
                db: db,
                duplicateRows: duplicateRows,
                newID: id,
                winnerID: winnerID,
                storageProjectID: storageProjectID,
                now: now,
                nowString: nowString
            )
            return (newValidTo, newSupersededBy)
        }

        return Memory(
            id: id,
            sourceKind: .chat,
            kind: request.kind,
            scope: request.scope,
            confidence: request.confidence,
            bodyRedacted: bodyRef,
            reviewStatus: request.reviewStatus,
            citations: citations,
            validFrom: now,
            validTo: dedupState.validTo,
            supersededBy: dedupState.supersededBy,
            createdAt: now,
            updatedAt: now
        )
    }

    func enqueueMemoryExtraction(_ intent: ExtractionIntent, now: Date = Date()) async throws -> String {
        try await dbQueue.write { db in
            try self.enqueueMemoryExtraction(intent, in: db, now: now)
        }
    }

    /// Transaction-scoped enqueue (shared INSERT) so the outbox row commits atomically with the chat write (G3/P1b).
    func enqueueMemoryExtraction(_ intent: ExtractionIntent, in db: Database, now: Date = Date()) throws -> String {
        let id = "memory-extraction-\(Self.sha256Hex(intent.idempotencyKey))"
        let scopeData = try JSONEncoder().encode(intent.scope)
        guard let scopeJSON = String(data: scopeData, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.MemoryExtraction", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Extraction scope could not be encoded as UTF-8."
            ])
        }
        try db.execute(
            sql: """
            INSERT INTO memory_extraction_jobs (
                id, idempotency_key, thread_id, thread_logical_id, message_id,
                prompt_version, scope_json, status, attempts, last_error,
                not_before, lease_expires_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, NULL, ?, ?)
            ON CONFLICT(idempotency_key) DO UPDATE SET
                thread_id = excluded.thread_id,
                thread_logical_id = excluded.thread_logical_id,
                message_id = excluded.message_id,
                prompt_version = excluded.prompt_version,
                scope_json = excluded.scope_json,
                status = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN 'pending'
                    ELSE memory_extraction_jobs.status
                END,
                attempts = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN 0
                    ELSE memory_extraction_jobs.attempts
                END,
                last_error = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.last_error
                END,
                not_before = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.not_before
                END,
                lease_expires_at = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.lease_expires_at
                END,
                updated_at = excluded.updated_at
            """,
            arguments: [
                id,
                intent.idempotencyKey,
                intent.threadID,
                intent.threadLogicalID,
                intent.messageID,
                intent.promptVersion,
                scopeJSON,
                now,
                now
            ]
        )
        return id
    }

    func claimNextMemoryExtractionJob(
        now: Date = Date(),
        maxAttempts: Int = 3,
        leaseDuration: TimeInterval = MemoryExtractionJob.defaultLeaseDuration
    ) async throws -> MemoryExtractionJob? {
        try await dbQueue.write { db in
            let boundedMaxAttempts = max(1, maxAttempts)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM memory_extraction_jobs
                WHERE (
                    status = 'pending'
                    AND (not_before IS NULL OR not_before <= ?)
                ) OR (
                    status = 'failed'
                    AND attempts < ?
                    AND not_before IS NOT NULL
                    AND not_before <= ?
                ) OR (
                    status = 'running'
                    AND attempts < ?
                    AND lease_expires_at IS NOT NULL
                    AND lease_expires_at <= ?
                )
                ORDER BY created_at ASC, id ASC
                LIMIT 1
                """,
                arguments: [now, boundedMaxAttempts, now, boundedMaxAttempts, now]
            ),
                  var job = Self.memoryExtractionJob(from: row) else {
                return nil
            }
            let leaseExpiresAt = now.addingTimeInterval(max(1, leaseDuration))
            try db.execute(
                sql: """
                UPDATE memory_extraction_jobs
                SET status = 'running', attempts = attempts + 1, lease_expires_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [leaseExpiresAt, now, job.id]
            )
            job = MemoryExtractionJob(
                id: job.id,
                idempotencyKey: job.idempotencyKey,
                threadID: job.threadID,
                threadLogicalID: job.threadLogicalID,
                messageID: job.messageID,
                promptVersion: job.promptVersion,
                scope: job.scope,
                status: .running,
                attempts: job.attempts + 1,
                lastError: job.lastError,
                notBefore: job.notBefore,
                leaseExpiresAt: leaseExpiresAt,
                createdAt: job.createdAt,
                updatedAt: now
            )
            return job
        }
    }

    func markMemoryExtractionJobSucceeded(_ id: String, now: Date = Date()) async throws {
        try await updateMemoryExtractionJob(
            id,
            status: .succeeded,
            lastError: nil,
            notBefore: nil,
            now: now
        )
    }

    func markMemoryExtractionJobFailed(
        _ id: String,
        error: String,
        retryAfter: TimeInterval,
        now: Date = Date()
    ) async throws {
        try await updateMemoryExtractionJob(
            id,
            status: .failed,
            lastError: error,
            notBefore: now.addingTimeInterval(retryAfter),
            now: now
        )
    }

    func memoryExtractionJobStatus(id: String) async throws -> MemoryEventStatus? {
        try await dbQueue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT status FROM memory_extraction_jobs WHERE id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            return MemoryEventStatus(rawValue: raw)
        }
    }

    /// The most-recently-updated job currently in `failed` status, or nil if none.
    /// The `MemoryExtractionEngine` reads this after a `claimedButFailed` drain tick to
    /// surface `lastError` (PR-D2 must-fix #3): extraction errors are swallowed by the
    /// worker — they never propagate through `drainNext()` — so the terminal status is
    /// the only place a failure is observable. A best-effort diagnostic read; not a gate.
    func mostRecentFailedMemoryExtractionJob() async throws -> MemoryExtractionJob? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM memory_extraction_jobs
                WHERE status = 'failed'
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return Self.memoryExtractionJob(from: row)
        }
    }

    func fetchChatMemoryAuthorityRecord(id: MemoryID) async throws -> Memory? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE id = ? AND source_kind = ?
                LIMIT 1
                """,
                arguments: [id, MemorySourceKind.chat.rawValue]
            ) else {
                return nil
            }

            let citationRows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_provenance
                WHERE memory_id = ?
                ORDER BY authored_at ASC, occurrence ASC, id ASC
                """,
                arguments: [id]
            )
            let citations = citationRows.compactMap(Self.memoryCitation(from:))
            return Self.memory(from: row, citations: citations)
        }
    }

    /// Fetch the chat transcript for `threadID` as the lightweight provenance view the
    /// extractor reasons over and the worker cites. Reads `chat_messages` from the
    /// shared db queue (the control-plane store and the chat store share one queue), so
    /// the worker can recompute provenance without a second store handle. Tool/system
    /// rows are excluded: only user/assistant turns are citable provenance (G8).
    func fetchChatTranscriptForExtraction(threadID: String) async throws -> [ChatTranscriptMessage] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, role, content, timestamp
                FROM chat_messages
                WHERE threadId = ? AND role IN ('user', 'assistant')
                ORDER BY timestamp ASC, id ASC
                """,
                arguments: [threadID]
            )
            return rows.compactMap { row -> ChatTranscriptMessage? in
                guard let id = row["id"] as? String,
                      let role = row["role"] as? String,
                      let content = row["content"] as? String,
                      let authoredAt = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
                    return nil
                }
                return ChatTranscriptMessage(id: id, role: role, body: content, authoredAt: authoredAt)
            }
        }
    }

    /// Fetch a single citable source message by id, scoped to the job's thread, for
    /// worker-side provenance recomputation (PR-D1 must-fix #1/#3). Returns nil when the
    /// message is absent or not a user/assistant turn — the caller then drops the
    /// citation rather than fabricating provenance.
    func fetchChatProvenanceSourceMessage(
        threadID: String,
        messageID: String
    ) async throws -> ChatTranscriptMessage? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, role, content, timestamp
                FROM chat_messages
                WHERE threadId = ? AND id = ? AND role IN ('user', 'assistant')
                LIMIT 1
                """,
                arguments: [threadID, messageID]
            ),
                  let id = row["id"] as? String,
                  let role = row["role"] as? String,
                  let content = row["content"] as? String,
                  let authoredAt = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
                return nil
            }
            return ChatTranscriptMessage(id: id, role: role, body: content, authoredAt: authoredAt)
        }
    }

    func openChatMemoryBody(id: MemoryID) async throws -> String? {
        let snapshotSlug = Self.memorySnapshotSlug(id)
        return try await dbQueue.read { db in
            guard let snapshotJSON = try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM memory_body_snapshots WHERE id = ? AND memory_id = ?",
                arguments: [snapshotSlug, id]
            ),
                  let data = snapshotJSON.data(using: .utf8)
            else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MemoryBodySnapshot.self, from: data).body
        }
    }

    func fetchActiveChatMemoryAuthorityRecords(scope: MemoryScope? = nil, kind: MemoryKind? = nil) async throws -> [Memory] {
        try await dbQueue.read { db in
            var predicates = ["source_kind = ?", "valid_to IS NULL"]
            var arguments: [any DatabaseValueConvertible] = [MemorySourceKind.chat.rawValue]
            if let kind {
                predicates.append("kind = ?")
                arguments.append(kind.rawValue)
            }
            if let scope {
                predicates.append("project_id = ?")
                arguments.append(Self.memoryStorageProjectID(for: scope))
                Self.appendScopePredicates(scope, to: &predicates, arguments: &arguments)
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY confidence DESC, valid_from ASC, id ASC
                """,
                arguments: StatementArguments(arguments)
            )
            return try rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let citationRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM memory_provenance
                    WHERE memory_id = ?
                    ORDER BY authored_at ASC, occurrence ASC, id ASC
                    """,
                    arguments: [id]
                )
                return Self.memory(from: row, citations: citationRows.compactMap(Self.memoryCitation(from:)))
            }
        }
    }

    func chatMemoryPage(_ request: MemoryPageRequest) async throws -> MemoryPage {
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: request.scope)
            .filter { memory in
                if memory.reviewStatus == .rejected { return false }
                return request.includeQuarantined || memory.reviewStatus == .approved
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
                return lhs.updatedAt > rhs.updatedAt
            }
        let pageSize = max(1, request.pageSize)
        let page = max(1, request.page)
        let start = max(0, (page - 1) * pageSize)
        return MemoryPage(
            items: Array(records.dropFirst(start).prefix(pageSize)),
            page: page,
            pageSize: pageSize,
            total: records.count
        )
    }

    func searchChatMemoryAuthorityRecords(_ query: MemoryQuery) async throws -> [Memory] {
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: query.scope)
            .filter { $0.reviewStatus != .rejected }
        var scored: [(memory: Memory, score: Double)] = []
        scored.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            let body = try await openChatMemoryBody(id: memory.id) ?? ""
            scored.append((memory, Self.memoryTextScore(query: query.text, text: body) + memory.confidence))
        }
        return scored.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }
        .prefix(max(1, query.limit))
        .map(\.memory)
    }

    func recallChatMemorySnippets(_ request: MemoryRecallRequest) async throws -> [MemorySnippet] {
        guard request.tokenBudget > 0, request.limit > 0 else { return [] }
        let records = try await fetchActiveChatMemoryAuthorityRecords(scope: request.scope)
            .filter { $0.reviewStatus == .approved && $0.validTo == nil }
        var ranked: [(memory: Memory, text: String, tokenEstimate: Int, score: Double)] = []
        ranked.reserveCapacity(records.count)
        for memory in records {
            guard try await memoryHasTombstonedSource(id: memory.id) == false else { continue }
            guard let body = try await openChatMemoryBody(id: memory.id), body.isEmpty == false else {
                continue
            }
            let tokenEstimate = Self.memoryTokenEstimate(body)
            let score = Self.memoryTextScore(query: request.query, text: body) + memory.confidence
            ranked.append((memory, body, tokenEstimate, score))
        }

        var spent = 0
        var snippets: [MemorySnippet] = []
        for item in ranked.sorted(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }) {
            guard snippets.count < request.limit else { break }
            guard item.tokenEstimate <= request.tokenBudget - spent else { continue }
            spent += item.tokenEstimate
            snippets.append(
                MemorySnippet(
                    memoryID: item.memory.id,
                    text: item.text,
                    kind: item.memory.kind,
                    confidence: item.memory.confidence,
                    citations: item.memory.citations,
                    trustTier: .untrusted,
                    tokenCountEstimate: item.tokenEstimate
                )
            )
        }
        return snippets
    }

    func updateChatMemoryAuthorityRecord(id: MemoryID, patch: MemoryPatch, now: Date = Date()) async throws -> Bool {
        guard let existing = try await fetchChatMemoryAuthorityRecord(id: id) else { return false }
        let patchedBody = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let patchedBody {
            guard patchedBody.isEmpty == false else { throw ChatMemoryAuthorityError.emptyBody }
            let secretLabels = Self.memoryGateFindingIDs(in: patchedBody)
            if secretLabels.isEmpty == false {
                try await appendMemoryAuditEvent(
                    action: "memory.secret_rejected",
                    projectID: Self.memoryStorageProjectID(for: existing.scope),
                    subjectID: id,
                    labels: [
                        "memory_id": id,
                        "source_kind": MemorySourceKind.chat.rawValue,
                        "labels": secretLabels.joined(separator: ",")
                    ],
                    now: now
                )
                throw ChatMemoryAuthorityError.secretRejected(labels: secretLabels)
            }
        }

        let snapshotSlug = Self.memorySnapshotSlug(id)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(MemorySourceKind.chat.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if let patchedBody {
                let bodyHash = Self.sha256Hex(patchedBody)
                let bodyRef = Self.memorySnapshotRef(snapshotSlug)
                let snapshotJSON = try Self.memoryBodySnapshotJSON(
                    memoryID: id,
                    body: patchedBody,
                    bodyHash: bodyHash,
                    citations: existing.citations,
                    createdAt: existing.createdAt
                )
                try db.execute(sql: "DELETE FROM project_memory_snapshots WHERE projectSlug = ?", arguments: [snapshotSlug])
                try db.execute(
                    sql: """
                    INSERT INTO memory_body_snapshots (
                        id, memory_id, body_ref, snapshot_json, body_hash, source_kind, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        body_ref = excluded.body_ref,
                        snapshot_json = excluded.snapshot_json,
                        body_hash = excluded.body_hash,
                        source_kind = excluded.source_kind,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        snapshotSlug,
                        id,
                        bodyRef,
                        snapshotJSON,
                        bodyHash,
                        MemorySourceKind.chat.rawValue,
                        existing.createdAt,
                        now
                    ]
                )
            }
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET kind = COALESCE(?, kind),
                    confidence = COALESCE(?, confidence),
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [
                    patch.kind?.rawValue,
                    patch.confidence,
                    now,
                    id,
                    MemorySourceKind.chat.rawValue
                ]
            )
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.update",
                projectID: Self.memoryStorageProjectID(for: existing.scope),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        return true
    }

    func setChatMemoryReviewStatus(id: MemoryID, status: MemoryReviewStatus, now: Date = Date()) async throws -> Bool {
        guard let existing = try await fetchChatMemoryAuthorityRecord(id: id) else { return false }
        let auditLabels = [
            "memory_id:\(id)",
            "review_status:\(status.rawValue)",
            "source_kind:\(MemorySourceKind.chat.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if existing.reviewStatus == .approved,
               status != .approved,
               existing.scope.userID != nil {
                try Self.insertMemoryFactTombstone(
                    db: db,
                    memory: existing,
                    reason: "review_status_\(status.rawValue)",
                    now: now
                )
            }
            if existing.reviewStatus != .approved,
               status == .approved,
               existing.scope.userID != nil {
                try db.execute(
                    sql: """
                    UPDATE memory_fact_tombstones
                    SET replicated_at = ?
                    WHERE memory_id = ?
                      AND replicated_at IS NULL
                    """,
                    arguments: [now, id]
                )
            }
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET review_status = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [status.rawValue, now, id, MemorySourceKind.chat.rawValue]
            )
            try Self.insertMemoryAuditEvent(
                db: db,
                action: status == .approved ? "memory.approve" : "memory.reject",
                projectID: Self.memoryStorageProjectID(for: existing.scope),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        return true
    }

    func deleteChatMemoryAuthorityRecord(id: MemoryID, now: Date = Date()) async throws -> Bool {
        guard let existing = try await fetchChatMemoryAuthorityRecord(id: id) else { return false }
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(MemorySourceKind.chat.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            if existing.reviewStatus == .approved,
               existing.scope.userID != nil {
                try Self.insertMemoryFactTombstone(
                    db: db,
                    memory: existing,
                    reason: "user_delete",
                    now: now
                )
            }
            try db.execute(sql: "DELETE FROM memory_embedding_refs WHERE memory_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM memory_provenance WHERE memory_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM agent_memories WHERE id = ? AND source_kind = ?", arguments: [id, MemorySourceKind.chat.rawValue])
            try db.execute(sql: "DELETE FROM project_memory_snapshots WHERE projectSlug = ?", arguments: [snapshotSlug])
            try db.execute(sql: "DELETE FROM memory_body_snapshots WHERE memory_id = ?", arguments: [id])
            try Self.insertMemoryAuditEvent(
                db: db,
                action: "memory.delete",
                projectID: Self.memoryStorageProjectID(for: existing.scope),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
        }
        return true
    }

    func deleteChatMemoryAuthorityRecords(scope: MemoryScope, now: Date = Date()) async throws -> Int {
        let ids = try await chatMemoryAuthorityDeletionIDs(scope: scope)
        var records: [Memory] = []
        for id in ids {
            if let record = try await fetchChatMemoryAuthorityRecord(id: id) {
                records.append(record)
            }
        }
        var deleted = 0
        for record in records where try await deleteChatMemoryAuthorityRecord(id: record.id, now: now) {
            deleted += 1
        }
        return deleted
    }

    private func fetchAllChatMemoryAuthorityRecordsForDeletion(scope: MemoryScope) async throws -> [Memory] {
        try await dbQueue.read { db in
            var predicates = ["source_kind = ?", "project_id = ?"]
            var arguments: [any DatabaseValueConvertible] = [
                MemorySourceKind.chat.rawValue,
                Self.memoryStorageProjectID(for: scope)
            ]
            Self.appendScopePredicates(scope, to: &predicates, arguments: &arguments)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE \(predicates.joined(separator: " AND "))
                ORDER BY created_at ASC, id ASC
                """,
                arguments: StatementArguments(arguments)
            )
            return try rows.compactMap { row in
                guard let id: String = row["id"] else { return nil }
                let citationRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT *
                    FROM memory_provenance
                    WHERE memory_id = ?
                    ORDER BY authored_at ASC, occurrence ASC, id ASC
                    """,
                    arguments: [id]
                )
                return Self.memory(from: row, citations: citationRows.compactMap(Self.memoryCitation(from:)))
            }
        }
    }

    func listChatMemoryEntities() async throws -> [MemoryEntity] {
        let records = try await fetchActiveChatMemoryAuthorityRecords()
            .filter { $0.reviewStatus != .rejected }
        var counts: [String: Int] = [:]
        for memory in records {
            if let value = memory.scope.userID { counts["user_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.agentID { counts["agent_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.runID { counts["run_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.appID { counts["app_id:\(value)", default: 0] += 1 }
            if let value = memory.scope.projectID { counts["project_id:\(value)", default: 0] += 1 }
        }
        return counts.map { key, count in
            let parts = key.split(separator: ":", maxSplits: 1)
            return MemoryEntity(
                keyName: String(parts.first ?? ""),
                value: String(parts.last ?? ""),
                count: count
            )
        }
        .sorted { lhs, rhs in
            if lhs.keyName == rhs.keyName { return lhs.value < rhs.value }
            return lhs.keyName < rhs.keyName
        }
    }

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

    private struct MemoryBodySnapshot: Codable {
        let schemaVersion: Int
        let memoryID: MemoryID
        let sourceKind: MemorySourceKind
        let bodyHash: String
        let body: String
        let citations: [MemoryCitation]
        let createdAt: Date
    }

    private static func memorySnapshotSlug(_ id: MemoryID) -> String {
        "memory-\(id)"
    }

    private static func memorySnapshotRef(_ slug: String) -> String {
        "memory_body_snapshots:\(slug)"
    }

    private static func memoryStorageProjectID(for scope: MemoryScope) -> String {
        scope.projectID ?? "chat:\(scope.userID ?? scope.appID ?? "unscoped")"
    }

    /// Internal shim exposed for `MemoryExtractionWorker` (which lives outside the extension
    /// and cannot access the private `memoryStorageProjectID`). Same logic, different name.
    static func memoryExtractionProjectID(for scope: MemoryScope) -> String {
        memoryStorageProjectID(for: scope)
    }

    /// Internal shim for reset/forget helpers split into another file.
    static func appendMemoryExtractionScopePredicates(
        _ scope: MemoryScope,
        tableAlias: String = "",
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        appendScopePredicates(scope, tableAlias: tableAlias, to: &predicates, arguments: &arguments)
    }

    private static func memoryBodySnapshotJSON(
        memoryID: MemoryID,
        body: String,
        bodyHash: String,
        citations: [MemoryCitation],
        createdAt: Date
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = MemoryBodySnapshot(
            schemaVersion: 1,
            memoryID: memoryID,
            sourceKind: .chat,
            bodyHash: bodyHash,
            body: body,
            citations: citations,
            createdAt: createdAt
        )
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ChatMemory", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Chat memory body snapshot could not be encoded as UTF-8."
            ])
        }
        return json
    }

    private static func memoryProvenanceID(memoryID: MemoryID, citationID: String) -> String {
        "\(memoryID)#\(citationID)"
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func memoryTokenEstimate(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }

    private static func memoryTextScore(query: String, text: String) -> Double {
        let queryTerms = memoryTerms(query)
        guard queryTerms.isEmpty == false else { return 0 }
        let textTerms = memoryTerms(text)
        guard textTerms.isEmpty == false else { return 0 }
        let overlap = queryTerms.intersection(textTerms).count
        return Double(overlap) / Double(queryTerms.count)
    }

    private static func memoryTerms(_ text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .split { character in
                    character.isLetter == false && character.isNumber == false
                }
                .map(String.init)
        )
    }

    private static func memory(from row: Row, citations: [MemoryCitation]) -> Memory? {
        guard let id: String = row["id"],
              let sourceKindRaw: String = row["source_kind"],
              let sourceKind = MemorySourceKind(rawValue: sourceKindRaw),
              let kindRaw: String = row["kind"],
              let kind = MemoryKind(rawValue: kindRaw),
              let confidence: Double = row["confidence"],
              let bodyRedacted: String = row["body_redacted"],
              let reviewStatusRaw: String = row["review_status"],
              let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
              let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"]),
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updated_at"])
        else {
            return nil
        }
        let projectID: String? = sourceKind == .chat ? nil : row["project_id"]
        let scope = MemoryScope(
            userID: row["user_id"],
            agentID: row["agent_id"],
            runID: row["run_id"],
            appID: row["app_id"],
            projectID: projectID
        )
        return Memory(
            id: id,
            sourceKind: sourceKind,
            kind: kind,
            scope: scope,
            confidence: confidence,
            bodyRedacted: bodyRedacted,
            reviewStatus: reviewStatus,
            citations: citations,
            validFrom: validFrom,
            validTo: OpenBurnBarDatabase.parseDateValue(row["valid_to"]),
            supersededBy: row["superseded_by"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func memoryCitation(from row: Row) -> MemoryCitation? {
        guard let id: String = row["id"],
              let memoryID: String = row["memory_id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let role: String = row["role"],
              let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
              let contentHash: String = row["content_hash"],
              let occurrence: Int = row["occurrence"],
              let crossDeviceHMAC: String = row["xdevice_hmac"],
              let citationStateRaw: String = row["citation_state"],
              let citationState = MemoryCitationState(rawValue: citationStateRaw)
        else {
            return nil
        }
        let publicCitationID = id.hasPrefix("\(memoryID)#") ? String(id.dropFirst(memoryID.count + 1)) : id
        return MemoryCitation(
            id: publicCitationID,
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            role: role,
            authoredAt: authoredAt,
            contentHash: contentHash,
            occurrence: occurrence,
            crossDeviceHMAC: crossDeviceHMAC,
            citationState: citationState
        )
    }

    private static func appendScopePredicates(
        _ scope: MemoryScope,
        tableAlias: String = "",
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        let prefix = tableAlias.isEmpty ? "" : "\(tableAlias)."
        appendNullableScopePredicate(column: "\(prefix)user_id", value: scope.userID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)agent_id", value: scope.agentID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)run_id", value: scope.runID, to: &predicates, arguments: &arguments)
        appendNullableScopePredicate(column: "\(prefix)app_id", value: scope.appID, to: &predicates, arguments: &arguments)
    }

    private static func appendNullableScopePredicate(
        column: String,
        value: String?,
        to predicates: inout [String],
        arguments: inout [any DatabaseValueConvertible]
    ) {
        if let value {
            predicates.append("\(column) = ?")
            arguments.append(value)
        } else {
            predicates.append("\(column) IS NULL")
        }
    }

    private static func chatMemoryDuplicateCandidates(
        db: Database,
        bodyHash: String,
        storageProjectID: String,
        kind: MemoryKind,
        scope: MemoryScope,
        excludingID: MemoryID
    ) throws -> [Row] {
        var predicates = [
            "m.source_kind = ?",
            "m.kind = ?",
            "m.project_id = ?",
            "m.id <> ?",
            "m.valid_to IS NULL",
            "s.body_hash = ?",
            "s.source_kind = ?"
        ]
        var arguments: [any DatabaseValueConvertible] = [
            MemorySourceKind.chat.rawValue,
            kind.rawValue,
            storageProjectID,
            excludingID,
            bodyHash,
            MemorySourceKind.chat.rawValue
        ]
        appendScopePredicates(scope, tableAlias: "m", to: &predicates, arguments: &arguments)

        return try Row.fetchAll(
            db,
            sql: """
            SELECT m.*
            FROM agent_memories m
            JOIN memory_body_snapshots s
              ON s.memory_id = m.id
            WHERE \(predicates.joined(separator: " AND "))
            ORDER BY m.confidence DESC, m.valid_from ASC, m.id ASC
            """,
            arguments: StatementArguments(arguments)
        )
    }

    private static func memoryDedupWinnerID(
        duplicateRows: [Row],
        newID: MemoryID,
        newConfidence: Double,
        newReviewStatus: MemoryReviewStatus,
        newValidFrom: Date
    ) -> MemoryID {
        var candidates: [(id: MemoryID, confidence: Double, reviewStatus: MemoryReviewStatus, validFrom: Date)] = duplicateRows.compactMap { row in
            guard let id: String = row["id"],
                  let confidence: Double = row["confidence"],
                  let reviewStatusRaw: String = row["review_status"],
                  let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
                  let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"])
            else {
                return nil
            }
            return (id, confidence, reviewStatus, validFrom)
        }
        candidates.append((newID, newConfidence, newReviewStatus, newValidFrom))
        return candidates.min { lhs, rhs in
            let lhsRank = memoryReviewDedupRank(lhs.reviewStatus)
            let rhsRank = memoryReviewDedupRank(rhs.reviewStatus)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.validFrom != rhs.validFrom { return lhs.validFrom < rhs.validFrom }
            return lhs.id < rhs.id
        }?.id ?? newID
    }

    private static func memoryReviewDedupRank(_ status: MemoryReviewStatus) -> Int {
        switch status {
        case .approved:
            return 0
        case .quarantined:
            return 1
        case .rejected:
            return 2
        }
    }

    private static func mergeDuplicateChatMemories(
        db: Database,
        duplicateRows: [Row],
        newID: MemoryID,
        winnerID: MemoryID,
        storageProjectID: String,
        now: Date,
        nowString: String
    ) throws {
        guard duplicateRows.isEmpty == false else { return }
        let duplicateIDs: [MemoryID] = duplicateRows.compactMap { row in row["id"] }
        let loserIDs = (duplicateIDs + [newID]).filter { $0 != winnerID }.uniqued()
        guard loserIDs.isEmpty == false else { return }

        for loserID in loserIDs {
            try db.execute(
                sql: """
                UPDATE agent_memories
                SET valid_to = COALESCE(valid_to, ?),
                    superseded_by = ?,
                    updated_at = ?
                WHERE id = ?
                  AND source_kind = ?
                """,
                arguments: [now, winnerID, now, loserID, MemorySourceKind.chat.rawValue]
            )
            try copyMemoryProvenance(db: db, from: loserID, to: winnerID, now: now)
            let auditLabels = [
                "reason:duplicate_body_hash",
                "source_kind:\(MemorySourceKind.chat.rawValue)",
                "winner_id:\(winnerID)"
            ]
            try insertMemoryAuditEvent(
                db: db,
                action: "memory.supersede",
                projectID: storageProjectID,
                subjectID: loserID,
                labels: auditLabels,
                nowString: nowString
            )
        }

        let mergeLabels = [
            "merged_ids:\(loserIDs.joined(separator: ","))",
            "reason:duplicate_body_hash",
            "source_kind:\(MemorySourceKind.chat.rawValue)",
            "winner_id:\(winnerID)"
        ]
        try insertMemoryAuditEvent(
            db: db,
            action: "memory.merge",
            projectID: storageProjectID,
            subjectID: winnerID,
            labels: mergeLabels,
            nowString: nowString
        )
    }

    private static func copyMemoryProvenance(
        db: Database,
        from loserID: MemoryID,
        to winnerID: MemoryID,
        now: Date
    ) throws {
        guard loserID != winnerID else { return }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT *
            FROM memory_provenance
            WHERE memory_id = ?
            ORDER BY authored_at ASC, occurrence ASC, id ASC
            """,
            arguments: [loserID]
        )
        for row in rows {
            guard let sourceID: String = row["id"],
                  let sourceKind: String = row["source_kind"],
                  let threadLogicalID: String = row["thread_logical_id"],
                  let role: String = row["role"],
                  let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
                  let contentHash: String = row["content_hash"],
                  let occurrence: Int = row["occurrence"],
                  let xdeviceHMAC: String = row["xdevice_hmac"],
                  let citationState: String = row["citation_state"]
            else {
                continue
            }
            let messageID: String? = row["message_id"]
            let existing = try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM memory_provenance
                WHERE memory_id = ?
                  AND xdevice_hmac = ?
                  AND occurrence = ?
                """,
                arguments: [winnerID, xdeviceHMAC, occurrence]
            ) ?? 0
            guard existing == 0 else { continue }

            let copyID = "dedup-\(winnerID)-\(sha256Hex("\(loserID)|\(sourceID)"))"
            try db.execute(
                sql: """
                INSERT INTO memory_provenance (
                    id, memory_id, source_kind, thread_logical_id, message_id, role,
                    authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    copyID,
                    winnerID,
                    sourceKind,
                    threadLogicalID,
                    messageID,
                    role,
                    authoredAt,
                    contentHash,
                    occurrence,
                    xdeviceHMAC,
                    citationState,
                    now
                ]
            )
        }
    }

    private func appendMemoryAuditEvent(
        action: String,
        projectID: String,
        subjectID: String,
        labels: [String: String],
        now: Date
    ) async throws {
        let auditLabels = labels.map { "\($0.key):\($0.value)" }.sorted()
        let nowString = Self.iso8601String(now)
        try await dbQueue.write { db in
            try Self.insertMemoryAuditEvent(
                db: db,
                action: action,
                projectID: projectID,
                subjectID: subjectID,
                labels: auditLabels,
                nowString: nowString
            )
        }
    }

    /// Emit a `memory.candidate_dropped` audit event for a G7-rejected extraction candidate.
    ///
    /// Called by `MemoryExtractionWorker` when the G7 gate rejects a candidate. Labels carry
    /// only stable, non-sensitive identifiers — NEVER the secret text or the candidate body.
    /// The `findingLabels` must be the finding IDs/labels (e.g. `openai-api-key`) joined with
    /// commas; the raw candidate text MUST NOT appear in any label.
    func appendMemoryCandidateDroppedAuditEvent(
        projectID: String,
        memoryID: String,
        sourceKind: String,
        findingLabels: String,
        candidateIndex: Int,
        now: Date
    ) async throws {
        try await appendMemoryAuditEvent(
            action: "memory.candidate_dropped",
            projectID: projectID,
            subjectID: memoryID,
            labels: [
                "candidate_index": String(candidateIndex),
                "finding_labels": findingLabels,
                "memory_id": memoryID,
                "source_kind": sourceKind
            ],
            now: now
        )
    }

    private func updateMemoryExtractionJob(
        _ id: String,
        status: MemoryEventStatus,
        lastError: String?,
        notBefore: Date?,
        now: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_extraction_jobs
                SET status = ?, last_error = ?, not_before = ?, lease_expires_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, lastError, notBefore, now, id]
            )
        }
    }

    private static func memoryExtractionJob(from row: Row) -> MemoryExtractionJob? {
        guard let id: String = row["id"],
              let idempotencyKey: String = row["idempotency_key"],
              let threadID: String = row["thread_id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let messageID: String = row["message_id"],
              let promptVersion: String = row["prompt_version"],
              let scopeJSON: String = row["scope_json"],
              let scopeData = scopeJSON.data(using: .utf8),
              let statusRaw: String = row["status"],
              let status = MemoryEventStatus(rawValue: statusRaw),
              let attempts: Int = row["attempts"],
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updated_at"])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        let scope: MemoryScope
        do {
            scope = try decoder.decode(MemoryScope.self, from: scopeData)
        } catch {
            return nil
        }
        return MemoryExtractionJob(
            id: id,
            idempotencyKey: idempotencyKey,
            threadID: threadID,
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            promptVersion: promptVersion,
            scope: scope,
            status: status,
            attempts: attempts,
            lastError: row["last_error"],
            notBefore: OpenBurnBarDatabase.parseDateValue(row["not_before"]),
            leaseExpiresAt: OpenBurnBarDatabase.parseDateValue(row["lease_expires_at"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func vectorNorm(_ vector: [Float]) -> Double {
        vector.reduce(0.0) { partial, value in
            partial + Double(value * value)
        }.squareRoot()
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

actor MemoryExtractionAdmissionController {
    private let maxConcurrent: Int
    private var inFlight = 0

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func tryEnter() -> Bool {
        guard inFlight < maxConcurrent else { return false }
        inFlight += 1
        return true
    }

    func leave() {
        inFlight = max(0, inFlight - 1)
    }
}

actor MemoryExtractionWorker {
    typealias Extractor = @Sendable (ControlPlaneStore.MemoryExtractionJob) async throws -> [MemoryAddRequest]

    /// Tri-state result of a single drain attempt. The driving pump
    /// (`MemoryExtractionEngine`) MUST loop on this, not on a `Bool`: a `Bool`
    /// conflates "claimed a job that then failed" with "nothing claimable", and a
    /// loop guarded on `drained == true` would halt the whole backlog on the first
    /// failing job (`drainClaimedJob` catches the extractor error, marks the job
    /// failed, and returns without re-throwing — PR-D2 must-fix #1).
    enum DrainOutcome: Equatable, Sendable {
        /// A job was claimed and processed to a terminal commit (succeeded).
        case drained
        /// A job was claimed but its processing failed; it is marked `failed` with a
        /// retry backoff. The pump should KEEP DRAINING (a later good job may sit
        /// behind it) but record the failure via `memoryExtractionJobStatus`.
        case claimedButFailed
        /// Nothing to do: the kill switch is off, admission was busy, or no job is
        /// currently claimable. The pump stops on this (idle).
        case idle
    }

    private let store: ControlPlaneStore
    private let admission: MemoryExtractionAdmissionController
    private let extractor: Extractor
    private let authorityWritesEnabled: @Sendable () -> Bool
    private let nowProvider: @Sendable () -> Date

    /// Number of candidates dropped by the G7 gate during the most recent `drainNext()` call.
    /// Reset to 0 at the start of each drain. The driving engine reads this after each tick to
    /// accumulate the pump-level `dropped` counter in `MemoryExtractionPumpReport`.
    private(set) var lastDroppedCount: Int = 0

    init(
        store: ControlPlaneStore,
        admission: MemoryExtractionAdmissionController = MemoryExtractionAdmissionController(),
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        authorityWritesEnabled: @escaping @Sendable () -> Bool = {
            ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
        },
        extractor: @escaping Extractor
    ) {
        self.store = store
        self.admission = admission
        self.nowProvider = nowProvider
        self.authorityWritesEnabled = authorityWritesEnabled
        self.extractor = extractor
    }

    /// Back-compat `Bool` adapter (kept so existing single-drain call sites and tests
    /// read unchanged): `true` iff a job was claimed and committed successfully.
    /// `false` for both `claimedButFailed` and `idle`. New drivers MUST prefer
    /// `drainNext()` so they can keep draining past a failing job.
    func drainOne() async throws -> Bool {
        try await drainNext() == .drained
    }

    /// Claim and process at most one job, surfacing the tri-state the pump needs.
    func drainNext() async throws -> DrainOutcome {
        guard await admission.tryEnter() else { return .idle }
        do {
            let outcome = try await drainClaimedJob()
            await admission.leave()
            return outcome
        } catch {
            await admission.leave()
            throw error
        }
    }

    private func drainClaimedJob() async throws -> DrainOutcome {
        // Authority gate checked PRE-CLAIM so a disabled fleet (or a not-yet-gone-live
        // subsystem) never claims (and never burns an attempt on) a job. Re-checked
        // per-record below via the `enabled:` argument. `authorityWritesEnabled` is the
        // AND of the engine's live `Sendable` kill-switch atomic AND the human-owned
        // go-live flag (PR-D2 must-fix #2/#4 + PR-D FIX #1): the kill switch is
        // re-established at THIS worker boundary because the engine-driven path bypasses
        // the controller's `memoryServiceForExtraction == nil` gate, and the default-false
        // go-live flag keeps durable writes blocked even when extraction is enabled.
        guard authorityWritesEnabled() else { return .idle }
        let now = nowProvider()
        guard let job = try await store.claimNextMemoryExtractionJob(now: now) else { return .idle }
        lastDroppedCount = 0
        do {
            // The extractor performs the LLM round-trip. The worker actor holds NO
            // database write transaction across this call (PR-D1 must-fix:
            // lock-not-held-across-LLM) — the LLM latency is fully outside any DB lock.
            let requests = try await extractor(job)
            let projectID = ControlPlaneStore.memoryExtractionProjectID(for: job.scope)

            for (index, request) in requests.enumerated() {
                // G7 candidate-DROP gate (PR-D1 must-fix #4): drop a secret/PII-bearing
                // candidate instead of failing the whole batch, so one poisoned
                // candidate cannot starve the rest. `.reject` (fail-closed) is also what
                // an unavailable corpus returns, so a missing corpus drops everything.
                let verdict = MemorySecretPIIGate.evaluate(request.text, policy: .reject)
                guard case .allow = verdict else {
                    lastDroppedCount += 1
                    // Emit a non-sensitive audit event: finding IDs/labels only,
                    // NEVER the secret text or the candidate body.
                    let findingLabels = verdict.findings.map(\.id).joined(separator: ",")
                    let memoryID = Self.memoryID(for: job, index: index)
                    try await store.appendMemoryCandidateDroppedAuditEvent(
                        projectID: projectID,
                        memoryID: memoryID,
                        sourceKind: MemorySourceKind.chat.rawValue,
                        findingLabels: findingLabels,
                        candidateIndex: index,
                        now: now
                    )
                    continue
                }

                let memoryID = Self.memoryID(for: job, index: index)
                // Fast-path idempotency check. The durable write itself is idempotent
                // (`agent_memories` INSERT is `ON CONFLICT(id) DO NOTHING`), so a race
                // past this check is a no-op, not a crash; this only avoids redundant
                // work on the common retry path.
                if try await store.fetchChatMemoryAuthorityRecord(id: memoryID) != nil {
                    continue
                }

                // Worker is the SOLE provenance authority (PR-D1 must-fix #1/#3): rebuild
                // every citation from the fetched source message, ignoring whatever the
                // extractor/model supplied. Unresolvable citations are dropped, never
                // fabricated.
                let authoritativeCitations = try await recomputeProvenance(
                    for: request,
                    job: job
                )
                guard authoritativeCitations.isEmpty == false else {
                    continue
                }

                var quarantined = request
                quarantined.scope = job.scope
                quarantined.reviewStatus = .quarantined
                quarantined.citations = authoritativeCitations
                _ = try await store.addChatMemoryAuthorityRecord(
                    quarantined,
                    id: memoryID,
                    now: nowProvider(),
                    enabled: authorityWritesEnabled()
                )
            }
            try await store.markMemoryExtractionJobSucceeded(job.id, now: nowProvider())
            return .drained
        } catch {
            try await store.markMemoryExtractionJobFailed(
                job.id,
                error: Self.failureLabel(for: error),
                retryAfter: 60,
                now: nowProvider()
            )
            // Job failed but the pump must KEEP DRAINING (do NOT re-throw here): a
            // good job may sit behind this one. The engine reads the terminal status
            // and records the failure (PR-D2 must-fix #1/#3).
            return .claimedButFailed
        }
    }

    /// Recompute authoritative provenance for `request` from the job + the fetched
    /// source message. The model's `citation.messageID` is treated as a LOOKUP KEY
    /// ONLY (PR-D1 must-fix #1): a citation whose message id is not a real user/assistant
    /// turn on the job's thread is DROPPED, never fabricated. `contentHash` is the
    /// SHA-256 of the cited SOURCE MESSAGE body (must-fix #3) — the thing the citation
    /// points at — not the extracted memory body. `crossDeviceHMAC` is a v1 non-crypto,
    /// content-derived provenance tag (must-fix #2): memory stays LOCAL-ONLY until a real
    /// HMAC key lifecycle exists, so this tag is never an authenticated cross-device
    /// identity and never leaves the device.
    private func recomputeProvenance(
        for request: MemoryAddRequest,
        job: ControlPlaneStore.MemoryExtractionJob
    ) async throws -> [MemoryCitation] {
        // Resolve the distinct claimed message ids the model proposed.
        var seen = Set<String>()
        var claimedIDs: [String] = []
        for citation in request.citations {
            guard let messageID = citation.messageID, messageID.isEmpty == false else { continue }
            if seen.insert(messageID).inserted {
                claimedIDs.append(messageID)
            }
        }

        var citations: [MemoryCitation] = []
        for (occurrence, messageID) in claimedIDs.enumerated() {
            guard let source = try await store.fetchChatProvenanceSourceMessage(
                threadID: job.threadID,
                messageID: messageID
            ) else {
                // Lookup miss: the model named a message that is not a citable turn on
                // this thread. Drop the citation (never fabricate provenance).
                continue
            }

            let contentHash = Self.provenanceContentHash(source.body)
            let crossDeviceHMAC = Self.provenanceLocalTag(
                threadLogicalID: job.threadLogicalID,
                messageID: source.id,
                occurrence: occurrence,
                contentHash: contentHash
            )
            citations.append(
                MemoryCitation(
                    id: "\(source.id)#\(occurrence)",
                    threadLogicalID: job.threadLogicalID,
                    messageID: source.id,
                    role: source.role,
                    authoredAt: source.authoredAt,
                    contentHash: contentHash,
                    occurrence: occurrence,
                    crossDeviceHMAC: crossDeviceHMAC,
                    citationState: .live
                )
            )
        }
        return citations
    }

    private static func failureLabel(for error: Error) -> String {
        if case .secretRejected(let labels) = error as? ControlPlaneStore.ChatMemoryAuthorityError {
            return "secret_rejected:\(labels.joined(separator: ","))"
        }
        return String(reflecting: type(of: error))
    }

    private static func memoryID(for job: ControlPlaneStore.MemoryExtractionJob, index: Int) -> MemoryID {
        "memory-\(job.id)-\(index)"
    }

    /// SHA-256 hex of the cited source message body. The citation binds to the source
    /// text, so a later edit/deletion of that message is detectable.
    static func provenanceContentHash(_ sourceBody: String) -> String {
        let bytes = SHA256.hash(data: Data(sourceBody.utf8))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// v1 non-crypto provenance tag. Content-derived (stable for identical source
    /// content) but explicitly NOT an authenticated HMAC: it is NOT derived from the
    /// idempotency key (that key is promptVersion-salted and is the wrong envelope) nor
    /// from any secret key. The `v1-local:` prefix marks it as the placeholder that
    /// gates cloud-sync — memory stays local-only until a real key lifecycle replaces
    /// this (integrated build plan §5.2).
    static func provenanceLocalTag(
        threadLogicalID: String,
        messageID: String,
        occurrence: Int,
        contentHash: String
    ) -> String {
        let material = "\(threadLogicalID)|\(messageID)|\(occurrence)|\(contentHash)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "v1-local:\(digest)"
    }
}

// MARK: - Extractor read seam

// `ControlPlaneStore` already exposes `fetchChatTranscriptForExtraction(threadID:)`
// against the shared db queue, so satisfying the extractor's transcript seam is a
// marker conformance. The extractor and the worker therefore read the transcript from
// the SAME store handle the worker uses to persist, which is what lets the worker be
// the sole provenance authority without a second store.
extension ControlPlaneStore: ChatExtractionTranscriptReading {}
