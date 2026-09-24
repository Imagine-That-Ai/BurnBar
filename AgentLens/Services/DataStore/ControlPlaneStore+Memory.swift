import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - ControlPlaneStore chat-memory subsystem
//
// This file was split out of ControlPlaneStore.swift to keep both files under the
// 2000-line debt ceiling. It owns the chat-memory authority CRUD, recall/search/page,
// the extraction-job queue, embedding refs, the chat-memory private helpers and nested
// types, the Array.uniqued() helper, and the extraction worker/admission actors.
//
// Shared, single-sourced helpers (iso8601String, auditLabelsJSON) intentionally
// remain in ControlPlaneStore.swift because they are also called by
// ControlPlaneStore+MemoryForget.swift and the 2.1c-iii authority lane;
// Swift `internal` access keeps them reachable across the split. Likewise,
// this file calls back into +MemoryForget's `memoryHasTombstonedSource`
// (internal). Audit appends and tombstone inserts commit through the writer
// seam (`ControlPlaneStore+MemoryAuthorityLane.swift`); the daemon assigns
// the chain fields.

extension ControlPlaneStore {
    // MARK: - Chat Memory Authority (flagged off)

    enum ChatMemoryAuthorityError: Error, LocalizedError, Equatable {
        case disabled
        case emptyBody
        case secretRejected(labels: [String])
        case agentForgetRequiresDaemon
        case conflictRetryExhausted
        case authorityResultMismatch

        var errorDescription: String? {
            switch self {
            case .disabled:
                "Chat memory authority writes are disabled."
            case .emptyBody:
                "Chat memory body is empty."
            case .secretRejected(let labels):
                "Chat memory body was rejected by the secret scanner: \(labels.joined(separator: ", "))."
            case .agentForgetRequiresDaemon:
                "The daemon could not hard-forget this memory, so nothing was deleted."
            case .conflictRetryExhausted:
                "The memory changed under this write too many times; nothing was applied."
            case .authorityResultMismatch:
                "The daemon's authority response did not match the request; nothing was applied."
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

        // Wave 2.1c-iii: daemon-owned tables — the decision half (dedup
        // election, merge plan) runs over local pre-reads and the finalized
        // write set commits through the writer seam. The daemon applies it
        // atomically and assigns only the audit chain fields.
        let duplicates = try await memoryAuthorityDuplicates(
            bodyHash: bodyHash,
            storageProjectID: storageProjectID,
            kind: request.kind,
            scope: request.scope,
            excludingID: id,
            sourceKinds: dedupSourceKinds
        )
        let winnerID = Self.memoryDedupWinnerID(
            candidates: duplicates.candidates,
            newID: id,
            newConfidence: request.confidence,
            newReviewStatus: request.reviewStatus,
            newValidFrom: now
        )
        let newSupersededBy = winnerID == id ? nil : winnerID
        let newValidTo = newSupersededBy == nil ? nil : now
        let snapshot = Self.memoryAuthoritySnapshotRow(
            id: snapshotSlug,
            memoryID: id,
            bodyRef: bodyRef,
            snapshotJSON: snapshotJSON,
            bodyHash: bodyHash,
            sourceKind: sourceKind,
            createdAt: now,
            updatedAt: now
        )
        // G1 at-rest: BOTH `body_ref` and `body_redacted` store the SEALED REFERENCE
        // (`bodyRef` = "memory_body_snapshots:<slug>"), never plaintext and never a
        // redacted body — the column name `body_redacted` is legacy and is a misnomer
        // here. The only plaintext fact body lives in `memory_body_snapshots.snapshot_json`
        // inside the SQLCipher-encrypted database, opened transiently via `openChatMemoryBody`.
        let memory = Self.memoryAuthorityMemoryRow(
            id: id,
            request: request,
            sourceKind: sourceKind,
            storageProjectID: storageProjectID,
            bodyRef: bodyRef,
            now: now,
            validTo: newValidTo,
            supersededBy: newSupersededBy
        )
        let provenance = citations.map { citation in
            Self.memoryAuthorityProvenanceRow(
                id: Self.memoryProvenanceID(memoryID: id, citationID: citation.id),
                memoryID: id,
                sourceKind: Self.memoryProvenanceSourceKind(for: sourceKind),
                citation: citation,
                createdAt: now
            )
        }
        let addAudit = try Self.memoryAuthorityAuditEvent(
            action: "memory.add",
            projectID: storageProjectID,
            subjectID: id,
            labels: auditLabels,
            nowString: nowString
        )
        let merge = try await memoryAuthorityMergePlan(
            duplicateIDs: duplicates.ids,
            newID: id,
            newCitations: citations,
            newSourceKind: sourceKind,
            winnerID: winnerID,
            storageProjectID: storageProjectID,
            sourceKinds: dedupSourceKinds,
            now: now,
            nowString: nowString
        )
        _ = try await commitMemoryAuthorityOperationsChecked([
            .remember(BurnBarMemoryAuthorityRemember(
                snapshot: snapshot,
                memory: memory,
                provenance: provenance,
                audits: [addAudit],
                merge: merge
            ))
        ])

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
            validTo: newValidTo,
            supersededBy: newSupersededBy,
            createdAt: now,
            updatedAt: now
        )
    }

}
