import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - AI Inbox reads and user state

/// The app's half of the AI Inbox data contract.
///
/// Ownership is split by table, which is what lets two processes share one
/// SQLite file without coordination:
///   • the daemon writes `ai_inbox_items` / `ai_inbox_runs` / `ai_inbox_state`
///   • the app writes `ai_inbox_item_state` (read, archive, snooze, feedback)
///   • each side reads the other's tables and never writes them
///
/// Reads go straight to the shared database rather than through a daemon RPC:
/// the rows are already local, GRDB is already open, and a direct read means the
/// Inbox renders instantly even when the daemon is restarting.
extension ControlPlaneStore {
    // MARK: - Reading items

    /// One inbox row joined with the user's own state for it.
    struct AIInboxRow: Sendable, Hashable, Identifiable {
        let summary: BurnBarInboxItemSummary
        let summaryMarkdown: String
        let payload: BurnBarInboxItemPayload
        let readAt: Date?
        let archivedAt: Date?
        let snoozedUntil: Date?
        let feedback: String?

        var id: String { summary.id }
        var isUnread: Bool { readAt == nil && summary.state.isOpen }
        var isArchived: Bool { archivedAt != nil }
        var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > Date() }

        /// Hidden from the default list but still reachable through filters.
        var isHidden: Bool { isArchived || isSnoozed }
    }

    func fetchAIInboxRows(
        states: [BurnBarInboxItemState]? = BurnBarInboxItemState.openStates,
        limit: Int = 200
    ) async throws -> [AIInboxRow] {
        try await dbQueue.read { db in
            guard try Self.aiInboxTableExists(db) else { return [] }

            var sql = """
                SELECT i.id, i.fingerprint, i.kind, i.priority, i.state, i.title, i.summary_md,
                       i.payload_json, i.project_id, i.project_name, i.occurrence_count,
                       i.first_seen_at, i.last_seen_at, i.resolved_at, i.resolution_note,
                       i.model_provenance,
                       s.read_at, s.archived_at, s.snoozed_until, s.feedback
                FROM ai_inbox_items i
                LEFT JOIN ai_inbox_item_state s ON s.item_id = i.id
                """
            var arguments: [DatabaseValueConvertible] = []
            if let states, states.isEmpty == false {
                let placeholders = Array(repeating: "?", count: states.count).joined(separator: ", ")
                sql += "\nWHERE i.state IN (\(placeholders))"
                arguments.append(contentsOf: states.map(\.rawValue))
            }
            sql += "\nORDER BY i.last_seen_at DESC, i.id DESC LIMIT ?"
            arguments.append(limit)

            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map(Self.makeAIInboxRow)
        }
    }

    func fetchAIInboxRow(id: String) async throws -> AIInboxRow? {
        try await dbQueue.read { db in
            guard try Self.aiInboxTableExists(db) else { return nil }
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT i.id, i.fingerprint, i.kind, i.priority, i.state, i.title, i.summary_md,
                           i.payload_json, i.project_id, i.project_name, i.occurrence_count,
                           i.first_seen_at, i.last_seen_at, i.resolved_at, i.resolution_note,
                           i.model_provenance,
                           s.read_at, s.archived_at, s.snoozed_until, s.feedback
                    FROM ai_inbox_items i
                    LEFT JOIN ai_inbox_item_state s ON s.item_id = i.id
                    WHERE i.id = ?
                    """,
                arguments: [id]
            ).map(Self.makeAIInboxRow)
        }
    }

    /// Badge count: open, unread, not archived, not snoozed.
    ///
    /// Deliberately a `COUNT` rather than a fetch — this runs on the periodic
    /// cadence and must stay negligible.
    func aiInboxUnreadCount() async throws -> Int {
        try await dbQueue.read { db in
            guard try Self.aiInboxTableExists(db) else { return 0 }
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM ai_inbox_items i
                    LEFT JOIN ai_inbox_item_state s ON s.item_id = i.id
                    WHERE i.state IN ('new', 'updated')
                      AND s.read_at IS NULL
                      AND s.archived_at IS NULL
                      AND (s.snoozed_until IS NULL OR s.snoozed_until <= ?)
                    """,
                arguments: [Self.aiInboxTimestamp(Date())]
            ) ?? 0
        }
    }

    /// Cheap change marker: how many rows exist and when the newest one moved.
    ///
    /// Follows the `UsageTableWriteMarker` idiom — the view refreshes only when
    /// this changes, so a 30-second cadence over an idle inbox costs one
    /// aggregate query and nothing else.
    func aiInboxChangeMarker() async throws -> String {
        try await dbQueue.read { db in
            guard try Self.aiInboxTableExists(db) else { return "absent" }
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*), COALESCE(MAX(last_seen_at), ''), COALESCE(MAX(id), '')
                    FROM ai_inbox_items
                    """
            )
            let count: Int = row?[0] ?? 0
            let latest: String = row?[1] ?? ""
            let maxID: String = row?[2] ?? ""
            let stateRow = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*), COALESCE(MAX(updated_at), '') FROM ai_inbox_item_state"
            )
            let stateCount: Int = stateRow?[0] ?? 0
            let stateLatest: String = stateRow?[1] ?? ""
            return "\(count)|\(latest)|\(maxID)|\(stateCount)|\(stateLatest)"
        }
    }

    func fetchAIInboxRuns(limit: Int = 20) async throws -> [BurnBarInboxRunTelemetry] {
        try await dbQueue.read { db in
            guard try Self.aiInboxRunsTableExists(db) else { return [] }
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT tick_id, started_at, finished_at, gate_result, egress_mode, llm_calls,
                           input_tokens, output_tokens, cost_usd, items_new, items_updated,
                           items_resolved, error
                    FROM ai_inbox_runs ORDER BY started_at DESC LIMIT ?
                    """,
                arguments: [limit]
            ).map { row in
                BurnBarInboxRunTelemetry(
                    tickID: row["tick_id"] ?? "",
                    startedAt: Self.aiInboxDate(row["started_at"]) ?? Date(timeIntervalSince1970: 0),
                    finishedAt: Self.aiInboxDate(row["finished_at"]),
                    gateResult: BurnBarInboxRunTelemetry.GateResult(rawValue: row["gate_result"] ?? "") ?? .failed,
                    egressMode: BurnBarInboxEgressMode(rawValue: row["egress_mode"] ?? "") ?? .off,
                    llmCalls: row["llm_calls"] ?? 0,
                    inputTokens: row["input_tokens"] ?? 0,
                    outputTokens: row["output_tokens"] ?? 0,
                    costUSD: row["cost_usd"] ?? 0,
                    itemsNew: row["items_new"] ?? 0,
                    itemsUpdated: row["items_updated"] ?? 0,
                    itemsResolved: row["items_resolved"] ?? 0,
                    error: row["error"]
                )
            }
        }
    }

    // MARK: - Writing user state

    func markAIInboxItemRead(id: String, at date: Date = Date()) async throws {
        try await upsertAIInboxItemState(id: id, now: date) { row in
            row.readAt = row.readAt ?? date
        }
    }

    func markAIInboxItemUnread(id: String) async throws {
        try await upsertAIInboxItemState(id: id, now: Date()) { row in
            row.readAt = nil
        }
    }

    func setAIInboxItemArchived(id: String, archived: Bool, at date: Date = Date()) async throws {
        try await upsertAIInboxItemState(id: id, now: date) { row in
            row.archivedAt = archived ? date : nil
            // Archiving implies you have seen it.
            if archived { row.readAt = row.readAt ?? date }
        }
    }

    func snoozeAIInboxItem(id: String, until: Date?, at date: Date = Date()) async throws {
        try await upsertAIInboxItemState(id: id, now: date) { row in
            row.snoozedUntil = until
            if until != nil { row.readAt = row.readAt ?? date }
        }
    }

    func setAIInboxItemFeedback(id: String, feedback: String?, at date: Date = Date()) async throws {
        try await upsertAIInboxItemState(id: id, now: date) { row in
            row.feedback = feedback
        }
    }

    /// Marks every currently-open item read. The "clear the badge" gesture.
    func markAllAIInboxItemsRead(at date: Date = Date()) async throws {
        try await dbQueue.write { db in
            guard try Self.aiInboxTableExists(db) else { return }
            let stamp = Self.aiInboxTimestamp(date)
            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_item_state (item_id, read_at, updated_at)
                    SELECT i.id, ?, ?
                    FROM ai_inbox_items i
                    LEFT JOIN ai_inbox_item_state s ON s.item_id = i.id
                    WHERE i.state IN ('new', 'updated') AND s.read_at IS NULL
                    ON CONFLICT(item_id) DO UPDATE SET
                        read_at = COALESCE(ai_inbox_item_state.read_at, excluded.read_at),
                        updated_at = excluded.updated_at
                    """,
                arguments: [stamp, stamp]
            )
        }
    }

    // MARK: - Private

    private struct MutableItemState {
        var readAt: Date?
        var archivedAt: Date?
        var snoozedUntil: Date?
        var feedback: String?
    }

    /// Read-modify-write in one transaction so two rapid UI actions cannot lose
    /// each other's field.
    private func upsertAIInboxItemState(
        id: String,
        now: Date,
        _ mutate: @escaping @Sendable (inout MutableItemState) -> Void
    ) async throws {
        try await dbQueue.write { db in
            guard try Self.aiInboxStateTableExists(db) else { return }
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT read_at, archived_at, snoozed_until, feedback FROM ai_inbox_item_state WHERE item_id = ?",
                arguments: [id]
            )
            var state = MutableItemState(
                readAt: Self.aiInboxDate(existing?["read_at"]),
                archivedAt: Self.aiInboxDate(existing?["archived_at"]),
                snoozedUntil: Self.aiInboxDate(existing?["snoozed_until"]),
                feedback: existing?["feedback"]
            )
            mutate(&state)

            try db.execute(
                sql: """
                    INSERT INTO ai_inbox_item_state (item_id, read_at, archived_at, snoozed_until, feedback, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET
                        read_at = excluded.read_at,
                        archived_at = excluded.archived_at,
                        snoozed_until = excluded.snoozed_until,
                        feedback = excluded.feedback,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    id,
                    state.readAt.map(Self.aiInboxTimestamp),
                    state.archivedAt.map(Self.aiInboxTimestamp),
                    state.snoozedUntil.map(Self.aiInboxTimestamp),
                    state.feedback,
                    Self.aiInboxTimestamp(now)
                ]
            )
        }
    }

    private static func makeAIInboxRow(_ row: Row) -> AIInboxRow {
        let payload: BurnBarInboxItemPayload = {
            guard let json: String = row["payload_json"], let data = json.data(using: .utf8) else {
                return BurnBarInboxItemPayload()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(BurnBarInboxItemPayload.self, from: data)) ?? BurnBarInboxItemPayload() // try?-ok(legacy or partial rows decode to an empty payload)
        }()

        let summary = BurnBarInboxItemSummary(
            id: row["id"] ?? "",
            fingerprint: row["fingerprint"] ?? "",
            kind: BurnBarInboxItemKind(rawValue: row["kind"] ?? "") ?? .system,
            priority: BurnBarInboxPriority(clamping: row["priority"] ?? 3),
            state: BurnBarInboxItemState(rawValue: row["state"] ?? "") ?? .new,
            title: row["title"] ?? "",
            projectID: row["project_id"],
            projectName: row["project_name"],
            occurrenceCount: max(1, row["occurrence_count"] ?? 1),
            firstSeenAt: aiInboxDate(row["first_seen_at"]) ?? Date(timeIntervalSince1970: 0),
            lastSeenAt: aiInboxDate(row["last_seen_at"]) ?? Date(timeIntervalSince1970: 0),
            resolvedAt: aiInboxDate(row["resolved_at"]),
            resolutionNote: row["resolution_note"],
            modelProvenance: row["model_provenance"] ?? "local-rules",
            hasMemoryCandidates: payload.memoryCandidates.isEmpty == false
        )

        return AIInboxRow(
            summary: summary,
            summaryMarkdown: row["summary_md"] ?? "",
            payload: payload,
            readAt: aiInboxDate(row["read_at"]),
            archivedAt: aiInboxDate(row["archived_at"]),
            snoozedUntil: aiInboxDate(row["snoozed_until"]),
            feedback: row["feedback"]
        )
    }

    // The daemon writes these tables `IF NOT EXISTS` on open, and the app's v58
    // migration creates them too — but a profile can be mid-upgrade, so every
    // read probes rather than assuming.
    private static func aiInboxTableExists(_ db: Database) throws -> Bool {
        try db.tableExists("ai_inbox_items")
    }

    private static func aiInboxRunsTableExists(_ db: Database) throws -> Bool {
        try db.tableExists("ai_inbox_runs")
    }

    private static func aiInboxStateTableExists(_ db: Database) throws -> Bool {
        try db.tableExists("ai_inbox_item_state")
    }

    /// Matches the daemon's ISO-8601-with-fractional-seconds format exactly, so
    /// string comparisons in SQL (`snoozed_until <= ?`) order correctly.
    static func aiInboxTimestamp(_ date: Date) -> String {
        AIInboxTimestampCodec.string(from: date)
    }

    static func aiInboxDate(_ value: String?) -> Date? {
        AIInboxTimestampCodec.date(from: value)
    }
}

/// Lock-guarded ISO-8601 codec for AI Inbox timestamps.
///
/// `ISO8601DateFormatter` is not `Sendable` and is documented as not
/// thread-safe, so a bare `static let` is (correctly) rejected under strict
/// concurrency. Rows are read from a database pool on arbitrary threads, so the
/// formatters are wrapped rather than allocated per call.
///
/// The format mirrors `BurnBarAIInboxTimestamp` in the daemon exactly — the two
/// processes write and read the same column.
enum AIInboxTimestampCodec {
    // AUDIT(nonisolated(unsafe)): both formatters are only touched while `lock`
    // is held; see the two accessors below.
    // sendable-allowlist: foundation-sdk-shim
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // sendable-allowlist: foundation-sdk-shim
    nonisolated(unsafe) private static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    static func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return fractional.string(from: date)
    }

    static func date(from value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: value) ?? basic.date(from: value)
    }
}
