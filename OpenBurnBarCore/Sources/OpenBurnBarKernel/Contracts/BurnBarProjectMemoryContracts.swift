import Foundation

public struct BurnBarProjectMemoryRememberRequest: Codable, Hashable, Sendable {
    public let text: String
    public let projectPath: String?
    public let kind: String
    public let scope: String
    public let tags: [String]
    public let confidence: Double
    public let sourcePath: String?
    public let reviewStatus: MemoryReviewStatus
    /// Present means the `agent` partition and keys its blind-sync document; `nil` keeps `"code"`.
    public let engineMemoryID: String?

    public init(
        text: String,
        projectPath: String? = nil,
        kind: String = "note",
        scope: String = "personal",
        tags: [String] = [],
        confidence: Double = 1.0,
        sourcePath: String? = nil,
        reviewStatus: MemoryReviewStatus = .approved,
        engineMemoryID: String? = nil
    ) {
        self.text = text
        self.projectPath = projectPath
        self.kind = kind
        self.scope = scope
        self.tags = tags
        self.confidence = confidence
        self.sourcePath = sourcePath
        self.reviewStatus = reviewStatus
        self.engineMemoryID = engineMemoryID
    }

    private enum CodingKeys: String, CodingKey {
        case text, projectPath, kind, scope, tags, confidence, sourcePath, reviewStatus, engineMemoryID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try values.decode(String.self, forKey: .text)
        self.projectPath = try values.decodeIfPresent(String.self, forKey: .projectPath)
        self.kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "note"
        self.scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? "personal"
        self.tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.confidence = try values.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
        self.sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
        self.reviewStatus = try values.decodeIfPresent(MemoryReviewStatus.self, forKey: .reviewStatus) ?? .approved
        self.engineMemoryID = try values.decodeIfPresent(String.self, forKey: .engineMemoryID)
    }
}

public struct BurnBarProjectMemoryRememberResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let memoryID: String
    public let auditHash: String

    public init(traceID: String, projectID: String, memoryID: String, auditHash: String) {
        self.traceID = traceID
        self.projectID = projectID
        self.memoryID = memoryID
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectMemoryRecallRequest: Codable, Hashable, Sendable {
    public let query: String
    public let projectPath: String?
    public let limit: Int
    public let scope: String
    public let includeCrossProject: Bool
    public let includeQuarantined: Bool
    public let includeForgotten: Bool

    public init(
        query: String,
        projectPath: String? = nil,
        limit: Int = 20,
        scope: String = "all",
        includeCrossProject: Bool = false,
        includeQuarantined: Bool = false,
        includeForgotten: Bool = false
    ) {
        self.query = query
        self.projectPath = projectPath
        self.limit = limit
        self.scope = scope
        self.includeCrossProject = includeCrossProject
        self.includeQuarantined = includeQuarantined
        self.includeForgotten = includeForgotten
    }

    private enum CodingKeys: String, CodingKey {
        case query, projectPath, limit, scope, includeCrossProject, includeQuarantined, includeForgotten
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try values.decode(String.self, forKey: .query)
        self.projectPath = try values.decodeIfPresent(String.self, forKey: .projectPath)
        self.limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 20
        self.scope = try values.decodeIfPresent(String.self, forKey: .scope) ?? "all"
        self.includeCrossProject = try values.decodeIfPresent(Bool.self, forKey: .includeCrossProject) ?? false
        self.includeQuarantined = try values.decodeIfPresent(Bool.self, forKey: .includeQuarantined) ?? false
        self.includeForgotten = try values.decodeIfPresent(Bool.self, forKey: .includeForgotten) ?? false
    }
}

public struct BurnBarProjectMemoryHit: Codable, Hashable, Sendable {
    public let memoryID: String
    public let projectID: String
    public let kind: String
    public let scope: String
    public let confidence: Double
    public let bodyRedacted: String
    public let tags: [String]
    public let sourcePath: String?
    public let snippet: String
    public let rank: Double?
    public let reviewStatus: MemoryReviewStatus

    public init(
        memoryID: String,
        projectID: String,
        kind: String,
        scope: String,
        confidence: Double,
        bodyRedacted: String,
        tags: [String],
        sourcePath: String?,
        snippet: String,
        rank: Double?,
        reviewStatus: MemoryReviewStatus = .approved
    ) {
        self.memoryID = memoryID
        self.projectID = projectID
        self.kind = kind
        self.scope = scope
        self.confidence = confidence
        self.bodyRedacted = bodyRedacted
        self.tags = tags
        self.sourcePath = sourcePath
        self.snippet = snippet
        self.rank = rank
        self.reviewStatus = reviewStatus
    }

    private enum CodingKeys: String, CodingKey {
        case memoryID, projectID, kind, scope, confidence, bodyRedacted, tags, sourcePath, snippet, rank, reviewStatus
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.memoryID = try values.decode(String.self, forKey: .memoryID)
        self.projectID = try values.decode(String.self, forKey: .projectID)
        self.kind = try values.decode(String.self, forKey: .kind)
        self.scope = try values.decode(String.self, forKey: .scope)
        self.confidence = try values.decode(Double.self, forKey: .confidence)
        self.bodyRedacted = try values.decode(String.self, forKey: .bodyRedacted)
        self.tags = try values.decode([String].self, forKey: .tags)
        self.sourcePath = try values.decodeIfPresent(String.self, forKey: .sourcePath)
        self.snippet = try values.decode(String.self, forKey: .snippet)
        self.rank = try values.decodeIfPresent(Double.self, forKey: .rank)
        self.reviewStatus = try values.decodeIfPresent(MemoryReviewStatus.self, forKey: .reviewStatus) ?? .approved
    }
}

/// Durable review transition for an existing memory authority record. The daemon
/// owns this state; renderers never persist a decision locally.
public struct BurnBarProjectMemoryReviewStatusRequest: Codable, Hashable, Sendable {
    public let memoryID: String
    public let projectPath: String?
    public let status: MemoryReviewStatus

    public init(memoryID: String, projectPath: String? = nil, status: MemoryReviewStatus) {
        self.memoryID = memoryID
        self.projectPath = projectPath
        self.status = status
    }
}

public struct BurnBarProjectMemoryReviewStatusResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let memoryID: String
    public let status: MemoryReviewStatus
    public let auditHash: String

    public init(traceID: String, projectID: String, memoryID: String, status: MemoryReviewStatus, auditHash: String) {
        self.traceID = traceID
        self.projectID = projectID
        self.memoryID = memoryID
        self.status = status
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectMemoryRecallResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let hits: [BurnBarProjectMemoryHit]

    public init(traceID: String, projectID: String, hits: [BurnBarProjectMemoryHit]) {
        self.traceID = traceID
        self.projectID = projectID
        self.hits = hits
    }
}

public struct BurnBarProjectMemoryForgetRequest: Codable, Hashable, Sendable {
    public let memoryID: String
    public let projectPath: String?
    public let requireCloudDelete: Bool

    public init(memoryID: String, projectPath: String? = nil, requireCloudDelete: Bool = false) {
        self.memoryID = memoryID
        self.projectPath = projectPath
        self.requireCloudDelete = requireCloudDelete
    }
}

public struct BurnBarProjectMemoryForgetResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let memoryID: String
    public let localDeleted: Bool
    public let cloudDeletePending: Bool
    public let auditHash: String

    public init(
        traceID: String,
        projectID: String,
        memoryID: String,
        localDeleted: Bool,
        cloudDeletePending: Bool,
        auditHash: String
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.memoryID = memoryID
        self.localDeleted = localDeleted
        self.cloudDeletePending = cloudDeletePending
        self.auditHash = auditHash
    }
}

public struct BurnBarProjectMemoryAuditTrailRequest: Codable, Hashable, Sendable {
    public let projectPath: String?
    public let limit: Int

    public init(projectPath: String? = nil, limit: Int = 50) {
        self.projectPath = projectPath
        self.limit = limit
    }
}

public struct BurnBarProjectMemoryAuditEvent: Codable, Hashable, Sendable {
    public let seq: Int64
    public let ts: String
    public let actor: String
    public let action: String
    public let domain: String
    public let projectID: String?
    public let subjectID: String?
    public let labels: [String]
    public let prevHash: String?
    public let hash: String

    public init(
        seq: Int64,
        ts: String,
        actor: String,
        action: String,
        domain: String,
        projectID: String?,
        subjectID: String?,
        labels: [String],
        prevHash: String?,
        hash: String
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
}

public struct BurnBarProjectMemoryAuditTrailResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let events: [BurnBarProjectMemoryAuditEvent]

    public init(traceID: String, projectID: String, events: [BurnBarProjectMemoryAuditEvent]) {
        self.traceID = traceID
        self.projectID = projectID
        self.events = events
    }
}

public struct BurnBarProjectMemoryAnalyticsRequest: Codable, Hashable, Sendable {
    public let projectPath: String?

    public init(projectPath: String? = nil) {
        self.projectPath = projectPath
    }
}

public struct BurnBarProjectMemoryAnalyticsResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let projectID: String
    public let total: Int
    public let byKind: [String: Int]
    public let byScope: [String: Int]
    public let lastAuditHash: String?

    public init(
        traceID: String,
        projectID: String,
        total: Int,
        byKind: [String: Int],
        byScope: [String: Int],
        lastAuditHash: String?
    ) {
        self.traceID = traceID
        self.projectID = projectID
        self.total = total
        self.byKind = byKind
        self.byScope = byScope
        self.lastAuditHash = lastAuditHash
    }
}

// MARK: - Memory Blind Sync inbox (PR-2)

/// Where the app records "which member is signed in, and is device sync
/// consented right now" so the daemon can ENFORCE the inbox's user scope
/// instead of documenting it.
///
/// The daemon holds no Firebase identity and the Memory MCP engine has no uid,
/// so before this marker existed the drain could only ever hand over "whatever
/// is unmerged" and trust the app to have purged foreign rows first. That trust
/// is established inside a gated path whose consumers are ungated, which is not
/// a boundary. The marker turns the invariant into a predicate both sides can
/// evaluate.
///
/// It rides on `remote_sync_watermarks` — the control plane's existing
/// per-account sync-state table, already keyed `(accountUid, collectionKind)`
/// and already read by this very feature for the pull cursor — under a
/// collection kind that names no real collection. Reusing it is deliberate: a
/// dedicated table would be a new SQLite migration across all eight schema
/// surfaces for one row.
///
/// **Presence, and freshness, are consent.** Exactly one row exists while the
/// effective device-sync gate is open, and its `accountUid` is the signed-in
/// member. The app deletes it the instant any lever closes (sign-out, uid
/// change, the sub-toggle off, the backup opt-in off, a lapsed entitlement) and
/// rewrites it on every consenting sync, so the daemon reads absence — or a
/// `refreshedAtColumn` no sync has advanced inside
/// `BurnBarProjectCodeMemoryStore.deviceSyncConsentMarkerMaxAge` — as "no
/// consent" and returns nothing. Anything ambiguous — the table missing, no row,
/// more than one row, an unreadable stamp — is also nothing (fail closed).
public enum BurnBarMemoryDeviceSyncMarker: Sendable {
    /// The table the marker row lives in. Created by the app's `v30` migration;
    /// the daemon only ever reads it, and treats its absence as "no consent".
    public static let tableName = "remote_sync_watermarks"
    /// The `collectionKind` value that makes a row a marker rather than a
    /// watermark. Deliberately not a `RemoteSyncCollectionKind` case: nothing
    /// syncs a collection by this name, and the sync code must never iterate it.
    public static let collectionKind = "memory_facts_device_sync_marker"
    /// The account column, as the app's migration spells it.
    public static let accountColumn = "accountUid"
    /// The kind column, as the app's migration spells it.
    public static let kindColumn = "collectionKind"
    /// The column carrying "when did a consenting sync last vouch for this".
    ///
    /// The app REWRITES the marker row (delete + insert) on every consenting
    /// cycle, so this advances on the refresh cadence for as long as consent
    /// stands and stops the instant it does not. That is what lets the daemon
    /// age-bound the marker: presence alone cannot expire, and the daemon
    /// outlives the app, so a marker left behind by an app that quit after a
    /// sign-out would otherwise authorise drains for ever. See
    /// `BurnBarProjectCodeMemoryStore.deviceSyncConsentMarkerMaxAge`.
    public static let refreshedAtColumn = "lastSyncedAt"

    /// How often the APP rewrites the marker while consent stands.
    ///
    /// Deliberately NOT the app's refresh cadence. `BehaviorSettings.refreshInterval`
    /// defaults to 600 s but the Settings UI permits up to 15 minutes, and
    /// `BackgroundCadenceCoordinator` stretches it 5x while the app is inactive
    /// — which a menu-bar app normally is. A marker tied to that cadence could
    /// therefore go 75 minutes without a refresh while consent was fully
    /// granted, and the daemon would read a stale marker as "no consent" and
    /// return an empty inbox for most of every cycle. The feature would look
    /// broken while every switch said it was on.
    ///
    /// So `MemoryCloudSyncDomain` runs the marker on its OWN fixed timer at this
    /// interval, independent of the refresh cadence and of the background
    /// coordinator, doing only the gate read + enforce — never an upload or a
    /// pull. Five minutes: cheap (one main-actor hop and one row write) and well
    /// inside `maxAge` below even after several missed beats.
    public static let refreshInterval: TimeInterval = 300

    /// How long the DAEMON honours a marker no refresh has touched.
    ///
    /// Four refresh intervals — 20 minutes. Presence alone cannot expire and the
    /// daemon outlives the app, so a marker left behind by an app that quit
    /// after a sign-out would otherwise authorise drains for ever. Three missed
    /// beats are tolerated (a slow cycle, a sleeping Mac catching up); the
    /// fourth is read as "no app is vouching for this any more" and the drain
    /// falls closed. Expressed as a multiple of `refreshInterval` on purpose:
    /// the two numbers are one contract between two processes, and a bound that
    /// silently stopped being a multiple of the cadence is exactly the bug this
    /// pairing exists to prevent.
    public static let maxAge: TimeInterval = 4 * refreshInterval
}

/// Drain request for memory facts the app's pull lane verified and parked in
/// `agent_memory_inbox`. The engine calls this, merges what it gets under §5 of
/// the blind-sync design, then acknowledges the doc ids it applied.
public struct BurnBarMemorySyncInboxListRequest: Codable, Hashable, Sendable {
    /// Accepted for symmetry with the other memory RPCs and for the audit trace.
    /// It deliberately does NOT narrow the result: an engine memory id is globally
    /// unique and carries no project, so the inbox is user-scoped, not
    /// project-scoped.
    public let projectID: String?
    public let limit: Int

    public init(projectID: String? = nil, limit: Int = 200) {
        self.projectID = projectID
        self.limit = limit
    }
}

/// One verified remote fact awaiting merge. `payloadJSON` is the plaintext the
/// app opened from the member's own sealed document — it never left SQLCipher
/// except across the local unix socket the engine already uses.
public struct BurnBarMemorySyncInboxEntry: Codable, Hashable, Sendable {
    public let docID: String
    /// The account the fact was pulled under. Every entry the drain returns has
    /// already been filtered to the member named by
    /// `BurnBarMemoryDeviceSyncMarker` — the daemon holds no Firebase identity,
    /// so the app publishes that member and the daemon enforces it — and it
    /// travels so the engine can AUDIT which member a row belongs to.
    public let userID: String
    public let engineMemoryID: String
    public let payloadJSON: String
    public let remoteUpdatedAt: String

    public init(
        docID: String,
        userID: String,
        engineMemoryID: String,
        payloadJSON: String,
        remoteUpdatedAt: String
    ) {
        self.docID = docID
        self.userID = userID
        self.engineMemoryID = engineMemoryID
        self.payloadJSON = payloadJSON
        self.remoteUpdatedAt = remoteUpdatedAt
    }
}

public struct BurnBarMemorySyncInboxListResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let entries: [BurnBarMemorySyncInboxEntry]

    public init(traceID: String, entries: [BurnBarMemorySyncInboxEntry]) {
        self.traceID = traceID
        self.entries = entries
    }
}

/// Marks the named documents merged. Idempotent: acknowledging a doc id twice,
/// or one that was never parked, changes nothing.
public struct BurnBarMemorySyncInboxAckRequest: Codable, Hashable, Sendable {
    public let docIDs: [String]

    public init(docIDs: [String]) {
        self.docIDs = docIDs
    }
}

public struct BurnBarMemorySyncInboxAckResponse: Codable, Hashable, Sendable {
    public let traceID: String
    public let acknowledged: Int

    public init(traceID: String, acknowledged: Int) {
        self.traceID = traceID
        self.acknowledged = acknowledged
    }
}
