import BurnBarCore
import Foundation
import GRDB

/// Daemon-owned fleet persistence in `fleet.sqlite` (GRDB; no new dependency).
///
/// Schema (architecture §6):
/// - `fleet_snapshots(id INTEGER PK AUTOINCREMENT, generated_at REAL, payload TEXT)` —
///   the latest completed snapshot JSON, pruned to the retention count.
/// - `fleet_events(id INTEGER PK AUTOINCREMENT, at REAL, agent TEXT, kind TEXT,
///   from_status TEXT, to_status TEXT, detail TEXT)` — fixed-roster transition
///   events (`status_changed` always; `confidence_changed` when confidence
///   changes), pruned to exactly 24h by default and testable through the
///   `BURNBAR_FLEET_EVENT_RETENTION_SECONDS` seam.
/// - `orchestrator_state(id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT)` —
///   schema only in M1; behavior lands in M4.
/// - `fleet_directives(id INTEGER PK AUTOINCREMENT, directive_id TEXT UNIQUE,
///   payload TEXT, created_at REAL)` — schema only in M1; behavior lands in M4.
///
/// Model declaration: **fixed-roster rows**. The ten declared agents are never
/// removed from snapshots; status/confidence transitions carry exact
/// agent/from/to values. `appeared`/`disappeared` events are NOT produced —
/// they are reserved for a documented dynamic session-row model, which this
/// implementation does not use.
///
/// Rebuild semantics (invariant 6): the live projection always rebuilds from
/// probes. Store corruption is detected, the store is deleted + recreated,
/// and the recovery is surfaced through `persistenceHealth: degraded(reason)`
/// (reason `storeRebuilt`) until the next successful persist. Store deletion
/// discards daemon-owned orchestration history and re-initializes designation
/// to `none` — disclosed in `docs/fleet/BURNBAR_FLEET_SIGNALS.md`.
public final class BurnBarFleetStore {
    public struct Health: Equatable, Sendable {
        public var persistenceHealth: BurnBarFleetPersistenceHealth
    }

    public let databasePath: String
    public let eventRetentionSeconds: TimeInterval
    public let snapshotRetentionCount: Int

    private var queue: DatabaseQueue?
    private var health: BurnBarFleetPersistenceHealth = .ok

    public init(
        databasePath: String,
        eventRetentionSeconds: TimeInterval = BurnBarFleetPersistenceConstants.defaultEventRetentionSeconds,
        snapshotRetentionCount: Int = BurnBarFleetPersistenceConstants.defaultSnapshotRetentionCount
    ) {
        self.databasePath = databasePath
        self.eventRetentionSeconds = eventRetentionSeconds
        self.snapshotRetentionCount = snapshotRetentionCount
    }

    // MARK: - Open / recover

    /// Opens (creating if needed) and migrates the store. Corruption is
    /// detected: the store is deleted + recreated and health becomes
    /// `degraded(storeRebuilt)` until the next successful persist — the
    /// daemon never crashes over a corrupt fleet store.
    @discardableResult
    public func open() throws -> BurnBarFleetPersistenceHealth {
        if queue != nil {
            // Already open (idempotent).
            return health
        }
        do {
            queue = try Self.openQueue(at: databasePath, migrate: true)
            return health
        } catch {
            guard Self.looksCorrupt(error) else {
                health = .degraded(reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)"))
                throw error
            }
            // Rebuild: delete + recreate. Deletion discards orchestration
            // history; the projection itself always rebuilds from probes.
            try? FileManager.default.removeItem(atPath: databasePath)
            do {
                queue = try Self.openQueue(at: databasePath, migrate: true)
            } catch {
                health = .degraded(reason: BurnBarFleetPersistenceReason.storeUnavailable("\(error)"))
                throw error
            }
            health = .degraded(reason: BurnBarFleetPersistenceReason.storeRebuilt("recreated after corruption"))
            return health
        }
    }

    /// Closes the store (used by tests; the daemon keeps the store open for
    /// its lifetime).
    public func close() {
        try? queue?.close()
        queue = nil
    }

    public func currentHealth() -> BurnBarFleetPersistenceHealth {
        health
    }

    private static func openQueue(at path: String, migrate: Bool) throws -> DatabaseQueue {
        let directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let queue = try DatabaseQueue(path: path)
        if migrate {
            try migrator.migrate(queue)
        }
        return queue
    }

    /// GRDB database error that indicates an unreadable/corrupt database file.
    private static func looksCorrupt(_ error: Error) -> Bool {
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_IOERR:
            return true
        default:
            return false
        }
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_fleet") { db in
            try db.create(table: "fleet_snapshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("generated_at", .double).notNull().indexed()
                t.column("payload", .text).notNull()
            }

            try db.create(table: "fleet_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .double).notNull().indexed()
                t.column("agent", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("from_status", .text)
                t.column("to_status", .text)
                t.column("detail", .text)
            }
            try db.create(index: "index_fleet_events_agent_at", on: "fleet_events", columns: ["agent", "at"])

            try db.create(table: "orchestrator_state") { t in
                t.column("id", .integer).primaryKey()
                t.check(sql: "id = 1")
                t.column("payload", .text).notNull()
            }

            try db.create(table: "fleet_directives") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("directive_id", .text).notNull().unique()
                t.column("payload", .text).notNull()
                t.column("created_at", .double).notNull()
            }
        }
        return migrator
    }

    // MARK: - Snapshots

    /// Persists the latest completed snapshot VERBATIM: the payload is the
    /// exact JSON of the served snapshot (its `cadenceSeconds` is already the
    /// configured cadence — never re-stamped). Older snapshots are pruned to
    /// `snapshotRetentionCount` and events older than the retention window
    /// are pruned in the same transaction. Returns the persisted snapshot's
    /// decoded form (equal to the input) and clears any rebuild degradation
    /// on success.
    @discardableResult
    public func persistLatestSnapshot(_ snapshot: BurnBarFleetSnapshot) throws -> BurnBarFleetSnapshot {
        guard let queue else { throw BurnBarFleetPersistenceError.storeNotOpen }

        let payload = try Self.encodeSnapshot(snapshot)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO fleet_snapshots (generated_at, payload) VALUES (?, ?)",
                arguments: [snapshot.generatedAt.timeIntervalSince1970, payload]
            )
            try db.execute(
                sql: "DELETE FROM fleet_snapshots WHERE id NOT IN (SELECT id FROM fleet_snapshots ORDER BY id DESC LIMIT ?)",
                arguments: [snapshotRetentionCount]
            )
            try db.execute(
                sql: "DELETE FROM fleet_events WHERE at < ?",
                arguments: [Date().addingTimeInterval(-eventRetentionSeconds).timeIntervalSince1970]
            )
        }
        health = .ok
        return snapshot
    }

    /// The latest completed snapshot from the store, or nil when none has
    /// been persisted.
    public func latestSnapshot() throws -> BurnBarFleetSnapshot? {
        guard let queue else { return nil }
        return try queue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT payload FROM fleet_snapshots ORDER BY id DESC LIMIT 1")
            else {
                return nil
            }
            let payload: String = row["payload"]
            return try Self.decodeSnapshot(payload)
        }
    }

    /// The raw JSON payload of the latest completed snapshot (verbatim string
    /// as persisted — the strongest "persist VERBATIM" assertion surface).
    public func latestSnapshotPayload() throws -> String? {
        guard let queue else { return nil }
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM fleet_snapshots ORDER BY id DESC LIMIT 1")
        }
    }

    // MARK: - Transition events

    /// Records the transition events for one roster row between a previous
    /// snapshot and the current one (fixed-roster model):
    /// - `status_changed` is ALWAYS recorded for a status change, with exact
    ///   agent/from/to values (detail: "status: <from> -> <to>").
    /// - `confidence_changed` is recorded when confidence changes, with exact
    ///   agent/from/to values (detail: "confidence: <from> -> <to>").
    /// A fixed-roster row is never removed, so `appeared`/`disappeared` are
    /// never produced.
    public func recordTransition(
        agentID: BurnBarFleetAgentID,
        fromStatus: BurnBarFleetAgentStatus?,
        toStatus: BurnBarFleetAgentStatus,
        fromConfidence: BurnBarFleetConfidence?,
        toConfidence: BurnBarFleetConfidence,
        at: Date
    ) throws {
        guard let queue else { return }
        try queue.write { db in
            if let fromStatus, fromStatus != toStatus {
                try db.execute(
                    sql: """
                        INSERT INTO fleet_events (at, agent, kind, from_status, to_status, detail)
                        VALUES (?, ?, 'status_changed', ?, ?, ?)
                        """,
                    arguments: [
                        at.timeIntervalSince1970,
                        agentID.wireValue,
                        fromStatus.rawValue,
                        toStatus.rawValue,
                        "status: \(fromStatus.rawValue) -> \(toStatus.rawValue)"
                    ]
                )
            }
            if let fromConfidence, fromConfidence != toConfidence {
                try db.execute(
                    sql: """
                        INSERT INTO fleet_events (at, agent, kind, from_status, to_status, detail)
                        VALUES (?, ?, 'confidence_changed', ?, ?, ?)
                        """,
                    arguments: [
                        at.timeIntervalSince1970,
                        agentID.wireValue,
                        fromConfidence.rawValue,
                        toConfidence.rawValue,
                        "confidence: \(fromConfidence.rawValue) -> \(toConfidence.rawValue)"
                    ]
                )
            }
        }
    }

    /// Prunes events older than `retentionSeconds` (used by the retention
    /// seam and invoked on every persist).
    @discardableResult
    public func pruneEvents(olderThan retentionSeconds: TimeInterval, now: Date = Date()) throws -> Int {
        guard let queue else { return 0 }
        let cutoff = now.addingTimeInterval(-retentionSeconds)
        return try queue.write { db in
            try db.execute(
                sql: "DELETE FROM fleet_events WHERE at < ?",
                arguments: [cutoff.timeIntervalSince1970]
            )
            return db.changesCount
        }
    }

    /// All events for an agent, ordered oldest first (test/validation view).
    public func events(for agentID: BurnBarFleetAgentID) throws -> [StoredFleetEvent] {
        guard let queue else { return [] }
        return try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT at, kind, from_status, to_status, detail FROM fleet_events WHERE agent = ? ORDER BY id ASC",
                arguments: [agentID.wireValue]
            )
            return rows.map { row in
                StoredFleetEvent(
                    at: Date(timeIntervalSince1970: row["at"]),
                    kind: row["kind"],
                    fromStatus: row["from_status"] as String?,
                    toStatus: row["to_status"] as String?,
                    detail: row["detail"] as String?
                )
            }
        }
    }

    // MARK: - Orchestrator / directives (schema only until M4)

    /// M4 lands orchestrator/directive behavior. This method exists so the
    /// schema-only tables are exercised (open + round-trip) without behavior.
    public func orchestratorStateRowCount() throws -> Int {
        guard let queue else { return 0 }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM orchestrator_state") ?? 0
        }
    }

    public func directiveRowCount() throws -> Int {
        guard let queue else { return 0 }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM fleet_directives") ?? 0
        }
    }

    // MARK: - JSON

    private static func encodeSnapshot(_ snapshot: BurnBarFleetSnapshot) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BurnBarFleetPersistenceError.payloadEncodingFailed
        }
        return string
    }

    private static func decodeSnapshot(_ payload: String) throws -> BurnBarFleetSnapshot {
        guard let data = payload.data(using: .utf8) else {
            throw BurnBarFleetPersistenceError.payloadDecodingFailed
        }
        return try JSONDecoder().decode(BurnBarFleetSnapshot.self, from: data)
    }
}

/// A stored fleet transition event (validation view).
public struct StoredFleetEvent: Equatable, Sendable {
    public let at: Date
    public let kind: String
    public let fromStatus: String?
    public let toStatus: String?
    public let detail: String?
}

public enum BurnBarFleetPersistenceError: Error, LocalizedError {
    case payloadEncodingFailed
    case payloadDecodingFailed
    case storeNotOpen

    public var errorDescription: String? {
        switch self {
        case .payloadEncodingFailed:
            return "Fleet snapshot payload could not be encoded to UTF-8 JSON."
        case .payloadDecodingFailed:
            return "Stored fleet snapshot payload could not be decoded."
        case .storeNotOpen:
            return "Fleet store is not open."
        }
    }
}
