import Foundation

// MARK: - Rollback Contracts (Hermes Square §6.10)
//
// Phone-readable index of per-session snapshots the Mac writes under
// `.burnbar/sessions/{sessionID}/snapshots/{N}` while a mission runs.
// Source pattern: DiffBack (https://github.com/A386official/diffback) +
// Rubrik Agent Rewind (https://www.rubrik.com/insights/ai-issues-take-control-with-rubrik-agent-rewind).

public struct RollbackSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    /// Mission session this snapshot belongs to.
    public let sessionID: String
    /// 0-based sequence number — lower = earlier in the mission.
    public let sequence: Int
    /// ISO-8601 timestamp the snapshot was taken.
    public let takenAt: Date
    /// Human-friendly action label that produced this snapshot
    /// ("Edit src/foo.swift", "Run npm test").
    public let actionLabel: String
    /// Relative paths the snapshot covers — used by the phone to render
    /// the per-file revert affordance.
    public let touchedFiles: [String]
    /// Optional opaque token the Mac uses to look the snapshot up on
    /// disk. Phone treats as opaque.
    public let macSnapshotPath: String?
    /// Whether the snapshot has been restored. Set when a rollback runs.
    public let restoredAt: Date?

    public init(
        id: String,
        sessionID: String,
        sequence: Int,
        takenAt: Date,
        actionLabel: String,
        touchedFiles: [String],
        macSnapshotPath: String? = nil,
        restoredAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.takenAt = takenAt
        self.actionLabel = actionLabel
        self.touchedFiles = touchedFiles
        self.macSnapshotPath = macSnapshotPath
        self.restoredAt = restoredAt
    }
}

// MARK: - Rollback request

public enum RollbackScope: Codable, Sendable, Hashable {
    /// Roll the entire session back to before any agent action.
    case fullSession
    /// Roll a single file back to its prior state.
    case singleFile(path: String)
    /// Roll back the most recent N actions.
    case lastN(count: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, path, count
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "fullSession": self = .fullSession
        case "singleFile":
            self = .singleFile(path: try c.decode(String.self, forKey: .path))
        case "lastN":
            self = .lastN(count: try c.decode(Int.self, forKey: .count))
        default:
            self = .fullSession
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fullSession:
            try c.encode("fullSession", forKey: .kind)
        case .singleFile(let path):
            try c.encode("singleFile", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .lastN(let count):
            try c.encode("lastN", forKey: .kind)
            try c.encode(count, forKey: .count)
        }
    }
}

public struct RollbackRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let sessionID: String
    public let scope: RollbackScope
    public let requestedAt: Date
    public let requestedBy: String          // device label / user uid prefix
    public var status: Status
    public var resolvedAt: Date?
    public var errorMessage: String?

    public enum Status: String, Codable, Sendable, Hashable {
        case pending
        case inFlight
        case completed
        case failed
    }

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        scope: RollbackScope,
        requestedAt: Date = Date(),
        requestedBy: String,
        status: Status = .pending,
        resolvedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.scope = scope
        self.requestedAt = requestedAt
        self.requestedBy = requestedBy
        self.status = status
        self.resolvedAt = resolvedAt
        self.errorMessage = errorMessage
    }
}

// MARK: - Pure-logic planner

public enum RollbackPlanner {
    /// Given a set of `RollbackSnapshot` rows and a desired scope, return
    /// the snapshots to apply (in descending sequence order — newest first).
    public static func snapshotsToRestore(
        all: [RollbackSnapshot],
        scope: RollbackScope
    ) -> [RollbackSnapshot] {
        let sorted = all.sorted { $0.sequence > $1.sequence }
        switch scope {
        case .fullSession:
            return sorted
        case .singleFile(let path):
            // First snapshot (newest-first iteration) that touched the path.
            return sorted.filter { $0.touchedFiles.contains(path) }.prefix(1).map { $0 }
        case .lastN(let count):
            return Array(sorted.prefix(max(0, count)))
        }
    }
}
