import Foundation

/// Wave 2.1c-iii: the daemon owns the memory authority tables (ADR-005) and
/// the Mac app routes its memory writes through these contracts instead of
/// touching the tables directly. Reads stay on the app's local connection
/// until the read cutover.
///
/// Lane semantics, read carefully — this lane is an *applier*, not a
/// decision-maker:
/// - The app keeps every byte of authority logic: the G7 secret gate,
///   dedup-winner election, reseal context rules, tombstone policy, and the
///   review/forget preconditions. It finalizes the full write set and ships
///   it here.
/// - The daemon validates shape and bounds, checks preconditions, and stores
///   every value verbatim inside one `BEGIN IMMEDIATE` transaction. It
///   recomputes nothing except the audit chain fields (`seq`, `prev_hash`,
///   `hash`), which cannot be finalized before commit time: they are assigned
///   in-transaction from the live chain head, which is what closes the
///   cross-process fork the dual writers had.
/// - Temporal columns ride as app-finalized TEXT and bind verbatim. The
///   legacy app bindings are a deliberate mix — GRDB `Date` text
///   (`yyyy-MM-dd HH:mm:ss.SSS` UTC) for most stamps, ISO 8601 for the
///   review-status `updated_at` and the agent-body blanking stamp — and the
///   daemon preserves each quirk byte-for-byte so `ORDER BY` and `MAX()`
///   behave identically across the cutover. The daemon validates that every
///   stamp parses as ISO 8601 or GRDB text and falls in 2000–2100, then binds
///   the string untouched.
/// - Audit events ride fully finalized except the chain fields: `labels` and
///   `labelsJSON` are the app's exact encodings (sorted, no dedup — the
///   daemon lane's `Set` dedup is a different behavior and must not leak
///   into this lane), hashed under the shared `openburnbar.memory_audit.v2`
///   payload so export verification is untouched.
/// - Every row effect is idempotent by construction (`ON CONFLICT DO
///   NOTHING`, conditional updates, absolute sets), so a retried mutation
///   converges. The one exception is audit append: a retried mutation appends
///   a second event, which is the truthful trail of two attempts, never
///   silent duplication of one.
///
/// Preconditions (compare-and-swap, not best-effort): the reseal carries the
/// `body_hash`/`updated_at` the app read before finalizing. If the stored
/// snapshot moved, the daemon refuses the whole mutation with `conflict`
/// (`-32004`) and applies nothing; the app re-reads and retries. This is the
/// cross-process form of the in-transaction snapshot read the legacy
/// `updateMemoryAuthorityRecord` used, and of the `#2565-F4`
/// `expectedUpdatedAt` precedent on the agent review lane.
public struct BurnBarMemoryAuthorityApplyRequest: Codable, Equatable, Sendable {
    public let mutationID: String
    public let actor: String
    public let operations: [BurnBarMemoryAuthorityOperation]

    public init(mutationID: String, actor: String, operations: [BurnBarMemoryAuthorityOperation]) {
        self.mutationID = mutationID
        self.actor = actor
        self.operations = operations
    }
}

public struct BurnBarMemoryAuthorityApplyResponse: Codable, Equatable, Sendable {
    public let mutationID: String
    public let results: [BurnBarMemoryAuthorityOperationResult]

    public init(mutationID: String, results: [BurnBarMemoryAuthorityOperationResult]) {
        self.mutationID = mutationID
        self.results = results
    }
}

public struct BurnBarMemoryAuthorityOperationResult: Codable, Equatable, Sendable {
    public let affectedRows: Int
    public let audits: [BurnBarMemoryAuthorityAuditReceipt]

    public init(affectedRows: Int, audits: [BurnBarMemoryAuthorityAuditReceipt]) {
        self.affectedRows = affectedRows
        self.audits = audits
    }
}

public struct BurnBarMemoryAuthorityAuditReceipt: Codable, Equatable, Sendable {
    public let sequence: Int
    public let hash: String

    public init(sequence: Int, hash: String) {
        self.sequence = sequence
        self.hash = hash
    }
}

/// One memory authority mutation. Cases mirror the app's authority flows
/// one-for-one so the rewire is mechanical and reviewable; the daemon applies
/// all operations of a request atomically, in order.
public enum BurnBarMemoryAuthorityOperation: Codable, Equatable, Sendable {
    case remember(BurnBarMemoryAuthorityRemember)
    case updateBody(BurnBarMemoryAuthorityUpdate)
    case setReviewStatus(BurnBarMemoryAuthorityReview)
    case deleteMemory(BurnBarMemoryAuthorityDelete)
    case reconcileSuppressions(BurnBarMemoryAuthorityReconcile)
    case claimUnowned(BurnBarMemoryAuthorityClaim)
    case enqueueFactTombstones(BurnBarMemoryAuthorityEnqueueTombstones)
    case recordSourceTombstone(BurnBarMemoryAuthoritySourceTombstone)
    case markTombstoneReplicated(BurnBarMemoryAuthorityMarkReplicated)
    case appendAudit(BurnBarMemoryAuthorityAuditEvent)

    private enum Kind: String, Codable {
        case remember
        case updateBody
        case setReviewStatus
        case deleteMemory
        case reconcileSuppressions
        case claimUnowned
        case enqueueFactTombstones
        case recordSourceTombstone
        case markTombstoneReplicated
        case appendAudit
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .remember: self = .remember(try container.decode(BurnBarMemoryAuthorityRemember.self, forKey: .value))
        case .updateBody: self = .updateBody(try container.decode(BurnBarMemoryAuthorityUpdate.self, forKey: .value))
        case .setReviewStatus: self = .setReviewStatus(try container.decode(BurnBarMemoryAuthorityReview.self, forKey: .value))
        case .deleteMemory: self = .deleteMemory(try container.decode(BurnBarMemoryAuthorityDelete.self, forKey: .value))
        case .reconcileSuppressions: self = .reconcileSuppressions(try container.decode(BurnBarMemoryAuthorityReconcile.self, forKey: .value))
        case .claimUnowned: self = .claimUnowned(try container.decode(BurnBarMemoryAuthorityClaim.self, forKey: .value))
        case .enqueueFactTombstones: self = .enqueueFactTombstones(try container.decode(BurnBarMemoryAuthorityEnqueueTombstones.self, forKey: .value))
        case .recordSourceTombstone: self = .recordSourceTombstone(try container.decode(BurnBarMemoryAuthoritySourceTombstone.self, forKey: .value))
        case .markTombstoneReplicated: self = .markTombstoneReplicated(try container.decode(BurnBarMemoryAuthorityMarkReplicated.self, forKey: .value))
        case .appendAudit: self = .appendAudit(try container.decode(BurnBarMemoryAuthorityAuditEvent.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .remember(let value):
            try container.encode(Kind.remember, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .updateBody(let value):
            try container.encode(Kind.updateBody, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .setReviewStatus(let value):
            try container.encode(Kind.setReviewStatus, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .deleteMemory(let value):
            try container.encode(Kind.deleteMemory, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .reconcileSuppressions(let value):
            try container.encode(Kind.reconcileSuppressions, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .claimUnowned(let value):
            try container.encode(Kind.claimUnowned, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .enqueueFactTombstones(let value):
            try container.encode(Kind.enqueueFactTombstones, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .recordSourceTombstone(let value):
            try container.encode(Kind.recordSourceTombstone, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .markTombstoneReplicated(let value):
            try container.encode(Kind.markTombstoneReplicated, forKey: .kind)
            try container.encode(value, forKey: .value)
        case .appendAudit(let value):
            try container.encode(Kind.appendAudit, forKey: .kind)
            try container.encode(value, forKey: .value)
        }
    }
}

/// `memory_body_snapshots` row image, exactly as the app's upsert binds it
/// (`ON CONFLICT(memory_id) DO UPDATE`, same column set).
public struct BurnBarMemoryAuthoritySnapshotRow: Codable, Equatable, Sendable {
    public let id: String
    public let memoryID: String
    public let bodyRef: String
    public let snapshotJSON: String
    public let bodyHash: String
    public let sourceKind: String
    public let createdAtText: String
    public let updatedAtText: String

    public init(
        id: String,
        memoryID: String,
        bodyRef: String,
        snapshotJSON: String,
        bodyHash: String,
        sourceKind: String,
        createdAtText: String,
        updatedAtText: String
    ) {
        self.id = id
        self.memoryID = memoryID
        self.bodyRef = bodyRef
        self.snapshotJSON = snapshotJSON
        self.bodyHash = bodyHash
        self.sourceKind = sourceKind
        self.createdAtText = createdAtText
        self.updatedAtText = updatedAtText
    }
}

/// `agent_memories` row image, exactly as the app's remember binds it
/// (`ON CONFLICT(id) DO NOTHING`). `scopeText` preserves the legacy v50
/// spelling rule (chat rows carry the literal `"chat"`).
public struct BurnBarMemoryAuthorityMemoryRow: Codable, Equatable, Sendable {
    public let id: String
    public let projectID: String
    public let kind: String
    public let scopeText: String
    public let confidence: Double
    public let bodyRef: String
    public let bodyRedacted: String
    public let tagsJSON: String
    public let sourcePath: String?
    public let validFromText: String
    public let validToText: String?
    public let supersededBy: String?
    public let createdAtText: String
    public let updatedAtText: String
    public let sourceKind: String
    public let reviewStatus: String
    public let userID: String?
    public let agentID: String?
    public let runID: String?
    public let appID: String?

    public init(
        id: String,
        projectID: String,
        kind: String,
        scopeText: String,
        confidence: Double,
        bodyRef: String,
        bodyRedacted: String,
        tagsJSON: String,
        sourcePath: String?,
        validFromText: String,
        validToText: String?,
        supersededBy: String?,
        createdAtText: String,
        updatedAtText: String,
        sourceKind: String,
        reviewStatus: String,
        userID: String?,
        agentID: String?,
        runID: String?,
        appID: String?
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.scopeText = scopeText
        self.confidence = confidence
        self.bodyRef = bodyRef
        self.bodyRedacted = bodyRedacted
        self.tagsJSON = tagsJSON
        self.sourcePath = sourcePath
        self.validFromText = validFromText
        self.validToText = validToText
        self.supersededBy = supersededBy
        self.createdAtText = createdAtText
        self.updatedAtText = updatedAtText
        self.sourceKind = sourceKind
        self.reviewStatus = reviewStatus
        self.userID = userID
        self.agentID = agentID
        self.runID = runID
        self.appID = appID
    }
}

/// `memory_provenance` row image (`ON CONFLICT(id) DO NOTHING`).
public struct BurnBarMemoryAuthorityProvenanceRow: Codable, Equatable, Sendable {
    public let id: String
    public let memoryID: String
    public let sourceKind: String
    public let threadLogicalID: String
    public let messageID: String?
    public let role: String
    public let authoredAtText: String
    public let contentHash: String
    public let occurrence: Int
    public let xdeviceHMAC: String
    public let citationState: String
    public let createdAtText: String

    public init(
        id: String,
        memoryID: String,
        sourceKind: String,
        threadLogicalID: String,
        messageID: String?,
        role: String,
        authoredAtText: String,
        contentHash: String,
        occurrence: Int,
        xdeviceHMAC: String,
        citationState: String,
        createdAtText: String
    ) {
        self.id = id
        self.memoryID = memoryID
        self.sourceKind = sourceKind
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.role = role
        self.authoredAtText = authoredAtText
        self.contentHash = contentHash
        self.occurrence = occurrence
        self.xdeviceHMAC = xdeviceHMAC
        self.citationState = citationState
        self.createdAtText = createdAtText
    }
}

/// `memory_fact_tombstones` row image. The conflict clause is selected per
/// call site, exactly matching the three legacy clauses: the enqueue path
/// keeps the existing row (`overwriteOnConflict == false`); the agent
/// delete path overwrites everything except `source_refs_json` (always
/// `'[]'` there); the chat review/delete paths overwrite `source_refs_json`
/// too (`refreshSourceRefsOnConflict == true`).
public struct BurnBarMemoryAuthorityFactTombstoneRow: Codable, Equatable, Sendable {
    public let id: String
    public let userID: String
    public let memoryID: String
    public let sourceRefsJSON: String
    public let reason: String
    public let createdAtText: String
    public let overwriteOnConflict: Bool
    public let refreshSourceRefsOnConflict: Bool

    public init(
        id: String,
        userID: String,
        memoryID: String,
        sourceRefsJSON: String,
        reason: String,
        createdAtText: String,
        overwriteOnConflict: Bool,
        refreshSourceRefsOnConflict: Bool
    ) {
        self.id = id
        self.userID = userID
        self.memoryID = memoryID
        self.sourceRefsJSON = sourceRefsJSON
        self.reason = reason
        self.createdAtText = createdAtText
        self.overwriteOnConflict = overwriteOnConflict
        self.refreshSourceRefsOnConflict = refreshSourceRefsOnConflict
    }
}

/// `memory_source_tombstones` row image (upsert-overwrite, legacy clause).
public struct BurnBarMemoryAuthoritySourceTombstoneRow: Codable, Equatable, Sendable {
    public let id: String
    public let userID: String?
    public let threadLogicalID: String
    public let messageID: String?
    public let contentHash: String?
    public let reason: String
    public let createdAtText: String

    public init(
        id: String,
        userID: String?,
        threadLogicalID: String,
        messageID: String?,
        contentHash: String?,
        reason: String,
        createdAtText: String
    ) {
        self.id = id
        self.userID = userID
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.contentHash = contentHash
        self.reason = reason
        self.createdAtText = createdAtText
    }
}

/// Audit event minus the chain fields. `labels` is the app's finalized
/// sorted list and `labelsJSON` its exact `auditLabelsJSON` encoding; the
/// daemon binds both verbatim and assigns `seq`/`prev_hash`/`hash`.
public struct BurnBarMemoryAuthorityAuditEvent: Codable, Equatable, Sendable {
    public let action: String
    public let projectID: String?
    public let subjectID: String?
    public let labels: [String]
    public let labelsJSON: String
    public let timestampText: String

    public init(
        action: String,
        projectID: String?,
        subjectID: String?,
        labels: [String],
        labelsJSON: String,
        timestampText: String
    ) {
        self.action = action
        self.projectID = projectID
        self.subjectID = subjectID
        self.labels = labels
        self.labelsJSON = labelsJSON
        self.timestampText = timestampText
    }
}

/// The add-memory transaction: snapshot upsert, memory insert, citation
/// provenance, the `memory.add` audit, and the dedup merge (loser updates,
/// provenance copies, per-loser `memory.supersede` audits, one
/// `memory.merge` audit). The app pre-reads duplicate candidates and loser
/// provenance over its local connection; `merge` is nil when nothing matched.
public struct BurnBarMemoryAuthorityRemember: Codable, Equatable, Sendable {
    public let snapshot: BurnBarMemoryAuthoritySnapshotRow
    public let memory: BurnBarMemoryAuthorityMemoryRow
    public let provenance: [BurnBarMemoryAuthorityProvenanceRow]
    public let audits: [BurnBarMemoryAuthorityAuditEvent]
    public let merge: BurnBarMemoryAuthorityMerge?

    public init(
        snapshot: BurnBarMemoryAuthoritySnapshotRow,
        memory: BurnBarMemoryAuthorityMemoryRow,
        provenance: [BurnBarMemoryAuthorityProvenanceRow],
        audits: [BurnBarMemoryAuthorityAuditEvent],
        merge: BurnBarMemoryAuthorityMerge?
    ) {
        self.snapshot = snapshot
        self.memory = memory
        self.provenance = provenance
        self.audits = audits
        self.merge = merge
    }
}

public struct BurnBarMemoryAuthorityMerge: Codable, Equatable, Sendable {
    public let winnerID: String
    public let loserIDs: [String]
    public let sourceKinds: [String]
    public let storageProjectID: String
    public let nowText: String
    public let nowTimestampText: String
    public let provenanceCopies: [BurnBarMemoryAuthorityProvenanceRow]
    public let supersedeAudits: [BurnBarMemoryAuthorityAuditEvent]
    public let mergeAudit: BurnBarMemoryAuthorityAuditEvent

    public init(
        winnerID: String,
        loserIDs: [String],
        sourceKinds: [String],
        storageProjectID: String,
        nowText: String,
        nowTimestampText: String,
        provenanceCopies: [BurnBarMemoryAuthorityProvenanceRow],
        supersedeAudits: [BurnBarMemoryAuthorityAuditEvent],
        mergeAudit: BurnBarMemoryAuthorityAuditEvent
    ) {
        self.winnerID = winnerID
        self.loserIDs = loserIDs
        self.sourceKinds = sourceKinds
        self.storageProjectID = storageProjectID
        self.nowText = nowText
        self.nowTimestampText = nowTimestampText
        self.provenanceCopies = provenanceCopies
        self.supersedeAudits = supersedeAudits
        self.mergeAudit = mergeAudit
    }
}

/// The body/kind/confidence edit transaction. `reseal` carries the snapshot
/// rewrite plus the compare-and-swap precondition: the `body_hash` and
/// `updated_at` the app read before finalizing (`nil` each means the row
/// must be absent). A kind/confidence-only patch sends no reseal and no
/// precondition, exactly like the legacy path skipping the snapshot read.
public struct BurnBarMemoryAuthorityUpdate: Codable, Equatable, Sendable {
    public let memoryID: String
    public let sourceKind: String
    public let kind: String?
    public let confidence: Double?
    public let updatedAtText: String
    public let reseal: BurnBarMemoryAuthorityReseal?
    public let audit: BurnBarMemoryAuthorityAuditEvent

    public init(
        memoryID: String,
        sourceKind: String,
        kind: String?,
        confidence: Double?,
        updatedAtText: String,
        reseal: BurnBarMemoryAuthorityReseal?,
        audit: BurnBarMemoryAuthorityAuditEvent
    ) {
        self.memoryID = memoryID
        self.sourceKind = sourceKind
        self.kind = kind
        self.confidence = confidence
        self.updatedAtText = updatedAtText
        self.reseal = reseal
        self.audit = audit
    }
}

public struct BurnBarMemoryAuthorityReseal: Codable, Equatable, Sendable {
    public let expectedBodyHash: String?
    public let expectedUpdatedAtText: String?
    public let snapshot: BurnBarMemoryAuthoritySnapshotRow

    public init(
        expectedBodyHash: String?,
        expectedUpdatedAtText: String?,
        snapshot: BurnBarMemoryAuthoritySnapshotRow
    ) {
        self.expectedBodyHash = expectedBodyHash
        self.expectedUpdatedAtText = expectedUpdatedAtText
        self.snapshot = snapshot
    }
}

/// The review-verdict transaction. `updatedAtText` is the legacy ISO 8601
/// stamp (not GRDB text) — preserved verbatim, see the lane header.
/// `factTombstone` is set on the unapprove-with-owner path;
/// `markFactTombstoneReplicated` on the approve-with-owner path; neither
/// otherwise. The agent-lane daemon publish stays a separate call after the
/// verdict commits, as before.
public struct BurnBarMemoryAuthorityReview: Codable, Equatable, Sendable {
    public let memoryID: String
    public let sourceKind: String
    public let reviewStatus: String
    public let updatedAtText: String
    public let factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?
    public let markFactTombstoneReplicated: Bool
    public let replicatedAtText: String?
    public let audit: BurnBarMemoryAuthorityAuditEvent

    public init(
        memoryID: String,
        sourceKind: String,
        reviewStatus: String,
        updatedAtText: String,
        factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?,
        markFactTombstoneReplicated: Bool,
        replicatedAtText: String?,
        audit: BurnBarMemoryAuthorityAuditEvent
    ) {
        self.memoryID = memoryID
        self.sourceKind = sourceKind
        self.reviewStatus = reviewStatus
        self.updatedAtText = updatedAtText
        self.factTombstone = factTombstone
        self.markFactTombstoneReplicated = markFactTombstoneReplicated
        self.replicatedAtText = replicatedAtText
        self.audit = audit
    }
}

/// The delete cascade. `agent` carries the mirrored-row extras (fact
/// tombstone, quarantine delete, sync-body blanking with its legacy ISO
/// stamp); `factTombstone` the approved-chat-with-owner tombstone. The
/// agent-lane daemon forget still runs first and fail-closed, as before.
public struct BurnBarMemoryAuthorityDelete: Codable, Equatable, Sendable {
    public let memoryID: String
    public let sourceKind: String
    public let agent: BurnBarMemoryAuthorityAgentDelete?
    public let factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?
    public let blankedBodyUpdatedAtText: String?
    public let audit: BurnBarMemoryAuthorityAuditEvent

    public init(
        memoryID: String,
        sourceKind: String,
        agent: BurnBarMemoryAuthorityAgentDelete?,
        factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?,
        blankedBodyUpdatedAtText: String?,
        audit: BurnBarMemoryAuthorityAuditEvent
    ) {
        self.memoryID = memoryID
        self.sourceKind = sourceKind
        self.agent = agent
        self.factTombstone = factTombstone
        self.blankedBodyUpdatedAtText = blankedBodyUpdatedAtText
        self.audit = audit
    }
}

public struct BurnBarMemoryAuthorityAgentDelete: Codable, Equatable, Sendable {
    public let factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?

    public init(factTombstone: BurnBarMemoryAuthorityFactTombstoneRow?) {
        self.factTombstone = factTombstone
    }
}

/// The source-tombstone reconcile sweep. The app pre-reads matching rows
/// over its local connection; the daemon applies the conditional suppress
/// update plus one audit per row, atomically.
public struct BurnBarMemoryAuthorityReconcile: Codable, Equatable, Sendable {
    public let matches: [BurnBarMemoryAuthorityReconcileMatch]
    public let sourceKind: String
    public let validToText: String
    public let updatedAtText: String
    public let timestampText: String

    public init(
        matches: [BurnBarMemoryAuthorityReconcileMatch],
        sourceKind: String,
        validToText: String,
        updatedAtText: String,
        timestampText: String
    ) {
        self.matches = matches
        self.sourceKind = sourceKind
        self.validToText = validToText
        self.updatedAtText = updatedAtText
        self.timestampText = timestampText
    }
}

public struct BurnBarMemoryAuthorityReconcileMatch: Codable, Equatable, Sendable {
    public let memoryID: String
    public let projectID: String
    public let labels: [String]
    public let labelsJSON: String

    public init(memoryID: String, projectID: String, labels: [String], labelsJSON: String) {
        self.memoryID = memoryID
        self.projectID = projectID
        self.labels = labels
        self.labelsJSON = labelsJSON
    }
}

/// The unowned-agent-memory claim (`UPDATE ... WHERE source_kind AND
/// user_id IS NULL/empty`). Returns the claimed count.
public struct BurnBarMemoryAuthorityClaim: Codable, Equatable, Sendable {
    public let userID: String
    public let sourceKind: String

    public init(userID: String, sourceKind: String) {
        self.userID = userID
        self.sourceKind = sourceKind
    }
}

/// The unsyncable-row tombstone enqueue. The app pre-reads candidates over
/// its local connection; rows insert `ON CONFLICT DO NOTHING` and the result
/// carries the newly enqueued count.
public struct BurnBarMemoryAuthorityEnqueueTombstones: Codable, Equatable, Sendable {
    public let tombstones: [BurnBarMemoryAuthorityFactTombstoneRow]

    public init(tombstones: [BurnBarMemoryAuthorityFactTombstoneRow]) {
        self.tombstones = tombstones
    }
}

public struct BurnBarMemoryAuthoritySourceTombstone: Codable, Equatable, Sendable {
    public let tombstone: BurnBarMemoryAuthoritySourceTombstoneRow

    public init(tombstone: BurnBarMemoryAuthoritySourceTombstoneRow) {
        self.tombstone = tombstone
    }
}

public struct BurnBarMemoryAuthorityMarkReplicated: Codable, Equatable, Sendable {
    public let table: BurnBarMemoryAuthorityTombstoneTable
    public let id: String
    public let replicatedAtText: String

    public init(table: BurnBarMemoryAuthorityTombstoneTable, id: String, replicatedAtText: String) {
        self.table = table
        self.id = id
        self.replicatedAtText = replicatedAtText
    }
}

public enum BurnBarMemoryAuthorityTombstoneTable: String, Codable, Equatable, Sendable {
    case fact
    case source
}
