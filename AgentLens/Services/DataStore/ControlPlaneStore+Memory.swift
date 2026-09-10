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
        try await addMemoryAuthorityRecord(
            request,
            id: id,
            sourceKind: .chat,
            now: now,
            enabled: enabled
        )
    }

    /// Single choke point for app-owned authority writes: G7 secret/PII gate,
    /// sealed snapshot, provenance, audit, and exact-hash dedup all happen here
    /// for every `sourceKind`. Chat callers use the `addChatMemoryAuthorityRecord`
    /// wrapper above and are byte-identical to the pre-parameterization behavior;
    /// usage callers pass their own kind, gate-derived `enabled`, and an
    /// optional extraction `context` sentence for the sealed snapshot.
    func addMemoryAuthorityRecord(
        _ request: MemoryAddRequest,
        id: MemoryID = UUID().uuidString,
        sourceKind: MemorySourceKind = .chat,
        context: String? = nil,
        now: Date = Date(),
        enabled: Bool = ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
    ) async throws -> Memory {
        guard enabled else { throw ChatMemoryAuthorityError.disabled }
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw ChatMemoryAuthorityError.emptyBody }

        let partition = MemoryStoragePartition(sourceKind)
        // Usage kinds dedup against each other (shared partition); chat and code
        // dedup only against themselves.
        let dedupSourceKinds: Set<MemorySourceKind> =
            partition == .usage ? MemorySourceKind.usageKinds : [sourceKind]

        // G7 covers every string sealed into `snapshot_json` — the body and the
        // usage extraction's context sentence. Chat passes no context, so its
        // labels stay byte-identical.
        var secretLabels = Self.memoryGateFindingIDs(in: body)
        if let context {
            for label in Self.memoryGateFindingIDs(in: context) where secretLabels.contains(label) == false {
                secretLabels.append(label)
            }
        }
        if secretLabels.isEmpty == false {
            try await appendMemoryAuditEvent(
                action: "memory.secret_rejected",
                projectID: Self.memoryStorageProjectID(for: request.scope, partition: partition),
                subjectID: id,
                labels: [
                    "memory_id": id,
                    "source_kind": sourceKind.rawValue,
                    "labels": secretLabels.joined(separator: ",")
                ],
                now: now
            )
            throw ChatMemoryAuthorityError.secretRejected(labels: secretLabels)
        }

        let bodyHash = Self.sha256Hex(body)
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let bodyRef = Self.memorySnapshotRef(snapshotSlug)
        let storageProjectID = Self.memoryStorageProjectID(for: request.scope, partition: partition)
        let nowString = Self.iso8601String(now)
        let citations = request.citations
        let snapshotJSON = try Self.memoryBodySnapshotJSON(
            memoryID: id,
            body: body,
            bodyHash: bodyHash,
            citations: citations,
            createdAt: now,
            sourceKind: sourceKind,
            context: context
        )
        let auditLabels = [
            "body_ref:\(bodyRef)",
            "memory_id:\(id)",
            "review_status:\(request.reviewStatus.rawValue)",
            "source_kind:\(sourceKind.rawValue)"
        ].sorted()

        let dedupState = try await dbQueue.write { db -> (validTo: Date?, supersededBy: MemoryID?) in
            let duplicateRows = try Self.memoryDuplicateCandidates(
                db: db,
                bodyHash: bodyHash,
                storageProjectID: storageProjectID,
                kind: request.kind,
                scope: request.scope,
                excludingID: id,
                sourceKinds: dedupSourceKinds
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
                    sourceKind.rawValue,
                    now,
                    now
                ]
            )
            // G1 at-rest: BOTH `body_ref` and `body_redacted` store the SEALED REFERENCE
            // (`bodyRef` = "memory_body_snapshots:<slug>"), never plaintext and never a
            // redacted body — the column name `body_redacted` is legacy and is a misnomer
            // here. The only plaintext fact body lives in `memory_body_snapshots.snapshot_json`
            // inside the SQLCipher-encrypted database, opened transiently via `openChatMemoryBody`.
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
                    // Legacy v50 `scope` text column: chat rows shipped as the
                    // literal "chat"; usage rows carry their raw source kind.
                    sourceKind == .chat ? "chat" : sourceKind.rawValue,
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
                    sourceKind.rawValue,
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
                        Self.memoryProvenanceSourceKind(for: sourceKind).rawValue,
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
            try Self.mergeDuplicateMemories(
                db: db,
                duplicateRows: duplicateRows,
                newID: id,
                winnerID: winnerID,
                storageProjectID: storageProjectID,
                sourceKinds: dedupSourceKinds,
                now: now,
                nowString: nowString
            )
            return (newValidTo, newSupersededBy)
        }

        return Memory(
            id: id,
            sourceKind: sourceKind,
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

}
