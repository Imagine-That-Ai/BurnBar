import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarKernel

extension ControlPlaneStore {
    /// How a reseal treats the sealed snapshot's A-MEM `context` sentence.
    ///
    /// A body edit must never touch it *implicitly*: resealing without carrying
    /// the stored sentence forward destroys it and downgrades a usage snapshot
    /// from `schemaVersion` 2 back to 1. `MemoryPatch` deliberately does not
    /// carry this — the `MemoryServing` contract is frozen and cross-track
    /// coordinated, so the knob lives on the store method instead.
    enum MemoryContextEdit: Sendable, Equatable {
        /// Carry the stored context sentence forward unchanged. The default,
        /// and the only correct behavior for a body-only edit.
        case preserve
        /// Replace the context sentence deliberately. `nil` (or whitespace)
        /// clears it, taking the snapshot back to `schemaVersion` 1.
        case replace(String?)
    }

    func updateChatMemoryAuthorityRecord(id: MemoryID, patch: MemoryPatch, now: Date = Date()) async throws -> Bool {
        try await updateMemoryAuthorityRecord(id: id, patch: patch, sourceKinds: [.chat], now: now)
    }

    func updateMemoryAuthorityRecord(
        id: MemoryID,
        patch: MemoryPatch,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        context: MemoryContextEdit = .preserve,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let patchedBody = patch.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let patchedBody, patchedBody.isEmpty {
            throw ChatMemoryAuthorityError.emptyBody
        }
        // `let`, not `var` — the write closure below captures it, and Swift 6
        // rejects a captured `var` in concurrently-executing code.
        let replacementContext: String? = {
            guard case .replace(let value) = context else { return nil }
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == true ? nil : trimmed
        }()
        // G7 covers every string this call would seal into `snapshot_json` —
        // the new body and, when the caller replaces it, the context sentence.
        // Order-preserving union so a body-only edit reports exactly the labels
        // it reported before this parameter existed.
        var secretLabels: [String] = []
        for text in [patchedBody, replacementContext].compactMap({ $0 }) {
            for label in Self.memoryGateFindingIDs(in: text) where secretLabels.contains(label) == false {
                secretLabels.append(label)
            }
        }
        func rejectSecrets(_ labels: [String]) async throws {
            try await appendMemoryAuditEvent(
                action: "memory.secret_rejected",
                projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                subjectID: id,
                labels: [
                    "memory_id": id,
                    "source_kind": existing.sourceKind.rawValue,
                    "labels": labels.joined(separator: ",")
                ],
                now: now
            )
            throw ChatMemoryAuthorityError.secretRejected(labels: labels)
        }
        if secretLabels.isEmpty == false {
            try await rejectSecrets(secretLabels)
        }

        // A reseal is needed when this call changes sealed content: a new body,
        // or a deliberate context replacement on an unchanged body.
        let resealsSnapshot = patchedBody != nil || context != .preserve
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        // Wave 2.1c-iii: daemon-owned tables — the stored snapshot is
        // pre-read locally and the reseal commits through the writer seam
        // with a compare-and-swap precondition, the cross-process form of
        // the legacy in-transaction snapshot read. A conflicting reseal
        // applies nothing; the loop re-reads and retries, so two racing
        // reseals serialize exactly like the legacy transaction did.
        var attempt = 0
        while true {
            attempt += 1
            let seal = try await memoryAuthoritySnapshotSeal(id: id)
            var reseal: BurnBarMemoryAuthorityReseal?
            // `seal.body` only carries a context-only edit; a body patch
            // reseals even when the snapshot row is somehow absent, exactly as
            // this path did before.
            if resealsSnapshot, let resealBody = patchedBody ?? seal.body {
                let resealContext: String?
                switch context {
                case .preserve: resealContext = seal.context
                case .replace: resealContext = replacementContext
                }
                // A preserved sentence may predate the add-path G7 scan, so it is
                // scanned here; a hit rejects before anything is committed.
                if context == .preserve, let resealContext {
                    let labels = Self.memoryGateFindingIDs(in: resealContext)
                    if labels.isEmpty == false {
                        try await rejectSecrets(labels)
                    }
                }
                let bodyHash = Self.sha256Hex(resealBody)
                let bodyRef = Self.memorySnapshotRef(snapshotSlug)
                let snapshotJSON = try Self.memoryBodySnapshotJSON(
                    memoryID: id,
                    body: resealBody,
                    bodyHash: bodyHash,
                    citations: existing.citations,
                    createdAt: existing.createdAt,
                    sourceKind: existing.sourceKind,
                    context: resealContext
                )
                reseal = BurnBarMemoryAuthorityReseal(
                    expectedBodyHash: seal.bodyHash,
                    expectedUpdatedAtText: seal.updatedAtText,
                    snapshot: Self.memoryAuthoritySnapshotRow(
                        id: snapshotSlug,
                        memoryID: id,
                        bodyRef: bodyRef,
                        snapshotJSON: snapshotJSON,
                        bodyHash: bodyHash,
                        sourceKind: existing.sourceKind,
                        createdAt: existing.createdAt,
                        updatedAt: now
                    )
                )
            }
            let audit = try Self.memoryAuthorityAuditEvent(
                action: "memory.update",
                projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
                subjectID: id,
                labels: auditLabels,
                nowString: nowString
            )
            let operation = BurnBarMemoryAuthorityOperation.updateBody(BurnBarMemoryAuthorityUpdate(
                memoryID: id,
                sourceKind: existing.sourceKind.rawValue,
                kind: patch.kind?.rawValue,
                confidence: patch.confidence,
                updatedAtText: Self.memoryAuthorityTimestampText(now),
                reseal: reseal,
                audit: audit
            ))
            do {
                _ = try await commitMemoryAuthorityOperations([operation])
                return true
            } catch OpenBurnBarDaemonManagerError.rpcConflict {
                guard attempt < Self.memoryAuthorityMaxResealAttempts else {
                    throw ChatMemoryAuthorityError.conflictRetryExhausted
                }
            }
        }
    }

    func setChatMemoryReviewStatus(id: MemoryID, status: MemoryReviewStatus, now: Date = Date()) async throws -> Bool {
        try await setMemoryReviewStatus(id: id, status: status, sourceKinds: [.chat], now: now)
    }

    func setMemoryReviewStatus(
        id: MemoryID,
        status: MemoryReviewStatus,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let auditLabels = [
            "memory_id:\(id)",
            "review_status:\(status.rawValue)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)
        // Wave 2.1c-iii: daemon-owned tables — the verdict commits through
        // the writer seam. `updatedAtText` keeps the legacy ISO 8601 stamp
        // (not GRDB text); the daemon binds it verbatim.
        var factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?
        var markFactTombstoneReplicated = false
        var replicatedAtText: String?
        if existing.reviewStatus == .approved,
           status != .approved,
           existing.scope.userID != nil {
            factTombstone = try Self.memoryAuthorityChatFactTombstone(
                memory: existing,
                reason: "review_status_\(status.rawValue)",
                createdAt: now
            )
        }
        if existing.reviewStatus != .approved,
           status == .approved,
           existing.scope.userID != nil {
            markFactTombstoneReplicated = true
            replicatedAtText = Self.memoryAuthorityTimestampText(now)
        }
        let audit = try Self.memoryAuthorityAuditEvent(
            action: status == .approved ? "memory.approve" : "memory.reject",
            projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
            subjectID: id,
            labels: auditLabels,
            nowString: nowString
        )
        _ = try await commitMemoryAuthorityOperationsChecked([
            .setReviewStatus(BurnBarMemoryAuthorityReview(
                memoryID: id,
                sourceKind: existing.sourceKind.rawValue,
                reviewStatus: status.rawValue,
                updatedAtText: nowString,
                factTombstone: factTombstone,
                markFactTombstoneReplicated: markFactTombstoneReplicated,
                replicatedAtText: replicatedAtText,
                audit: audit
            ))
        ])
        // The verdict is durable and audited above; publishing the BODY is the
        // daemon's, so an agent-lane verdict is handed to
        // `daemon.memory.review_status` and the daemon stays the single
        // publisher (I-56). The call never throws and never undoes the verdict:
        // an unreachable daemon leaves the row in the derived
        // pending-publication state the inbox shows and the next launch
        // retries. Chat and usage rows keep their bodies in the app's own
        // snapshot table and have nothing to hand over.
        if existing.sourceKind == .agent {
            // The stamp is the `updated_at` this verdict was committed under:
            // sent as the daemon's precondition so an RPC that lands after a
            // newer verdict is refused instead of resurrecting it (#2565-F4).
            await publishAgentMemoryReview(
                id: id,
                status: status,
                projectID: existing.scope.projectID,
                expectedUpdatedAt: nowString
            )
        }
        return true
    }

    func deleteChatMemoryAuthorityRecord(id: MemoryID, now: Date = Date()) async throws -> Bool {
        try await deleteMemoryAuthorityRecord(id: id, sourceKinds: [.chat], now: now)
    }

    func deleteMemoryAuthorityRecord(
        id: MemoryID,
        sourceKinds: Set<MemorySourceKind>,
        actingAccountUserID: String? = nil,
        now: Date = Date()
    ) async throws -> Bool {
        guard let existing = try await fetchMemoryAuthorityRecord(
            id: id,
            sourceKinds: sourceKinds,
            actingAccountUserID: actingAccountUserID
        ) else { return false }
        let partition = MemoryStoragePartition(existing.sourceKind)
        let auditLabels = [
            "memory_id:\(id)",
            "source_kind:\(existing.sourceKind.rawValue)"
        ]
        let nowString = Self.iso8601String(now)

        // Review #2565-F1: an agent-lane forget goes to the daemon FIRST and
        // fails closed. The daemon owns the mirrored memory's other halves —
        // the quarantined plaintext in `memory_quarantine_bodies`, the
        // published project-memory section, the engine mirror — and it needs
        // this row's `project_id` to find them, so the row must still exist
        // when the call lands. A refused or unreachable daemon throws and
        // every local byte stays: a forget that cannot reach the daemon is
        // not a forget.
        let engineMemoryID: String?
        if existing.sourceKind == .agent {
            let resolvedEngineID = try await self.engineMemoryID(for: id)
            guard let projectID = existing.scope.projectID, projectID.isEmpty == false,
                  let root = try await memoryProjectRecordedRoot(engineProjectID: projectID) else {
                throw ChatMemoryAuthorityError.agentForgetRequiresDaemon
            }
            let response = try await forgetAgentMemory(id, root)
            guard response.localDeleted,
                  response.memoryID == id,
                  response.projectID == projectID else {
                throw ChatMemoryAuthorityError.agentForgetRequiresDaemon
            }
            engineMemoryID = resolvedEngineID
        } else {
            engineMemoryID = nil
        }

        // Wave 2.1c-iii: daemon-owned tables — the cascade commits through
        // the writer seam (tombstones first, then deletes, then the
        // mirrored-row halves, then audit — the legacy order). The
        // agent-lane daemon forget above still runs first and fail-closed.
        var agent: BurnBarMemoryAuthorityAgentDelete?
        var factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?
        // The sealed cloud copy deletes through a fact tombstone — keyed on
        // the engine id for a mirrored row, the same spelling
        // `enqueueTombstonesForUnsyncableAgentMemories` uses, because that
        // is what the cloud document is named. A mirrored row that was ever
        // owned may have been uploaded under ANY earlier verdict, so the
        // tombstone is not gated on `review_status` the way the chat path's
        // is: a rejected or still-parked row can still have a cloud copy.
        if existing.sourceKind == .agent {
            var agentTombstone: BurnBarMemoryAuthorityFactTombstoneRow?
            if let owner = existing.scope.userID ?? actingAccountUserID {
                agentTombstone = Self.memoryAuthorityAgentFactTombstone(
                    memoryID: id,
                    userID: owner,
                    engineMemoryID: engineMemoryID,
                    reason: "user_delete",
                    createdAt: now
                )
            }
            agent = BurnBarMemoryAuthorityAgentDelete(factTombstone: agentTombstone)
        } else if existing.reviewStatus == .approved,
                  existing.scope.userID != nil {
            factTombstone = try Self.memoryAuthorityChatFactTombstone(
                memory: existing,
                reason: "user_delete",
                createdAt: now
            )
        }
        let audit = try Self.memoryAuthorityAuditEvent(
            action: "memory.delete",
            projectID: Self.memoryStorageProjectID(for: existing.scope, partition: partition),
            subjectID: id,
            labels: auditLabels,
            nowString: nowString
        )
        _ = try await commitMemoryAuthorityOperationsChecked([
            .deleteMemory(BurnBarMemoryAuthorityDelete(
                memoryID: id,
                sourceKind: existing.sourceKind.rawValue,
                agent: agent,
                factTombstone: factTombstone,
                // Legacy ISO quirk, verbatim: the sync-body row is BLANKED,
                // not deleted — `engine_memory_id` is the only handle the
                // fact-tombstone drain keeps on the sealed cloud document.
                blankedBodyUpdatedAtText: existing.sourceKind == .agent ? nowString : nil,
                audit: audit
            ))
        ])
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
        // "Reset memory" must leave nothing readable behind. The blind-sync
        // inbox holds an opened plaintext copy of every fact pulled down from
        // the member's other devices, merged or not, and no other delete path
        // touches it — so a reset that skipped it would empty the surface the
        // member can see while leaving the copy they cannot.
        try await purgeAllRemoteMemoryFacts()
        return deleted
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

}
