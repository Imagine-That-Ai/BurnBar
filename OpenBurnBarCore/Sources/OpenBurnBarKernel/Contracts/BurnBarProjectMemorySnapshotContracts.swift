import Foundation

/// Wave 2.1c: the daemon owns `project_memory_snapshots` (ADR-005) and the
/// Mac app routes its snapshot writes through these contracts instead of
/// `INSERT`ing into the table directly. Reads stay on the app's local
/// connection until the read cutover.
///
/// Lane semantics, read carefully — the table is shared by two lanes that
/// must never be conflated:
/// - The daemon lane (`agent-*` slugs) is written by the daemon's own
///   publish path (`writeProjectMemorySnapshot`), which stamps `updatedAt`
///   and recomputes `contentHash` over the full stored JSON.
/// - The app lane (project slugs) carries bytes the app already finalized:
///   `snapshotJSON` is the app's own `ProjectMemorySnapshot` encoding and
///   `contentHash` is the app's change-detection token over its hash payload
///   (a subset of fields — NOT the full JSON). The daemon stores both
///   verbatim and recomputes nothing; re-hashing the full JSON here would
///   silently change the digest the app's cloud backup compares against.
///
/// Timestamps ride as ISO 8601 and the daemon persists them in GRDB's
/// `Date` text representation (`yyyy-MM-dd HH:mm:ss.SSS`, UTC) — the exact
/// format the app's pre-cutover GRDB writes used — so RPC-written rows are
/// byte-compatible with legacy rows in `ORDER BY` and `MAX()`.
public struct BurnBarProjectMemorySnapshotUpsertRequest: Codable, Equatable, Sendable {
    public let projectSlug: String
    public let projectDisplayName: String
    public let snapshotJSON: String
    public let contentHash: String
    public let sourceSessionCount: Int
    public let sourceConversationCount: Int
    public let generatedAt: String
    public let schemaVersion: Int
    public let updatedAt: String

    public init(
        projectSlug: String,
        projectDisplayName: String,
        snapshotJSON: String,
        contentHash: String,
        sourceSessionCount: Int,
        sourceConversationCount: Int,
        generatedAt: String,
        schemaVersion: Int,
        updatedAt: String
    ) {
        self.projectSlug = projectSlug
        self.projectDisplayName = projectDisplayName
        self.snapshotJSON = snapshotJSON
        self.contentHash = contentHash
        self.sourceSessionCount = sourceSessionCount
        self.sourceConversationCount = sourceConversationCount
        self.generatedAt = generatedAt
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
    }
}

public struct BurnBarProjectMemorySnapshotUpsertResponse: Codable, Equatable, Sendable {
    public let projectSlug: String
    public let updatedAt: String

    public init(projectSlug: String, updatedAt: String) {
        self.projectSlug = projectSlug
        self.updatedAt = updatedAt
    }
}

public struct BurnBarProjectMemorySnapshotDeleteRequest: Codable, Equatable, Sendable {
    public let projectSlug: String

    public init(projectSlug: String) {
        self.projectSlug = projectSlug
    }
}

public struct BurnBarProjectMemorySnapshotDeleteResponse: Codable, Equatable, Sendable {
    public let projectSlug: String
    public let deleted: Bool

    public init(projectSlug: String, deleted: Bool) {
        self.projectSlug = projectSlug
        self.deleted = deleted
    }
}

public struct BurnBarProjectMemorySnapshotDeleteAllRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct BurnBarProjectMemorySnapshotDeleteAllResponse: Codable, Equatable, Sendable {
    public let deletedCount: Int

    public init(deletedCount: Int) {
        self.deletedCount = deletedCount
    }
}
