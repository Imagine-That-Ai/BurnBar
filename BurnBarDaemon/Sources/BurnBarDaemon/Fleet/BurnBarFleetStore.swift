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
    public let databasePath: String
    public let eventRetentionSeconds: TimeInterval
    public let snapshotRetentionCount: Int

    private var queue: DatabaseQueue?
    private var health: BurnBarFleetPersistenceHealth = .ok
    /// Rebuild degradation that must remain visible on the FIRST published
    /// snapshot after a delete+recreate (served via RPC, written to
    /// fleet-snapshot.json, persisted to fleet_snapshots) and clear only on
    /// the NEXT successful persist after that publication (VAL-HARD-012/013).
    private var pendingRebuildHealth: BurnBarFleetPersistenceHealth?

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
            let rebuildHealth = BurnBarFleetPersistenceHealth.degraded(
                reason: BurnBarFleetPersistenceReason.storeRebuilt("recreated after corruption")
            )
            health = rebuildHealth
            // The rebuild window spans the first published recovery snapshot:
            // it must be visible on that snapshot (RPC + file + store row) and
            // clear only on the next successful persist after publication.
            pendingRebuildHealth = rebuildHealth
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
        // The pending rebuild window is part of the current health until the
        // first published recovery snapshot has been persisted.
        if let pendingRebuildHealth {
            return pendingRebuildHealth
        }
        return health
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
    /// configured cadence — never re-stamped). The snapshot insert and the
    /// retention pruning run in ONE transaction. Older snapshots are pruned
    /// to `snapshotRetentionCount` and events older than the retention window
    /// are pruned in the same transaction. Returns the persisted snapshot's
    /// decoded form (equal to the input).
    ///
    /// Rebuild-window semantics: the first successful persist after a
    /// delete+recreate publishes the recovery snapshot (the caller embeds
    /// the pending rebuild health in it); the rebuild degradation clears on
    /// the NEXT successful persist after that publication.
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
        if pendingRebuildHealth != nil {
            // The recovery snapshot has now been published (persisted with
            // the rebuild health embedded). The window closes after this
            // persist; the next successful persist reports the store's
            // normal health.
            pendingRebuildHealth = nil
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

    /// Records the transition events for one roster row between a previous
    /// snapshot and the current one (fixed-roster model):
    /// - `status_changed` is ALWAYS recorded for a status change, with exact
    ///   agent/from/to values (detail: "status: <from> -> <to>").
    /// - `confidence_changed` is recorded when confidence changes, with exact
    ///   agent/from/to values (detail: "confidence: <from> -> <to>").
    /// A fixed-roster row is never removed, so `appeared`/`disappeared` are
    /// never produced.
    ///
    /// The events are inserted in the SAME transaction as the snapshot
    /// persist (see `persistLatestSnapshot`), so a failed persist never
    /// advances the transition baseline and never loses a transition.
    public func recordTransition(
        agentID: BurnBarFleetAgentID,
        fromStatus: BurnBarFleetAgentStatus?,
        toStatus: BurnBarFleetAgentStatus,
        fromConfidence: BurnBarFleetConfidence?,
        toConfidence: BurnBarFleetConfidence,
        at: Date
    ) throws {
        guard let queue else { return }
        let transition = BurnBarFleetTransition(
            agentID: agentID,
            fromStatus: fromStatus,
            toStatus: toStatus,
            fromConfidence: fromConfidence,
            toConfidence: toConfidence,
            at: at
        )
        try queue.write { db in
            try Self.insertTransition(transition, into: db)
        }
    }

    /// Persists the latest completed snapshot AND its fixed-roster transition
    /// events in ONE transaction (snapshot insert, event inserts, and
    /// retention pruning). The persister uses this so the transition
    /// baseline can advance only when the store write AND the event
    /// insertion succeed — a failed persist never loses a later transition
    /// event. Returns the persisted snapshot's decoded form (equal to the
    /// input).
    ///
    /// Rebuild-window semantics: the first successful persist after a
    /// delete+recreate publishes the recovery snapshot (the caller embeds
    /// the pending rebuild health in it); the rebuild degradation clears on
    /// the NEXT successful persist after that publication.
    @discardableResult
    public func persistSnapshotAndTransitions(
        _ snapshot: BurnBarFleetSnapshot,
        transitions: [BurnBarFleetTransition]
    ) throws -> BurnBarFleetSnapshot {
        guard let queue else { throw BurnBarFleetPersistenceError.storeNotOpen }

        let payload = try Self.encodeSnapshot(snapshot)
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO fleet_snapshots (generated_at, payload) VALUES (?, ?)",
                arguments: [snapshot.generatedAt.timeIntervalSince1970, payload]
            )
            for transition in transitions {
                try Self.insertTransition(transition, into: db)
            }
            try db.execute(
                sql: """
                    DELETE FROM fleet_snapshots WHERE id NOT IN
                    (SELECT id FROM fleet_snapshots ORDER BY id DESC LIMIT ?)
                    """,
                arguments: [snapshotRetentionCount]
            )
            try db.execute(
                sql: "DELETE FROM fleet_events WHERE at < ?",
                arguments: [Date().addingTimeInterval(-eventRetentionSeconds).timeIntervalSince1970]
            )
        }
        if pendingRebuildHealth != nil {
            // The recovery snapshot has now been published (persisted with
            // the rebuild health embedded). The window closes after this
            // persist; the next successful persist reports the store's
            // normal health.
            pendingRebuildHealth = nil
        }
        health = .ok
        return snapshot
    }

    /// Inserts the `status_changed` (when status differs) and
    /// `confidence_changed` (when confidence differs) events for one
    /// transition. Shared by the single-transition and the atomic
    /// snapshot+transitions paths so both record identical rows.
    private static func insertTransition(_ transition: BurnBarFleetTransition, into db: Database) throws {
        if let fromStatus = transition.fromStatus, fromStatus != transition.toStatus {
            try db.execute(
                sql: """
                    INSERT INTO fleet_events (at, agent, kind, from_status, to_status, detail)
                    VALUES (?, ?, 'status_changed', ?, ?, ?)
                    """,
                arguments: [
                    transition.at.timeIntervalSince1970,
                    transition.agentID.wireValue,
                    fromStatus.rawValue,
                    transition.toStatus.rawValue,
                    "status: \(fromStatus.rawValue) -> \(transition.toStatus.rawValue)"
                ]
            )
        }
        if let fromConfidence = transition.fromConfidence, fromConfidence != transition.toConfidence {
            try db.execute(
                sql: """
                    INSERT INTO fleet_events (at, agent, kind, from_status, to_status, detail)
                    VALUES (?, ?, 'confidence_changed', ?, ?, ?)
                    """,
                arguments: [
                    transition.at.timeIntervalSince1970,
                    transition.agentID.wireValue,
                    fromConfidence.rawValue,
                    transition.toConfidence.rawValue,
                    "confidence: \(fromConfidence.rawValue) -> \(transition.toConfidence.rawValue)"
                ]
            )
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

    // MARK: - Orchestrator state (M4)

    /// True once the store has been opened (migrated). The control store uses
    /// this to distinguish "not open yet" (retry on next access) from an
    /// open store with no persisted state.
    public var isOpen: Bool {
        queue != nil
    }

    /// The persisted orchestrator-state payload (the JSON of the last
    /// `BurnBarOrchestratorState` written), or nil when no state row exists.
    /// The single-row contract (`id = 1`) means at most one row can exist.
    public func orchestratorStatePayload() throws -> String? {
        guard let queue else { return nil }
        return try queue.read { db in
            try String.fetchOne(db, sql: "SELECT payload FROM orchestrator_state WHERE id = 1")
        }
    }

    /// Upserts the orchestrator-state row (`id = 1`, single row contract).
    /// Replaces any prior state — the designation overwrite semantics (M4,
    /// ORCH-017) live in the control store, which calls this per accepted set.
    public func setOrchestratorState(payload: String) throws {
        guard let queue else { throw BurnBarFleetPersistenceError.storeNotOpen }
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO orchestrator_state (id, payload) VALUES (1, ?) "
                    + "ON CONFLICT(id) DO UPDATE SET payload = excluded.payload",
                arguments: [payload]
            )
        }
    }

    public func orchestratorStateRowCount() throws -> Int {
        guard let queue else { return 0 }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM orchestrator_state") ?? 0
        }
    }

    // MARK: - Directive records (M4)

    /// All directive records, oldest first. There is NO directive-list RPC by
    /// design: validators read `fleet_directives` with read-only sqlite3.
    public func directiveRecords() throws -> [BurnBarFleetDirective] {
        guard let queue else { return [] }
        return try queue.read { db in
            let payloads = try String.fetchAll(
                db,
                sql: "SELECT payload FROM fleet_directives ORDER BY id ASC"
            )
            return try payloads.map { payload in
                guard let data = payload.data(using: .utf8) else {
                    throw BurnBarFleetPersistenceError.payloadDecodingFailed
                }
                return try JSONDecoder().decode(BurnBarFleetDirective.self, from: data)
            }
        }
    }

    /// Returns one directive record by its stable directive id without
    /// decoding the full directive history.
    public func directiveRecord(id: String) throws -> BurnBarFleetDirective? {
        guard let queue else { return nil }
        return try queue.read { db in
            guard let payload = try String.fetchOne(
                db,
                sql: "SELECT payload FROM fleet_directives WHERE directive_id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            guard let data = payload.data(using: .utf8) else {
                throw BurnBarFleetPersistenceError.payloadDecodingFailed
            }
            return try JSONDecoder().decode(BurnBarFleetDirective.self, from: data)
        }
    }

    /// Upserts one directive record keyed by `directive_id` (UNIQUE). The M4
    /// idempotency rule: re-recording an existing id updates the record in
    /// place — a retry never creates a duplicate row.
    public func upsertDirective(_ directive: BurnBarFleetDirective) throws {
        guard let queue else { throw BurnBarFleetPersistenceError.storeNotOpen }
        let encoder = JSONEncoder()
        let data = try encoder.encode(directive)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw BurnBarFleetPersistenceError.payloadEncodingFailed
        }
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO fleet_directives (directive_id, payload, created_at) VALUES (?, ?, ?) "
                    + "ON CONFLICT(directive_id) DO UPDATE SET payload = excluded.payload, "
                    + "created_at = excluded.created_at",
                arguments: [directive.id, payload, directive.createdAt.timeIntervalSince1970]
            )
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

/// One fixed-roster transition to record atomically with the snapshot
/// persist (status_changed always; confidence_changed when confidence
/// changes). The persister derives these from the previous persisted
/// snapshot and the current one.
public struct BurnBarFleetTransition: Sendable {
    public let agentID: BurnBarFleetAgentID
    public let fromStatus: BurnBarFleetAgentStatus?
    public let toStatus: BurnBarFleetAgentStatus
    public let fromConfidence: BurnBarFleetConfidence?
    public let toConfidence: BurnBarFleetConfidence
    public let at: Date

    public init(
        agentID: BurnBarFleetAgentID,
        fromStatus: BurnBarFleetAgentStatus?,
        toStatus: BurnBarFleetAgentStatus,
        fromConfidence: BurnBarFleetConfidence?,
        toConfidence: BurnBarFleetConfidence,
        at: Date
    ) {
        self.agentID = agentID
        self.fromStatus = fromStatus
        self.toStatus = toStatus
        self.fromConfidence = fromConfidence
        self.toConfidence = toConfidence
        self.at = at
    }
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
