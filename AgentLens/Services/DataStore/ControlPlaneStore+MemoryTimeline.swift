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
    /// The team space a synced-in memory was contributed to, and the account
    /// that contributed it — read from the SAME parked cloud payload as
    /// `writerDevice` (memory program D16 / P22). `TeamMemoryPullService` writes
    /// `teamID` and `authorUID` INSIDE `payloadJSON`, following the `entryKind`
    /// precedent, so no column and no migration exist for either. Both nil for a
    /// personal memory, which is what almost every memory is.
    let teamID: String?
    let authorUID: String?
    /// Which history this is. Always `MemoryTimelineSource.appAudit` here.
    let source: String
    /// ALWAYS false: this ledger does not retain revision contents, and the view
    /// says so rather than letting empty `before`/`after` read as "unchanged".
    let revisionBodiesRetained: Bool
    /// True when the read hit its cap and older events exist that are NOT in
    /// `revisions`. The window is a TAIL — the latest events — so `lastHelpedAt`
    /// is genuinely the last one; without this flag the view would still present
    /// a partial history as the whole history.
    let truncated: Bool

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
        teamID: String? = nil,
        authorUID: String? = nil,
        source: String = MemoryTimelineSource.appAudit,
        revisionBodiesRetained: Bool = false,
        truncated: Bool = false
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
        self.teamID = teamID
        self.authorUID = authorUID
        self.source = source
        self.revisionBodiesRetained = revisionBodiesRetained
        self.truncated = truncated
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

    /// The `memory_audit` namespace a MEMORY's history lives in. The ledger is
    /// shared: the daemon writes `domain = "code"` rows into the same table.
    static let memoryAuditDomain = "memory"

    /// How many events one timeline read returns unless asked for fewer.
    static let memoryTimelineDefaultLimit = 500

    /// The hard cap on a timeline read, whatever the caller asks for.
    static let memoryTimelineMaxLimit = 500

    /// The largest `agent_memory_inbox.payload_json` this read will deserialize.
    /// The rows are written by the app's own verified pull lane, so this is a
    /// robustness bound rather than an attack surface — and exceeding it costs
    /// only the arrival device, never the timeline.
    static let memoryTimelinePayloadByteLimit = 256 * 1024

    /// Reads one memory's timeline out of the app's shared audit ledger.
    ///
    /// Sources, in the order they are read:
    ///   * `memory_audit WHERE subject_id = ? AND domain = 'memory'`, newest
    ///     first and then reversed — the ordered events, hash-chained by the
    ///     writer, capped to the LATEST `limit` of them.
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
    func memoryTimeline(
        memoryID: MemoryID,
        userID: String? = nil,
        limit: Int = ControlPlaneStore.memoryTimelineDefaultLimit
    ) async throws -> MemoryTimelineRecord {
        let cappedLimit = max(1, min(limit, Self.memoryTimelineMaxLimit))
        do {
            return try await dbQueue.read { db -> MemoryTimelineRecord in
                // DESC + reverse, not ASC: a capped read must keep the LATEST
                // events, or `revisions.last` is the last row of the OLDEST page
                // and the header renders a stale timestamp as "last recorded".
                // One extra row is fetched purely to detect the cap.
                // `domain = 'memory'` is not decoration: `memory_audit` is a
                // multi-namespace ledger and the daemon writes `domain = 'code'`
                // rows into it with a different `subject_id` namespace
                // (artifact ids, and filesystem paths for `code.index`).
                let pagedRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT seq, ts, actor, action, domain, project_id, labels_json
                    FROM memory_audit
                    WHERE subject_id = ? AND domain = ?
                    ORDER BY seq DESC
                    LIMIT ?
                    """,
                    arguments: [memoryID, Self.memoryAuditDomain, cappedLimit + 1]
                )
                let truncated = pagedRows.count > cappedLimit
                let auditRows = Array(pagedRows.prefix(cappedLimit).reversed())

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

                // `agent_memory_inbox` is user-scoped, so this join must be
                // too: on a Mac where two accounts have signed in, an unscoped
                // read could name a device out of another member's inbox row.
                // With nobody signed in there is no inbox to read, and the
                // memory simply names no arrival device.
                //
                // AND IT MUST BE NAMESPACE-SCOPED (PR3 Cursor ruling, T2). The
                // join is on `engine_memory_id` alone, and a TEAM row is parked
                // under the engine id its payload seals — which on a modified
                // client is a teammate's id, lifted from a document that member
                // already had. Without this predicate a hostile team fact
                // naming a member's PRIVATE memory would become that memory's
                // "arrival" record here: its `writerDevice`, `teamID` and
                // `authorUID` reported to the model and rendered in the UI as
                // facts about a row the team never touched. Team rows are
                // excluded outright rather than matched more carefully, because
                // a team row's own local engine id is derived by the engine
                // (`_team_local_memory_id`) and never equals the sealed one, so
                // this join could not correctly connect one anyway.
                var inboundPayload: String?
                if let userID {
                    inboundPayload = try String.fetchOne(
                        db,
                        sql: """
                        SELECT inbox.payload_json
                        FROM agent_memory_inbox AS inbox
                        JOIN agent_memory_bodies AS bodies
                            ON bodies.engine_memory_id = inbox.engine_memory_id
                        WHERE bodies.memory_id = ? AND inbox.user_id = ?
                            AND inbox.doc_id NOT LIKE ?
                        ORDER BY inbox.remote_updated_at DESC
                        LIMIT 1
                        """,
                        arguments: [memoryID, userID, "\(TeamMemoryPullService.inboxDocIDPrefix)%"]
                    )
                }

                // TEAM PROVENANCE IS A SEPARATE LIFT, KEYED ON THE ID THE ENGINE
                // DERIVES (memory program D16 / P22, PR 4).
                //
                // The read above deliberately cannot answer it. PR3's ruling made
                // the sealed `memoryID` non-authoritative, so a team row's
                // `engine_memory_id` column is a value the sealer chose and a key
                // to nothing local — which is why the join excludes team rows
                // outright rather than reading them more carefully.
                //
                // The id a team document ACTUALLY lands under is derived by the
                // engine (`_namespaces.py::_team_local_memory_id`) from
                // `(teamID, convergence identity)`. So the badge re-derives it
                // and matches on that. Landing on a chosen row would need a
                // SHA-256 preimage, and the personal id space is unreachable by
                // construction: a personal row's engine id is random, never
                // derived. The `writerDevice` exclusion is therefore untouched
                // by this — a forged team row still names no device, and now
                // names no team.
                //
                // THREE INPUTS COME OFF THE PAYLOAD, CANONICALISED THE WAY THE
                // ENGINE CANONICALISES THEM, AND THE FOURTH DOES NOT (PR 4
                // review N2). `_screen_remote_row` strips `projectID`, strips
                // and lowercases `engineScope`, strips `teamID` — and RECOMPUTES
                // the body hash from the gated body, refusing on principle to
                // take the sender's word for it. This side does the same: the
                // hash is `TeamMemorySyncService.canonicalBodyHash` over the
                // body this device already holds, so a payload that arrives
                // non-canonical, or whose body this device's gate redacted,
                // still badges — and the attacker-controlled part of the
                // preimage shrinks by a field.
                var teamProvenance: ParkedTeamProvenance?
                if let userID {
                    teamProvenance = try Self.teamProvenance(db: db, memoryID: memoryID, userID: userID)
                }

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
                    writerDevice: inboundPayload.flatMap(Self.writerDevice(inPayloadJSON:)),
                    teamID: teamProvenance?.teamID,
                    authorUID: teamProvenance?.authorUID,
                    truncated: truncated
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

    /// Everything the Team Fact badge needs out of ONE parked team document.
    ///
    /// The three identity fields are the engine's derivation inputs; a payload
    /// missing any of them is not matchable and is skipped rather than guessed
    /// at. `bodyHash` is deliberately NOT among them (PR 4 review N2): the
    /// engine recomputes the body hash from the gated body and never trusts the
    /// sender's copy, so this side recomputes it too — from the local body,
    /// which is the same body — and reads one field fewer off the payload.
    ///
    /// ONE PARSE PER ROW, not five (PR 4 review N4). The five fields used to be
    /// five independent `payloadString` calls, each re-running the byte-bound
    /// check and a full `JSONSerialization` pass over the same string, on every
    /// row of a walk that runs to completion for every personal memory. Decoding
    /// once into this type costs one pass and keeps the dual spellings.
    private struct ParkedTeamPayload: Decodable {
        let teamID: String
        let projectID: String
        let engineScope: String
        let authorUID: String?

        /// Both spellings for every field, for the reason the device lookup
        /// accepts four: the engine's own meta lookup does.
        private enum CodingKeys: String, CodingKey {
            case teamID
            case teamIDSnake = "team_id"
            case projectID
            case projectIDSnake = "project_id"
            case engineScope
            case engineScopeSnake = "engine_scope"
            case authorUID
            case authorUIDSnake = "author_uid"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func firstNonEmpty(_ keys: CodingKeys...) -> String? {
                for key in keys {
                    // try?-ok(a payload field of the wrong JSON type is "absent", the same reading the dictionary lookup gave it)
                    guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { continue }
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return raw }
                }
                return nil
            }
            guard let teamID = firstNonEmpty(.teamID, .teamIDSnake),
                  let projectID = firstNonEmpty(.projectID, .projectIDSnake),
                  let engineScope = firstNonEmpty(.engineScope, .engineScopeSnake) else {
                throw MemoryTimelineError.historyUnavailable("parked team payload names no derivable identity")
            }
            self.teamID = teamID
            self.projectID = projectID
            self.engineScope = engineScope
            self.authorUID = firstNonEmpty(.authorUID, .authorUIDSnake)
        }
    }

    /// What the badge lift reports about ONE matched team document.
    private struct ParkedTeamProvenance {
        let teamID: String
        let authorUID: String?
    }

    /// How many parked team rows one detail view will walk before it stops.
    ///
    /// A CAP EXISTS BECAUSE THE WORST CASE IS THE COMMON CASE (PR 4 review N4):
    /// a personal memory — almost every memory — matches nothing, so the walk
    /// always runs to the end of the member's team rows. The durable fix is
    /// PR 3's lane (stamp the derived local id on the inbox row at park time and
    /// this becomes one indexed lookup); there is no column for it today, so the
    /// scan is the only option here and a bound is the honest mitigation.
    ///
    /// AND EXCEEDING IT IS LOGGED, never silent. An unlogged cap would drop the
    /// badge from the oldest team facts of a very active member — a wrong answer
    /// wearing the same face as the right one, since an absent badge means
    /// "personal". The bound is deliberately far above any plausible parked
    /// corpus for one member, so the log line is a signal that the durable fix
    /// is now owed rather than routine noise.
    static let teamProvenanceScanLimit = 1_000

    private static func parkedTeamProvenance(
        inPayloadJSON json: String,
        canonicalBodyHash: String,
        matching engineMemoryID: String,
        derivationCache: inout [String: String]
    ) -> ParkedTeamProvenance? {
        guard payloadIsWithinParseBound(json), let data = json.data(using: .utf8) else { return nil }
        // A row that is not a derivable team payload is not an error: the inbox
        // carries receipts and older shapes under the same prefix.
        // try?-ok(an inbox row that is not a derivable team payload contributes no badge; it is not a read failure)
        guard let payload = try? JSONDecoder().decode(ParkedTeamPayload.self, from: data) else { return nil }
        // ONE DERIVATION PER DISTINCT IDENTITY (PR 4 review N4). A team's facts
        // share `(teamID, projectID, engineScope)` almost entirely, so this
        // collapses two SHA-256 passes per ROW into two per distinct triple.
        // Keyed on `\u{1}` because it cannot occur in any of the three tokens.
        let cacheKey = [payload.teamID, payload.projectID, payload.engineScope].joined(separator: "\u{1}")
        let derived: String
        if let cached = derivationCache[cacheKey] {
            derived = cached
        } else {
            derived = TeamMemoryPullService.teamLocalEngineMemoryID(
                teamID: payload.teamID,
                projectID: payload.projectID,
                engineScope: payload.engineScope,
                canonicalBodyHash: canonicalBodyHash
            )
            derivationCache[cacheKey] = derived
        }
        guard derived == engineMemoryID else { return nil }
        return ParkedTeamProvenance(teamID: payload.teamID, authorUID: payload.authorUID)
    }

    /// The parked team document THIS memory came from, or nil for the personal
    /// memory almost every row is.
    ///
    /// Scoped three ways, and the last one is the security boundary: to this
    /// member (`user_id`), to team rows (the `doc_id` prefix — a personal doc id
    /// is 64 hex characters and can never begin with it), and to the document
    /// whose OWN derivation names this memory's engine id.
    ///
    /// COST, STATED AND NOW BOUNDED (PR 4 review N4). The derivation cannot be
    /// indexed or expressed in SQL, so this walks the member's team rows
    /// newest-first and stops at the first match. It is a lazy cursor rather
    /// than a fetch-all, and it runs once when a member opens one memory's
    /// detail view — never on a list. Three bounds keep the personal case, which
    /// is the common one and never matches, from paying for the team case:
    ///
    ///   1. **It does not start.** The local body is read first, so a memory the
    ///      engine never mirrored costs one indexed lookup; and the walk is
    ///      skipped entirely unless this member has at least one parked team row
    ///      — which for a member in no team is every memory they own, at the
    ///      cost of one `EXISTS`.
    ///   2. **One JSON parse per row**, not the five independent ones the five
    ///      payload fields used to cost.
    ///   3. **One derivation per distinct `(teamID, projectID, engineScope)`**,
    ///      and at most `teamProvenanceScanLimit` rows, with the overflow
    ///      logged rather than silently answering "personal".
    private static func teamProvenance(
        db: Database,
        memoryID: MemoryID,
        userID: String
    ) throws -> ParkedTeamProvenance? {
        // The engine id AND the body, in one read: the body is what the
        // canonical hash is recomputed from (PR 4 review N2). The stored
        // `body_hash` column is deliberately NOT used — it is the daemon-mirror
        // hash, which `memory_engine/_util.py:42` names as a different,
        // non-lowered hash in a different namespace.
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT engine_memory_id, body FROM agent_memory_bodies WHERE memory_id = ? LIMIT 1",
            arguments: [memoryID]
        ) else {
            return nil
        }
        let engineMemoryID: String = row["engine_memory_id"] ?? ""
        let body: String = row["body"] ?? ""
        // An empty body cannot be the body a team fact landed with — the engine
        // refuses `EMPTY_MEMORY` — so a scrubbed row asks no question here.
        guard engineMemoryID.isEmpty == false, body.isEmpty == false else { return nil }

        let teamPrefix = "\(TeamMemoryPullService.inboxDocIDPrefix)%"
        let hasTeamRows = try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(
                SELECT 1 FROM agent_memory_inbox WHERE user_id = ? AND doc_id LIKE ? LIMIT 1
            )
            """,
            arguments: [userID, teamPrefix]
        ) ?? false
        guard hasTeamRows else { return nil }

        let canonicalBodyHash = TeamMemorySyncService.canonicalBodyHash(body)
        var derivationCache: [String: String] = [:]
        let payloads = try String.fetchCursor(
            db,
            sql: """
            SELECT payload_json
            FROM agent_memory_inbox
            WHERE user_id = ? AND doc_id LIKE ?
            ORDER BY remote_updated_at DESC
            LIMIT ?
            """,
            arguments: [userID, teamPrefix, teamProvenanceScanLimit + 1]
        )
        var scanned = 0
        while let payload = try payloads.next() {
            scanned += 1
            if scanned > teamProvenanceScanLimit {
                AppLogger.dataStore.silentFailure(
                    "team provenance walk hit its scan bound before matching",
                    error: MemoryTimelineError.historyUnavailable("team provenance scan bound reached"),
                    context: ["bound": String(teamProvenanceScanLimit)]
                )
                return nil
            }
            if let provenance = parkedTeamProvenance(
                inPayloadJSON: payload,
                canonicalBodyHash: canonicalBodyHash,
                matching: engineMemoryID,
                derivationCache: &derivationCache
            ) {
                return provenance
            }
        }
        return nil
    }

    /// Pulls the writing device out of a parked cloud payload, accepting each
    /// spelling the engine's own meta lookup accepts.
    private static func writerDevice(inPayloadJSON json: String) -> String? {
        payloadString(inPayloadJSON: json, keys: ["writerDevice", "writer_device", "deviceId", "device_id"])
    }

    /// The first non-empty string among `keys` in a parked cloud payload.
    ///
    /// One parser for every routing field that rides INSIDE `payloadJSON`
    /// (`writerDevice`, and the team lane's `teamID` / `authorUID` and the three
    /// identity fields), because they are all read the same way and a second
    /// copy would drift on the byte bound alone. Both spellings are accepted for
    /// the same reason the device lookup accepts four: the engine's own meta
    /// lookup does.
    private static func payloadString(inPayloadJSON json: String, keys: [String]) -> String? {
        guard payloadIsWithinParseBound(json), let data = json.data(using: .utf8) else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            AppLogger.dataStore.silentFailure("Unparseable agent_memory_inbox payload_json", error: error)
            return nil
        }
        guard let dictionary = object as? [String: Any] else { return nil }
        for key in keys {
            if let value = dictionary[key] as? String,
               value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return value
            }
        }
        return nil
    }

    /// The one byte bound on parsing a parked payload, shared by both readers so
    /// the team lift cannot quietly parse something the device lookup refuses to.
    private static func payloadIsWithinParseBound(_ json: String) -> Bool {
        guard json.utf8.count <= memoryTimelinePayloadByteLimit else {
            AppLogger.dataStore.silentFailure(
                "agent_memory_inbox payload_json past the timeline parse bound",
                error: MemoryTimelineError.historyUnavailable("inbox payload past the parse bound"),
                context: [
                    "bound": String(memoryTimelinePayloadByteLimit),
                    "bytes": String(json.utf8.count)
                ]
            )
            return false
        }
        return true
    }
}
