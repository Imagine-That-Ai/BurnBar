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
        self.sourceQuickCheck = sourceQuickCheck
    }
}

// MARK: - Timestamps

/// Timestamp parsing for a store written by three different code paths.
///
/// `memory_audit.ts` is ISO-8601 with a `T`, fractional seconds and a `Z`
/// (`ControlPlaneStore.iso8601String`); the daemon's `isoNow()` omits the
/// fraction; and GRDB binds a `Date` as `"YYYY-MM-DD HH:MM:SS.SSS"` with a SPACE
/// and no zone, which is what most `agent_memories` columns actually hold. A
/// formatter configured for one of those silently returns nil for the others,
/// and a nil timestamp here would break conjunct 6 the wrong way — a body whose
/// time cannot be read would look "not newer than the verdict".
///
/// So this is a hand-rolled parser over the field layout, which also keeps the
/// type free of the non-`Sendable` `ISO8601DateFormatter` and free of any
/// locale or default-timezone influence on a value the bundle's determinism
/// depends on.
public enum MemoryExportTimestamp {

    /// Accepts `YYYY-MM-DD` followed by `T` or a space, `HH:MM:SS`, an optional
    /// `.fff`, and an optional `Z` or `±HH:MM`. A missing zone is UTC, which is
    /// what every writer in the store actually means.
    public static func parse(_ text: String?) -> Date? {
        guard let text, text.count >= 19 else { return nil }
        let scalars = Array(text.utf8)
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 else { return nil }
                value = value * 10 + Int(scalars[index] - 48)
            }
            return value
        }
        guard scalars[4] == UInt8(ascii: "-"), scalars[7] == UInt8(ascii: "-"),
              scalars[10] == UInt8(ascii: "T") || scalars[10] == UInt8(ascii: " "),
              scalars[13] == UInt8(ascii: ":"), scalars[16] == UInt8(ascii: ":"),
              let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60 else {
            return nil
        }

        var index = 19
        var milliseconds = 0
        if index < scalars.count, scalars[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57, digits < 3 {
                milliseconds = milliseconds * 10 + Int(scalars[index] - 48)
                index += 1
                digits += 1
            }
            // Pad a shorter fraction: ".5" is 500 ms, not 5.
            while digits < 3 { milliseconds *= 10; digits += 1 }
            // Ignore any remaining sub-millisecond digits.
            while index < scalars.count, scalars[index] >= 48, scalars[index] <= 57 { index += 1 }
        }

        var offsetSeconds = 0
        if index < scalars.count, scalars[index] == UInt8(ascii: "+") || scalars[index] == UInt8(ascii: "-") {
            let sign = scalars[index] == UInt8(ascii: "-") ? -1 : 1
            guard let offsetHour = number((index + 1)..<(index + 3)) else { return nil }
            let offsetMinuteStart = scalars.count > index + 3 && scalars[index + 3] == UInt8(ascii: ":")
                ? index + 4
                : index + 3
            let offsetMinute = number(offsetMinuteStart..<(offsetMinuteStart + 2)) ?? 0
            offsetSeconds = sign * (offsetHour * 3600 + offsetMinute * 60)
        }

        let epochDays = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(epochDays * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds)
        return Date(timeIntervalSince1970: seconds + Double(milliseconds) / 1000)
    }

    /// Milliseconds since the epoch, the unit every `ts_ms` field in MIF uses.
    public static func milliseconds(_ text: String?, fallback: Int = 0) -> Int {
        guard let date = parse(text) else { return fallback }
        return Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The app's own wire format, for a value this target writes back out.
    public static func string(_ date: Date) -> String {
        let total = Int((date.timeIntervalSince1970 * 1000).rounded())
        let (days, msOfDay) = total >= 0
            ? (total / 86_400_000, total % 86_400_000)
            : ((total - 86_399_999) / 86_400_000, total - ((total - 86_399_999) / 86_400_000) * 86_400_000)
        let civil = civilFromDays(days)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            civil.year, civil.month, civil.day,
            msOfDay / 3_600_000, (msOfDay / 60_000) % 60, (msOfDay / 1000) % 60, msOfDay % 1000
        )
    }

    // Howard Hinnant's civil-from-days pair, which is exact for every date the
    // store can hold and needs no calendar object.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp + (mp < 10 ? 3 : -9)
        return (y + (month <= 2 ? 1 : 0), month, day)
    }
}
