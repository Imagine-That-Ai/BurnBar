import Foundation
@preconcurrency import GRDB
import OpenBurnBarKernel

// MARK: - One memory's timeline, from the APP's own audit ledger

/// What a timeline read is reading. Carried on every record so a reader can
/// never mistake this for the engine's `memory_history`.
///
/// The engine (`memory_engine/_read.py`) serves a timeline of REVISION BODIES —
/// `before` / `after` decrypted out of its own store under its own AAD. That
/// store is `openburnbar-memory.sqlite`, no Swift process reads it, and none
/// should. What the app holds instead is `memory_audit`: a hash-chained ledger
/// of WHAT HAPPENED to a memory (added, updated, approved, rejected, merged,
/// superseded, deleted) with no revision contents at all. Those are two
/// different histories that answer two different questions, so the record says
/// which one it is.
enum MemoryTimelineSource {
    /// The app's `memory_audit` ledger. Never the engine's revision bodies.
    static let appAudit = "app_audit"
}

/// One memory's timeline as the app can honestly serve it.
///
/// Field names are the ENGINE'S (`status`, `code`, `memoryID`, `revisions`,
/// `seq`, `event`, `actor`, `ts`, `meta`, `writerDevice`, `lastHelpedAt`,
/// `lastHelpedSource`) so a future daemon-forwarded engine timeline can feed the
/// same view without renaming anything — plus `source`, which says whose
/// timeline this is.
struct MemoryTimelineRecord: Equatable, Sendable {
    /// The read succeeded and the memory is known here.
    static let statusOK = "ok"
    /// Nothing in this database knows that id: no audit row, no authority row.
    /// Deliberately distinct from an `ok` read with zero revisions, which means
    /// "known, but nothing has happened to it yet".
    static let statusNotFound = "not_found"
    /// The engine's third status. The app never produces it — it has no
    /// cross-project scope to refuse — but the shape carries it so a forwarded
    /// engine read decodes into the same record.
    static let statusRefused = "refused"
    /// The only `lastHelpedSource` this ledger can justify. The engine also
    /// serves `"recall_serve"`, from a recall-serve table the app does not have;
    /// claiming it here would assert a recall that was never recorded.
    static let lastHelpedSourceHistory = "history"

    /// One thing that happened to the memory.
    struct Revision: Equatable, Sendable, Identifiable {
        let seq: Int
        /// `memory_audit.action`, verbatim (`memory.add`, `memory.approve`, …).
        /// The engine calls this member `event`; the app's column is `action`.
        let event: String
        let actor: String
        let ts: String
        /// ALWAYS nil. `memory_audit` records that a memory changed, never what
        /// it changed from or to — see `revisionBodiesRetained`.
        let before: String?
        /// ALWAYS nil, for the same reason as `before`.
        let after: String?
        /// The audit row's own context: its domain, project, and the labels the
        /// writer attached. The engine's `meta` is a free-form dict; so is this.
        let meta: [String: String]
        /// ALWAYS nil on an app-audit revision. `memory_audit` carries no
        /// per-event device: every row in it was written by THIS device. The one
        /// device fact the app does record — which device a synced memory
        /// arrived from — is a property of the memory, not of an event, and
        /// lives on `writerDevice` below.
        let writerDevice: String?

        var id: Int { seq }
    }

    let status: String
    /// Set only on a refusal, which the app never produces.
    let code: String?
    let memoryID: String
    let revisions: [Revision]
    let lastHelpedAt: String?
    let lastHelpedSource: String?
    /// `agent_memories.valid_from` — when this memory started being true.
    let validFrom: String?
    /// `agent_memories.valid_to` — when it stopped, if it has.
    let validTo: String?
    /// `agent_memories.superseded_by` — the memory that replaced it.
    let supersededBy: String?
    /// The device a synced-in memory was written on, read from the parked cloud
    /// payload in `agent_memory_inbox` (joined to this memory through
    /// `agent_memory_bodies.engine_memory_id`). Nil for a memory this device
    /// learned itself, and nil when the payload names no device.
    let writerDevice: String?
    /// Which history this is. Always `MemoryTimelineSource.appAudit` here.
    let source: String
    /// ALWAYS false: this ledger does not retain revision contents, and the view
    /// says so rather than letting empty `before`/`after` read as "unchanged".
    let revisionBodiesRetained: Bool

    init(
        status: String,
        code: String? = nil,
        memoryID: String,
        revisions: [Revision] = [],
        lastHelpedAt: String? = nil,
        lastHelpedSource: String? = nil,
        validFrom: String? = nil,
        validTo: String? = nil,
        supersededBy: String? = nil,
        writerDevice: String? = nil,
        source: String = MemoryTimelineSource.appAudit,
        revisionBodiesRetained: Bool = false
    ) {
        self.status = status
        self.code = code
        self.memoryID = memoryID
        self.revisions = revisions
        self.lastHelpedAt = lastHelpedAt
        self.lastHelpedSource = lastHelpedSource
        self.validFrom = validFrom
        self.validTo = validTo
        self.supersededBy = supersededBy
        self.writerDevice = writerDevice
        self.source = source
        self.revisionBodiesRetained = revisionBodiesRetained
    }
}

/// A timeline read that could not run at all.
///
/// The distinction this type exists to keep: a database that cannot answer
/// (`memory_audit` absent, a corrupt schema, a failed decrypt) is NOT a memory
/// with no history. Rendering the first as the second would tell the member
/// their memory has never been touched, on the strength of a broken read.
enum MemoryTimelineError: LocalizedError, Equatable {
    case historyUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .historyUnavailable(let detail):
            "History unavailable — \(detail)"
        }
    }
}

extension ControlPlaneStore {

    /// Reads one memory's timeline out of the app's shared audit ledger.
    ///
    /// Sources, in the order they are read:
    ///   * `memory_audit WHERE subject_id = ? ORDER BY seq ASC LIMIT ?` — the
    ///     ordered events, hash-chained by the writer.
    ///   * `agent_memories` — the lineage (`valid_from`, `valid_to`,
    ///     `superseded_by`) and the proof the id is known at all.
    ///   * `agent_memory_inbox.payload_json`, joined through
    ///     `agent_memory_bodies.engine_memory_id` — the device a synced-in
    ///     memory was written on.
    ///
    /// Failures are failures: any read error becomes
    /// `MemoryTimelineError.historyUnavailable` rather than an empty timeline.
    /// An id no table knows is `not_found`, which is not the same as an `ok`
    /// read with no events.
    func memoryTimeline(memoryID: MemoryID, limit: Int = 500) async throws -> MemoryTimelineRecord {
        let cappedLimit = max(1, min(limit, 500))
        do {
            return try await dbQueue.read { db -> MemoryTimelineRecord in
                let auditRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT seq, ts, actor, action, domain, project_id, labels_json
                    FROM memory_audit
                    WHERE subject_id = ?
                    ORDER BY seq ASC
                    LIMIT ?
                    """,
                    arguments: [memoryID, cappedLimit]
                )

                let lineage = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT valid_from, valid_to, superseded_by
                    FROM agent_memories
                    WHERE id = ?
                    LIMIT 1
                    """,
                    arguments: [memoryID]
                )

                guard auditRows.isEmpty == false || lineage != nil else {
                    return MemoryTimelineRecord(
                        status: MemoryTimelineRecord.statusNotFound,
                        memoryID: memoryID
                    )
                }

                let inboundPayload = try String.fetchOne(
                    db,
                    sql: """
                    SELECT inbox.payload_json
                    FROM agent_memory_inbox AS inbox
                    JOIN agent_memory_bodies AS bodies
                        ON bodies.engine_memory_id = inbox.engine_memory_id
                    WHERE bodies.memory_id = ?
                    ORDER BY inbox.remote_updated_at DESC
                    LIMIT 1
                    """,
                    arguments: [memoryID]
                )

                let validFrom: String? = lineage?["valid_from"]
                let validTo: String? = lineage?["valid_to"]
                let supersededBy: String? = lineage?["superseded_by"]
                let revisions = auditRows.map(Self.timelineRevision(from:))
                // "Last helped" over this ledger can only mean "last recorded
                // event", and its source is therefore the history — never the
                // recall-serve table the app does not keep.
                let lastEvent = revisions.last
                return MemoryTimelineRecord(
                    status: MemoryTimelineRecord.statusOK,
                    memoryID: memoryID,
                    revisions: revisions,
                    lastHelpedAt: lastEvent?.ts,
                    lastHelpedSource: lastEvent == nil
                        ? nil
                        : MemoryTimelineRecord.lastHelpedSourceHistory,
                    validFrom: validFrom,
                    validTo: validTo,
                    supersededBy: supersededBy,
                    writerDevice: inboundPayload.flatMap(Self.writerDevice(inPayloadJSON:))
                )
            }
        } catch {
            throw MemoryTimelineError.historyUnavailable(error.localizedDescription)
        }
    }

    // MARK: - Row mapping

    private static func timelineRevision(from row: Row) -> MemoryTimelineRecord.Revision {
        var meta: [String: String] = [:]
        if let domain: String = row["domain"] { meta["domain"] = domain }
        if let projectID: String = row["project_id"] { meta["projectID"] = projectID }
        if let labelsJSON: String = row["labels_json"] {
            let labels = decodedAuditLabels(labelsJSON)
            if labels.isEmpty == false { meta["labels"] = labels.joined(separator: ", ") }
        }
        return MemoryTimelineRecord.Revision(
            seq: row["seq"] ?? 0,
            event: row["action"] ?? "",
            actor: row["actor"] ?? "",
            ts: row["ts"] ?? "",
            before: nil,
            after: nil,
            meta: meta,
            writerDevice: nil
        )
    }

    /// `labels_json` is written by `insertMemoryAuditEvent` as a sorted JSON
    /// array of strings. A row this cannot parse contributes no labels rather
    /// than failing the whole timeline: the labels are context, not the history.
    private static func decodedAuditLabels(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            AppLogger.dataStore.silentFailure("Unparseable memory_audit labels_json", error: error)
            return []
        }
    }

    /// Pulls the writing device out of a parked cloud payload, accepting each
    /// spelling the engine's own meta lookup accepts.
    private static func writerDevice(inPayloadJSON json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            AppLogger.dataStore.silentFailure("Unparseable agent_memory_inbox payload_json", error: error)
            return nil
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in ["writerDevice", "writer_device", "deviceId", "device_id"] {
            if let value = dictionary[key] as? String,
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return value
            }
        }
        return nil
    }
}
