// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportSourceRows — plain values for every oracle table the exporter
// reads.
//
// The classifier (§3.1), the chain walk (§7) and the body resolver (§3.2) are
// all pure functions over these structs, so the whole decision surface is
// unit-testable without a database. `MemoryExportStoreReader` is the only file
// that knows GRDB exists.
//
// Optionality is load-bearing, not defensive: `sourceKind` and `reviewStatus`
// are `nil` when the COLUMN IS ABSENT (a daemon-only or Python-created file),
// which is classifier row 13 and must not be confused with an empty string.

import Foundation

/// One `agent_memories` row.
public struct MemoryExportMemoryRow: Sendable, Equatable {
    public var id: String
    public var projectID: String
    public var kind: String
    public var scope: String
    public var confidence: Double
    public var bodyRef: String
    public var bodyRedacted: String
    public var tagsJSON: String
    public var sourcePath: String?
    public var validFrom: String
    public var validTo: String?
    public var supersededBy: String?
    public var createdAt: String
    public var updatedAt: String
    /// `nil` when the v51 `source_kind` column does not exist.
    public var sourceKind: String?
    /// `nil` when the v51 `review_status` column does not exist (row 13).
    public var reviewStatus: String?
    public var userID: String?
    public var agentID: String?
    public var runID: String?
    public var appID: String?

    public init(
        id: String,
        projectID: String,
        kind: String = "fact",
        scope: String = "chat",
        confidence: Double = 0.5,
        bodyRef: String,
        bodyRedacted: String = "",
        tagsJSON: String = "[]",
        sourcePath: String? = nil,
        validFrom: String,
        validTo: String? = nil,
        supersededBy: String? = nil,
        createdAt: String,
        updatedAt: String,
        sourceKind: String? = "chat",
        reviewStatus: String? = "quarantined",
        userID: String? = nil,
        agentID: String? = nil,
        runID: String? = nil,
        appID: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.bodyRef = bodyRef
        self.bodyRedacted = bodyRedacted
        self.tagsJSON = tagsJSON
        self.sourcePath = sourcePath
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceKind = sourceKind
        self.reviewStatus = reviewStatus
        self.userID = userID
        self.agentID = agentID
        self.runID = runID
        self.appID = appID
    }

    public var tags: [String] {
        guard let data = tagsJSON.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return decoded
    }
}

/// One `memory_audit` row, with `labels_json` already decoded.
public struct MemoryExportAuditRow: Sendable, Equatable {
    public var seq: Int
    public var ts: String
    public var actor: String
    public var action: String
    public var domain: String
    public var projectID: String?
    public var subjectID: String?
    public var labels: [String]
    public var prevHash: String?
    public var hash: String

    public init(
        seq: Int,
        ts: String,
        actor: String,
        action: String,
        domain: String = "memory",
        projectID: String? = nil,
        subjectID: String? = nil,
        labels: [String] = [],
        prevHash: String? = nil,
        hash: String = ""
    ) {
        self.seq = seq
        self.ts = ts
        self.actor = actor
        self.action = action
        self.domain = domain
        self.projectID = projectID
        self.subjectID = subjectID
        self.labels = labels
        self.prevHash = prevHash
        self.hash = hash
    }

    /// M-13: the verdict's value is the `review_status:<raw>` label, **never**
    /// the action verb. BurnBar writes `memory.reject` for every non-approved
    /// transition, `approved -> quarantined` included; reading the verb turns
    /// "send back to review" into `rejected` + human origin, which the merge
    /// then makes permanent and unrecallable.
    public var reviewStatusLabelValue: String? {
        for label in labels where label.hasPrefix(Self.reviewStatusLabelPrefix) {
            return String(label.dropFirst(Self.reviewStatusLabelPrefix.count))
        }
        return nil
    }

    static let reviewStatusLabelPrefix = "review_status:"
}

/// One `memory_body_snapshots` row (convention A, the app lane).
public struct MemoryExportBodySnapshotRow: Sendable, Equatable {
    public var id: String
    public var memoryID: String
    public var bodyRef: String
    public var snapshotJSON: String
    public var bodyHash: String
    public var sourceKind: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        memoryID: String,
        bodyRef: String,
        snapshotJSON: String,
        bodyHash: String,
        sourceKind: String = "chat",
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.memoryID = memoryID
        self.bodyRef = bodyRef
        self.snapshotJSON = snapshotJSON
        self.bodyHash = bodyHash
        self.sourceKind = sourceKind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The plaintext body inside `snapshot_json`. The column is a full
    /// `MemoryBodySnapshot` document, not a bare string.
    public var body: String? {
        guard let data = snapshotJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["body"] as? String
    }
}

/// One `memory_provenance` row.
public struct MemoryExportProvenanceRow: Sendable, Equatable {
    public var id: String
    public var memoryID: String
    public var sourceKind: String
    public var threadLogicalID: String
    public var messageID: String?
    public var role: String
    public var authoredAt: String
    public var contentHash: String
    public var occurrence: Int
    public var citationState: String
    public var createdAt: String

    public init(
        id: String,
        memoryID: String,
        sourceKind: String = "chat_message",
        threadLogicalID: String,
        messageID: String? = nil,
        role: String = "human",
        authoredAt: String,
        contentHash: String,
        occurrence: Int = 0,
        citationState: String = "live",
        createdAt: String
    ) {
        self.id = id
        self.memoryID = memoryID
        self.sourceKind = sourceKind
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.role = role
        self.authoredAt = authoredAt
        self.contentHash = contentHash
        self.occurrence = occurrence
        self.citationState = citationState
        self.createdAt = createdAt
    }
}

/// One `memory_fact_tombstones` row.
public struct MemoryExportFactTombstoneRow: Sendable, Equatable {
    public var id: String
    public var userID: String
    public var memoryID: String
    public var sourceRefsJSON: String
    public var reason: String
    public var createdAt: String
    public var replicatedAt: String?

    public init(
        id: String,
        userID: String,
        memoryID: String,
        sourceRefsJSON: String = "[]",
        reason: String,
        createdAt: String,
        replicatedAt: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.memoryID = memoryID
        self.sourceRefsJSON = sourceRefsJSON
        self.reason = reason
        self.createdAt = createdAt
        self.replicatedAt = replicatedAt
    }
}

/// One `memory_source_tombstones` row. Carried as a `source` tombstone and
/// retained by the importer as a standing suppressor (M-15).
public struct MemoryExportSourceTombstoneRow: Sendable, Equatable {
    public var id: String
    public var userID: String?
    public var threadLogicalID: String
    public var messageID: String?
    public var contentHash: String?
    public var reason: String
    public var createdAt: String
    public var replicatedAt: String?

    public init(
        id: String,
        userID: String? = nil,
        threadLogicalID: String,
        messageID: String? = nil,
        contentHash: String? = nil,
        reason: String,
        createdAt: String,
        replicatedAt: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.threadLogicalID = threadLogicalID
        self.messageID = messageID
        self.contentHash = contentHash
        self.reason = reason
        self.createdAt = createdAt
        self.replicatedAt = replicatedAt
    }
}

/// One `pcm_projects` row plus its non-path aliases.
public struct MemoryExportProjectRow: Sendable, Equatable {
    public var projectID: String
    public var identityVersion: Int
    public var identityFingerprint: String
    public var projectName: String
    public var primaryPath: String
    public var createdAt: String
    public var updatedAt: String
    /// `pcm_project_aliases` rows. These are **path** aliases, which §2 forbids
    /// transporting; the count is carried into `not_exported` and the values
    /// are not.
    public var pathAliasCount: Int

    public init(
        projectID: String,
        identityVersion: Int,
        identityFingerprint: String,
        projectName: String,
        primaryPath: String,
        createdAt: String,
        updatedAt: String,
        pathAliasCount: Int = 0
    ) {
        self.projectID = projectID
        self.identityVersion = identityVersion
        self.identityFingerprint = identityFingerprint
        self.projectName = projectName
        self.primaryPath = primaryPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pathAliasCount = pathAliasCount
    }
}

/// One `memory_embedding_refs` lane roll-up. v1 carries counts only; the record
/// type has no vector field, so a bundle physically cannot carry one.
public struct MemoryExportEmbeddingLane: Sendable, Equatable {
    public var versionID: String
    public var dimension: Int
    public var rowCount: Int

    public init(versionID: String, dimension: Int, rowCount: Int) {
        self.versionID = versionID
        self.dimension = dimension
        self.rowCount = rowCount
    }
}

/// Everything one export reads out of the store, in one value.
public struct MemoryExportSourceSnapshot: Sendable {
    public var memories: [MemoryExportMemoryRow]
    public var auditRows: [MemoryExportAuditRow]
    public var bodySnapshots: [MemoryExportBodySnapshotRow]
    /// `project_memory_snapshots.snapshotJSON` by `projectSlug`.
    public var projectSnapshots: [String: String]
    /// `memory_quarantine_bodies.body` by `memory_id`.
    public var quarantineBodies: [String: String]
    public var provenance: [MemoryExportProvenanceRow]
    public var factTombstones: [MemoryExportFactTombstoneRow]
    public var sourceTombstones: [MemoryExportSourceTombstoneRow]
    public var projects: [MemoryExportProjectRow]
    public var embeddingLanes: [MemoryExportEmbeddingLane]
    /// False only when `memory_audit` is absent or unreadable — §3.1's retained
    /// fail-closed base case (row 16).
    public var auditTableAvailable: Bool
    public var auditHeadSeq: Int
    public var auditHeadHash: String?
    public var sourceQuickCheck: String?

    public init(
        memories: [MemoryExportMemoryRow] = [],
        auditRows: [MemoryExportAuditRow] = [],
        bodySnapshots: [MemoryExportBodySnapshotRow] = [],
        projectSnapshots: [String: String] = [:],
        quarantineBodies: [String: String] = [:],
        provenance: [MemoryExportProvenanceRow] = [],
        factTombstones: [MemoryExportFactTombstoneRow] = [],
        sourceTombstones: [MemoryExportSourceTombstoneRow] = [],
        projects: [MemoryExportProjectRow] = [],
        embeddingLanes: [MemoryExportEmbeddingLane] = [],
        auditTableAvailable: Bool = true,
        auditHeadSeq: Int = 0,
        auditHeadHash: String? = nil,
        sourceQuickCheck: String? = "ok"
    ) {
        self.memories = memories
        self.auditRows = auditRows
        self.bodySnapshots = bodySnapshots
        self.projectSnapshots = projectSnapshots
        self.quarantineBodies = quarantineBodies
        self.provenance = provenance
        self.factTombstones = factTombstones
        self.sourceTombstones = sourceTombstones
        self.projects = projects
        self.embeddingLanes = embeddingLanes
        self.auditTableAvailable = auditTableAvailable
        self.auditHeadSeq = auditHeadSeq
        self.auditHeadHash = auditHeadHash
        self.sourceQuickCheck = sourceQuickCheck
    }
}

// MARK: - Timestamps

/// The oracle stores ISO-8601 strings written by two different formatters (the
/// app emits fractional seconds, the daemon does not). Sorting or comparing
/// them as strings works only while both formats agree on width, so parse.
public enum MemoryExportTimestamp {
    private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ text: String?) -> Date? {
        guard let text, text.isEmpty == false else { return nil }
        return withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }

    /// Milliseconds since the epoch, the unit every `ts_ms` field in MIF uses.
    public static func milliseconds(_ text: String?, fallback: Int = 0) -> Int {
        guard let date = parse(text) else { return fallback }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    public static func string(_ date: Date) -> String {
        withFraction.string(from: date)
    }
}
