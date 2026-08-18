#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import OpenBurnBarEngine
// Prefer SQLCipher so open/key/schema all resolve to the same codec-backed
// sqlite3_* symbols as `BurnBarDaemonDatabaseCipher`. Falling through to
// system SQLite3 on a codec-less build keeps the plaintext path working.
#if canImport(SQLCipher)
import SQLCipher
#elseif canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

let aiInboxSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
// Identifies the store's serial queue so re-entrant calls run inline instead of
// deadlocking on `dbQueue.sync`.
let aiInboxQueueKey = DispatchSpecificKey<UUID>()

enum BurnBarAIInboxStoreError: Error, LocalizedError {
    case sqlite(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return message
        case .closed:
            return "The AI Inbox SQLite database is closed."
        }
    }
}

// AUDIT(@unchecked Sendable): raw SQLite access is serialized through `dbQueue`.
// sendable-allowlist: sqlite-raw-pointer
/// Durable store for the AI Inbox, opened against the same
/// `openburnbar.sqlite` the app and the rest of the daemon share.
///
/// Design notes:
///   • Raw sqlite3 (not GRDB) to match every other daemon-side store and to keep
///     the daemon free of the app's migration machinery.
///   • All access is serialized on one queue; the class is `@unchecked Sendable`
///     on exactly that basis, matching `BurnBarProjectCodeMemoryStore`.
///   • Opens with `CREATE` and self-heals its schema, so a fresh profile whose
///     app has not yet run migration v58 still gets a working inbox.
///   • Timestamps are ISO-8601 strings, matching the `pcm_*` convention, so the
///     rows are readable from Python/`sqlite3` and sort lexicographically.
final class BurnBarAIInboxStore: @unchecked Sendable {
    struct Row {
        let values: [String?]

        func string(_ index: Int) -> String { values.indices.contains(index) ? (values[index] ?? "") : "" }
        func optionalString(_ index: Int) -> String? { values.indices.contains(index) ? values[index] : nil }
        func int(_ index: Int) -> Int { Int(string(index)) ?? 0 }
        func double(_ index: Int) -> Double { Double(string(index)) ?? 0 }
        func date(_ index: Int) -> Date? { BurnBarAIInboxStore.date(from: optionalString(index)) }
    }

    enum Bind {
        case text(String)
        case int(Int)
        case double(Double)
        case null

        static func optionalText(_ value: String?) -> Bind { value.map(Bind.text) ?? .null }
        static func optionalDate(_ value: Date?) -> Bind {
            value.map { .text(BurnBarAIInboxStore.string(from: $0)) } ?? .null
        }
    }

    private let databasePath: String
    private let logger: BurnBarDaemonLogger
    private var db: OpaquePointer?
    /// Extra rows fetched beyond a page so a tie run on the boundary timestamp
    /// can be closed without a second query. One tick's worth of items is the
    /// realistic worst case.
    static let tieLookahead = 64

    private let dbQueue = DispatchQueue(label: "com.openburnbar.daemon.ai-inbox.sqlite")
    private let dbQueueID = UUID()

    static func string(from date: Date) -> String { BurnBarAIInboxTimestamp.string(from: date) }

    static func date(from string: String?) -> Date? { BurnBarAIInboxTimestamp.date(from: string) }

    /// Bound value for comparing against an APP-owned GRDB column
    /// (`conversations`, `token_usage`). These store `yyyy-MM-dd HH:mm:ss.SSS`,
    /// which SQLite compares as TEXT — an ISO-8601 bound silently matches zero
    /// rows. See `BurnBarAIInboxTimestamp.grdbString(from:)`.
    static func grdbString(from date: Date) -> String { BurnBarAIInboxTimestamp.grdbString(from: date) }

    init(databasePath: String, logger: BurnBarDaemonLogger) throws {
        self.databasePath = databasePath
        self.logger = logger
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            databasePath,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
            if let handle { sqlite3_close(handle) }
            throw BurnBarAIInboxStoreError.sqlite("Failed to open AI Inbox SQLite database: \(message)")
        }
        do {
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        // The app holds long write transactions during parser ingestion; wait
        // rather than surfacing SQLITE_BUSY into a background tick.
        sqlite3_busy_timeout(handle, 5000)
        db = handle
        dbQueue.setSpecific(key: aiInboxQueueKey, value: dbQueueID)
        try databaseSync { try bootstrapSchema() }
        // Inbox rows contain synthesized prose about the user's work. Match the
        // code-memory store and keep the shared database owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: databasePath
        )
    }

    deinit {
        guard let db else { return }
        _ = databaseSync { sqlite3_close(db) }
    }

    // MARK: - Schema

    func bootstrapSchema() throws {
        for statement in BurnBarAIInboxSchema.statements {
            try execute(statement, [])
        }
        for statement in BurnBarAIInboxSchema.founderLensStatements {
            try execute(statement, [])
        }
    }

    // MARK: - Items

    /// Insert-or-update keyed on the OPEN item for a fingerprint.
    ///
    /// Returns whether the row was newly created, so the caller can distinguish
    /// "new signal" (notify-worthy) from "same signal again" (silent bump).
    @discardableResult
    func upsertItem(_ candidate: BurnBarAIInboxItemWrite, now: Date) throws -> BurnBarAIInboxUpsertOutcome {
        try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                let outcome = try upsertItemLocked(candidate, now: now)
                try execute("COMMIT", [])
                return outcome
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    private func upsertItemLocked(
        _ candidate: BurnBarAIInboxItemWrite,
        now: Date
    ) throws -> BurnBarAIInboxUpsertOutcome {
        let existing = try queryRows(
            """
            SELECT id, occurrence_count, first_seen_at, priority, title, summary_md, state
            FROM ai_inbox_items
            WHERE fingerprint = ? AND state IN ('new', 'updated')
            LIMIT 1
            """,
            [.text(candidate.fingerprint)]
        ).first

        let payloadJSON = try Self.encodePayload(candidate.payload)

        guard let existing else {
            let id = candidate.id ?? "inb_\(UUID().uuidString.lowercased())"
            try execute(
                """
                INSERT INTO ai_inbox_items (
                    id, fingerprint, kind, priority, state, title, summary_md, payload_json,
                    project_id, project_name, occurrence_count, first_seen_at, last_seen_at,
                    resolved_at, resolution_note, tick_id, model_provenance
                ) VALUES (?, ?, ?, ?, 'new', ?, ?, ?, ?, ?, 1, ?, ?, NULL, NULL, ?, ?)
                """,
                [
                    .text(id),
                    .text(candidate.fingerprint),
                    .text(candidate.kind.rawValue),
                    .int(candidate.priority.rawValue),
                    .text(candidate.title),
                    .text(candidate.summaryMarkdown),
                    .text(payloadJSON),
                    .optionalText(candidate.projectID),
                    .optionalText(candidate.projectName),
                    .text(Self.string(from: now)),
                    .text(Self.string(from: now)),
                    .text(candidate.tickID),
                    .text(candidate.modelProvenance)
                ]
            )
            return BurnBarAIInboxUpsertOutcome(id: id, wasCreated: true, contentChanged: true, occurrenceCount: 1)
        }

        let existingID = existing.string(0)
        let occurrences = existing.int(1) + 1
        // Only bump `state` to `updated` when the user-visible content actually
        // moved. A recurring-but-identical condition should not un-read itself.
        let contentChanged = existing.string(3) != String(candidate.priority.rawValue)
            || existing.string(4) != candidate.title
            || existing.string(5) != candidate.summaryMarkdown
        let nextState: BurnBarInboxItemState = contentChanged ? .updated : (
            BurnBarInboxItemState(rawValue: existing.string(6)) ?? .new
        )

        try execute(
            """
            UPDATE ai_inbox_items
            SET kind = ?, priority = ?, state = ?, title = ?, summary_md = ?, payload_json = ?,
                project_id = ?, project_name = ?, occurrence_count = ?, last_seen_at = ?,
                tick_id = ?, model_provenance = ?
            WHERE id = ?
            """,
            [
                .text(candidate.kind.rawValue),
                .int(candidate.priority.rawValue),
                .text(nextState.rawValue),
                .text(candidate.title),
                .text(candidate.summaryMarkdown),
                .text(payloadJSON),
                .optionalText(candidate.projectID),
                .optionalText(candidate.projectName),
                .int(occurrences),
                .text(Self.string(from: now)),
                .text(candidate.tickID),
                .text(candidate.modelProvenance),
                .text(existingID)
            ]
        )
        return BurnBarAIInboxUpsertOutcome(
            id: existingID,
            wasCreated: false,
            contentChanged: contentChanged,
            occurrenceCount: occurrences
        )
    }

    /// Close an open item. Used when the evidence disappears — the promised PR
    /// merged, the dirty tree got committed, the workflow got fixed. Auto-resolution
    /// is what keeps the inbox honest instead of a graveyard of stale alerts.
    @discardableResult
    func resolveItem(id: String, note: String?, now: Date) throws -> Bool {
        try databaseSync {
            try execute(
                """
                UPDATE ai_inbox_items
                SET state = 'resolved', resolved_at = ?, resolution_note = ?, last_seen_at = ?
                WHERE id = ? AND state IN ('new', 'updated')
                """,
                [
                    .text(Self.string(from: now)),
                    .optionalText(note),
                    .text(Self.string(from: now)),
                    .text(id)
                ]
            )
            return changes() > 0
        }
    }

    /// Age out open items nothing has re-confirmed within `ttl`.
    @discardableResult
    func expireStaleItems(olderThan ttl: TimeInterval, now: Date, excluding kinds: Set<BurnBarInboxItemKind>) throws -> Int {
        let cutoff = now.addingTimeInterval(-ttl)
        let excluded = kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        let kindClause = excluded.isEmpty ? "" : "AND kind NOT IN (\(excluded))"
        return try databaseSync {
            try execute(
                """
                UPDATE ai_inbox_items
                SET state = 'expired', resolved_at = ?
                WHERE state IN ('new', 'updated') AND last_seen_at < ? \(kindClause)
                """,
                [.text(Self.string(from: now)), .text(Self.string(from: cutoff))]
            )
            return changes()
        }
    }

    func openItems() throws -> [BurnBarInboxItemSummary] {
        try list(BurnBarInboxListRequest(states: BurnBarInboxItemState.openStates, limit: BurnBarInboxListRequest.maxLimit)).items
    }

    func list(_ request: BurnBarInboxListRequest) throws -> BurnBarInboxListResponse {
        try databaseSync {
            var clauses: [String] = []
            var binds: [Bind] = []

            if let states = request.states, states.isEmpty == false {
                clauses.append("state IN (\(Self.placeholders(states.count)))")
                binds.append(contentsOf: states.map { Bind.text($0.rawValue) })
            }
            if let kinds = request.kinds, kinds.isEmpty == false {
                clauses.append("kind IN (\(Self.placeholders(kinds.count)))")
                binds.append(contentsOf: kinds.map { Bind.text($0.rawValue) })
            }
            if let projectID = request.projectID, projectID.isEmpty == false {
                clauses.append("project_id = ?")
                binds.append(.text(projectID))
            }
            if let before = request.before {
                clauses.append("last_seen_at < ?")
                binds.append(.text(Self.string(from: before)))
            }
            let whereClause = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"

            // Fetch one extra row to decide whether a next page exists without a
            // second COUNT query.
            let rows = try queryRows(
                """
                SELECT id, fingerprint, kind, priority, state, title, project_id, project_name,
                       occurrence_count, first_seen_at, last_seen_at, resolved_at, resolution_note,
                       model_provenance, payload_json
                FROM ai_inbox_items
                \(whereClause)
                ORDER BY last_seen_at DESC, id DESC
                LIMIT ?
                """,
                // Over-fetch so a run of rows tied on the boundary timestamp
                // can be completed in one query. Ties are common here: every
                // item written by a single tick shares that tick's timestamp.
                binds + [.int(request.limit + Self.tieLookahead)]
            )

            // Extend the page through any run of rows tied on the boundary
            // timestamp. A strictly-less-than cursor cannot express "the rest of
            // this timestamp", so the alternative is to lose those rows — as the
            // original did. Slightly over-filling one page is the cheap, correct
            // trade; the tie run is bounded by how many items one tick writes.
            var page = Array(rows.prefix(request.limit))
            if rows.count > request.limit, let boundary = page.last?.string(10) {
                for row in rows.dropFirst(request.limit) where row.string(10) == boundary {
                    page.append(row)
                }
            }
            // Only advertise another page when we actually saw rows beyond the
            // (tie-extended) page — otherwise the caller loops forever on ties.
            let nextBefore = rows.count > page.count ? page.last?.date(10) : nil
            let openCount = try fetchInt(
                "SELECT COUNT(*) FROM ai_inbox_items WHERE state IN ('new', 'updated')",
                []
            )
            return BurnBarInboxListResponse(
                items: page.map(Self.summary(from:)),
                nextBefore: nextBefore,
                openCount: openCount
            )
        }
    }

    func item(id: String) throws -> BurnBarInboxItemDetail? {
        try databaseSync {
            guard let row = try queryRows(
                """
                SELECT id, fingerprint, kind, priority, state, title, project_id, project_name,
                       occurrence_count, first_seen_at, last_seen_at, resolved_at, resolution_note,
                       model_provenance, payload_json, summary_md, tick_id
                FROM ai_inbox_items WHERE id = ? LIMIT 1
                """,
                [.text(id)]
            ).first else { return nil }
            return BurnBarInboxItemDetail(
                summary: Self.summary(from: row),
                summaryMarkdown: row.string(15),
                payload: Self.decodePayload(row.optionalString(14)),
                tickID: row.string(16)
            )
        }
    }

    func itemDetail(fingerprint: String) throws -> BurnBarInboxItemDetail? {
        try databaseSync {
            // Open item preferred; otherwise the NEWEST row for the condition.
            // Discuss is available on resolved/archived items too, and a reply
            // there still needs the item's title/summary/evidence as context.
            guard let row = try queryRows(
                """
                SELECT id FROM ai_inbox_items
                WHERE fingerprint = ?
                ORDER BY CASE WHEN state IN ('new', 'updated') THEN 0 ELSE 1 END,
                         last_seen_at DESC
                LIMIT 1
                """,
                [.text(fingerprint)]
            ).first else { return nil }
            return try itemLocked(id: row.string(0))
        }
    }

    private func itemLocked(id: String) throws -> BurnBarInboxItemDetail? {
        guard let row = try queryRows(
            """
            SELECT id, fingerprint, kind, priority, state, title, project_id, project_name,
                   occurrence_count, first_seen_at, last_seen_at, resolved_at, resolution_note,
                   model_provenance, payload_json, summary_md, tick_id
            FROM ai_inbox_items WHERE id = ? LIMIT 1
            """,
            [.text(id)]
        ).first else { return nil }
        return BurnBarInboxItemDetail(
            summary: Self.summary(from: row),
            summaryMarkdown: row.string(15),
            payload: Self.decodePayload(row.optionalString(14)),
            tickID: row.string(16)
        )
    }

    // MARK: - Runs

    func beginRun(_ telemetry: BurnBarInboxRunTelemetry, gateSignature: String) throws {
        try databaseSync {
            try execute(
                """
                INSERT OR REPLACE INTO ai_inbox_runs (
                    tick_id, started_at, finished_at, gate_result, gate_signature, egress_mode,
                    llm_calls, input_tokens, output_tokens, cost_usd,
                    items_new, items_updated, items_resolved, error
                ) VALUES (?, ?, NULL, ?, ?, ?, 0, 0, 0, 0, 0, 0, 0, NULL)
                """,
                [
                    .text(telemetry.tickID),
                    .text(Self.string(from: telemetry.startedAt)),
                    .text(telemetry.gateResult.rawValue),
                    .text(gateSignature),
                    .text(telemetry.egressMode.rawValue)
                ]
            )
        }
    }

    func finishRun(_ telemetry: BurnBarInboxRunTelemetry) throws {
        try databaseSync {
            try execute(
                """
                UPDATE ai_inbox_runs
                SET finished_at = ?, gate_result = ?, egress_mode = ?, llm_calls = ?,
                    input_tokens = ?, output_tokens = ?, cost_usd = ?,
                    items_new = ?, items_updated = ?, items_resolved = ?, error = ?
                WHERE tick_id = ?
                """,
                [
                    .text(Self.string(from: telemetry.finishedAt ?? Date())),
                    .text(telemetry.gateResult.rawValue),
                    .text(telemetry.egressMode.rawValue),
                    .int(telemetry.llmCalls),
                    .int(telemetry.inputTokens),
                    .int(telemetry.outputTokens),
                    .double(telemetry.costUSD),
                    .int(telemetry.itemsNew),
                    .int(telemetry.itemsUpdated),
                    .int(telemetry.itemsResolved),
                    .optionalText(telemetry.error),
                    .text(telemetry.tickID)
                ]
            )
        }
    }

    func recentRuns(limit: Int) throws -> [BurnBarInboxRunTelemetry] {
        try databaseSync {
            try queryRows(
                """
                SELECT tick_id, started_at, finished_at, gate_result, egress_mode, llm_calls,
                       input_tokens, output_tokens, cost_usd, items_new, items_updated,
                       items_resolved, error
                FROM ai_inbox_runs ORDER BY started_at DESC LIMIT ?
                """,
                [.int(limit)]
            ).map { row in
                BurnBarInboxRunTelemetry(
                    tickID: row.string(0),
                    startedAt: row.date(1) ?? Date(timeIntervalSince1970: 0),
                    finishedAt: row.date(2),
                    gateResult: BurnBarInboxRunTelemetry.GateResult(rawValue: row.string(3)) ?? .failed,
                    egressMode: BurnBarInboxEgressMode(rawValue: row.string(4)) ?? .off,
                    llmCalls: row.int(5),
                    inputTokens: row.int(6),
                    outputTokens: row.int(7),
                    costUSD: row.double(8),
                    itemsNew: row.int(9),
                    itemsUpdated: row.int(10),
                    itemsResolved: row.int(11),
                    error: row.optionalString(12)
                )
            }
        }
    }

    /// Spend attributed to inbox ticks since `since`. Used only for display; the
    /// authoritative budget check reads the daemon usage ledger, which is the
    /// system of record for money.
    func spend(since: Date) throws -> Double {
        try databaseSync {
            let rows = try queryRows(
                "SELECT COALESCE(SUM(cost_usd), 0) FROM ai_inbox_runs WHERE started_at >= ?",
                [.text(Self.string(from: since))]
            )
            return rows.first?.double(0) ?? 0
        }
    }

    // MARK: - State (KV)

    func state<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
        try databaseSync {
            guard let row = try queryRows(
                "SELECT value_json FROM ai_inbox_state WHERE key = ? LIMIT 1",
                [.text(key)]
            ).first, let json = row.optionalString(0), let data = json.data(using: .utf8) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(T.self, from: data)
        }
    }

    func setState<T: Encodable>(_ key: String, value: T, now: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let json = String(data: data, encoding: .utf8) ?? "null"
        try databaseSync {
            try execute(
                """
                INSERT INTO ai_inbox_state (key, value_json, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json, updated_at = excluded.updated_at
                """,
                [.text(key), .text(json), .text(Self.string(from: now))]
            )
        }
    }

    // MARK: - App-owned item state (read-only from the daemon)

    struct ItemUserState: Sendable, Hashable {
        let itemID: String
        let readAt: Date?
        let archivedAt: Date?
        let snoozedUntil: Date?
        let feedback: String?

        var isSuppressed: Bool {
            if archivedAt != nil { return true }
            if let snoozedUntil, snoozedUntil > Date() { return true }
            return false
        }
    }

    /// Reads the app-written table. Tolerates its absence: a daemon that starts
    /// before the app's migration ever ran must not fail its tick over this.
    func itemUserStates() throws -> [String: ItemUserState] {
        try databaseSync {
            guard try tableExistsLocked("ai_inbox_item_state") else { return [:] }
            let rows = try queryRows(
                "SELECT item_id, read_at, archived_at, snoozed_until, feedback FROM ai_inbox_item_state",
                []
            )
            var result: [String: ItemUserState] = [:]
            for row in rows {
                let id = row.string(0)
                result[id] = ItemUserState(
                    itemID: id,
                    readAt: row.date(1),
                    archivedAt: row.date(2),
                    snoozedUntil: row.date(3),
                    feedback: row.optionalString(4)
                )
            }
            return result
        }
    }

    private func tableExistsLocked(_ name: String) throws -> Bool {
        try queryRows(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            [.text(name)]
        ).isEmpty == false
    }

    // MARK: - Read helpers used by detectors

    /// Workspace paths for the always-on change gate.
    ///
    /// Keep this query metadata-only. The gate needs paths for a `stat`-only
    /// fingerprint and must not decode message bodies, summaries, key arrays,
    /// or `length(fullText)` on every five-minute wake.
    func recentConversationWorkingDirectories(since: Date, limit: Int) throws -> [String] {
        try databaseSync {
            guard try tableExistsLocked("conversations") else { return [] }
            return try queryRows(
                """
                SELECT workingDirectory
                FROM conversations
                WHERE COALESCE(endTime, startTime) >= ?
                ORDER BY COALESCE(endTime, startTime) DESC
                LIMIT ?
                """,
                [.text(Self.grdbString(from: since)), .int(limit)]
            ).compactMap { $0.optionalString(0) }
        }
    }

    /// Conversations touched within the window, newest first.
    ///
    /// `fullText` is deliberately excluded: it can be megabytes, and the evidence
    /// pack fetches bodies selectively with byte caps.
    func recentConversations(since: Date, limit: Int) throws -> [BurnBarAIInboxConversationRow] {
        try databaseSync {
            guard try tableExistsLocked("conversations") else { return [] }
            let rows = try queryRows(
                """
                SELECT id, provider, sessionId, projectName, startTime, endTime, messageCount,
                       inferredTaskTitle, lastAssistantMessage, summary, workingDirectory, indexedAt,
                       keyFiles, keyCommands, length(COALESCE(fullText, ''))
                FROM conversations
                WHERE COALESCE(endTime, startTime) >= ?
                ORDER BY COALESCE(endTime, startTime) DESC
                LIMIT ?
                """,
                [.text(Self.grdbString(from: since)), .int(limit)]
            )
            return rows.map { row in
                BurnBarAIInboxConversationRow(
                    id: row.string(0),
                    provider: row.string(1),
                    sessionID: row.optionalString(2),
                    projectName: row.optionalString(3),
                    startTime: row.date(4),
                    endTime: row.date(5),
                    messageCount: row.int(6),
                    inferredTaskTitle: row.optionalString(7),
                    lastAssistantMessage: row.optionalString(8),
                    summary: row.optionalString(9),
                    workingDirectory: row.optionalString(10),
                    indexedAt: row.date(11),
                    keyFiles: Self.decodeStringArray(row.optionalString(12)),
                    keyCommands: Self.decodeStringArray(row.optionalString(13)),
                    fullTextByteCount: row.int(14)
                )
            }
        }
    }

    /// Bounded body read for the evidence pack. `maxBytes` is applied in SQL so a
    /// 20 MB transcript never crosses the process boundary.
    func conversationBody(id: String, maxBytes: Int) throws -> String? {
        try databaseSync {
            guard try tableExistsLocked("conversations") else { return nil }
            return try queryRows(
                "SELECT substr(COALESCE(fullText, ''), 1, ?) FROM conversations WHERE id = ? LIMIT 1",
                [.int(max(1, maxBytes)), .text(id)]
            ).first?.optionalString(0)
        }
    }

    /// Cheap change signal: the newest indexing watermark plus a content hash of
    /// `(id, messageCount)` pairs. `messageCount` is in the hash because a live
    /// session mutates in place — the id alone would look unchanged as the
    /// transcript grows.
    func conversationWatermark(since: Date) throws -> (latestIndexedAt: Date?, contentHash: String) {
        try databaseSync {
            guard try tableExistsLocked("conversations") else { return (nil, "no-conversations") }
            let rows = try queryRows(
                """
                SELECT id, messageCount, COALESCE(indexedAt, '') FROM conversations
                WHERE COALESCE(endTime, startTime) >= ?
                ORDER BY id
                """,
                [.text(Self.grdbString(from: since))]
            )
            var hasher = BurnBarAIInboxStableHasher()
            var latest: Date?
            for row in rows {
                hasher.combine(row.string(0))
                hasher.combine(String(row.int(1)))
                if let indexedAt = row.date(2) {
                    latest = latest.map { Swift.max($0, indexedAt) } ?? indexedAt
                }
            }
            return (latest, hasher.finalize())
        }
    }

    /// Usage rows for the cost detectors. Reads the app-owned `token_usage`
    /// table read-only — the daemon never writes it.
    func usageAggregates(since: Date) throws -> [BurnBarAIInboxUsageAggregate] {
        try databaseSync {
            guard try tableExistsLocked("token_usage") else { return [] }
            return try queryRows(
                """
                SELECT COALESCE(projectName, ''), COALESCE(model, ''), COALESCE(provider, ''),
                       COUNT(*), COALESCE(SUM(totalTokens), 0), COALESCE(SUM(cost), 0)
                FROM token_usage
                WHERE startTime >= ?
                GROUP BY COALESCE(projectName, ''), COALESCE(model, ''), COALESCE(provider, '')
                ORDER BY SUM(cost) DESC
                LIMIT 200
                """,
                [.text(Self.grdbString(from: since))]
            ).map {
                BurnBarAIInboxUsageAggregate(
                    projectName: $0.string(0),
                    model: $0.string(1),
                    provider: $0.string(2),
                    callCount: $0.int(3),
                    totalTokens: $0.int(4),
                    costUSD: $0.double(5)
                )
            }
        }
    }

    // MARK: - SQLite plumbing

    func databaseSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: aiInboxQueueKey) == dbQueueID {
            return try work()
        }
        return try dbQueue.sync(execute: work)
    }

    private func changes() -> Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    func execute(_ sql: String, _ binds: [Bind]) throws {
        guard let db else { throw BurnBarAIInboxStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw sqliteError() }
    }

    func queryRows(_ sql: String, _ binds: [Bind]) throws -> [Row] {
        guard let db else { throw BurnBarAIInboxStoreError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError()
        }
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw sqliteError() }
            let count = sqlite3_column_count(statement)
            var values: [String?] = []
            values.reserveCapacity(Int(count))
            for index in 0..<count {
                if sqlite3_column_type(statement, index) == SQLITE_NULL {
                    values.append(nil)
                } else if let text = sqlite3_column_text(statement, index) {
                    values.append(String(cString: text))
                } else {
                    values.append(nil)
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    func fetchInt(_ sql: String, _ binds: [Bind]) throws -> Int {
        try queryRows(sql, binds).first?.int(0) ?? 0
    }

    private func bind(_ binds: [Bind], to statement: OpaquePointer) throws {
        for (index, value) in binds.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let string):
                rc = sqlite3_bind_text(statement, position, string, -1, aiInboxSQLiteTransient)
            case .int(let int):
                rc = sqlite3_bind_int64(statement, position, sqlite3_int64(int))
            case .double(let double):
                rc = sqlite3_bind_double(statement, position, double)
            case .null:
                rc = sqlite3_bind_null(statement, position)
            }
            guard rc == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func sqliteError() -> BurnBarAIInboxStoreError {
        .sqlite(db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error")
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: max(1, count)).joined(separator: ", ")
    }

    // MARK: - Codec

    static func encodePayload(_ payload: BurnBarInboxItemPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
    }

    /// Never throws: a payload written by a newer daemon must degrade to an empty
    /// body rather than making the row unreadable.
    static func decodePayload(_ json: String?) -> BurnBarInboxItemPayload {
        guard let json, let data = json.data(using: .utf8) else { return BurnBarInboxItemPayload() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BurnBarInboxItemPayload.self, from: data)) ?? BurnBarInboxItemPayload()
    }

    private static func decodeStringArray(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private static func summary(from row: Row) -> BurnBarInboxItemSummary {
        let payload = decodePayload(row.optionalString(14))
        return BurnBarInboxItemSummary(
            id: row.string(0),
            fingerprint: row.string(1),
            kind: BurnBarInboxItemKind(rawValue: row.string(2)) ?? .system,
            priority: BurnBarInboxPriority(clamping: row.int(3)),
            state: BurnBarInboxItemState(rawValue: row.string(4)) ?? .new,
            title: row.string(5),
            projectID: row.optionalString(6),
            projectName: row.optionalString(7),
            occurrenceCount: max(1, row.int(8)),
            firstSeenAt: row.date(9) ?? Date(timeIntervalSince1970: 0),
            lastSeenAt: row.date(10) ?? Date(timeIntervalSince1970: 0),
            resolvedAt: row.date(11),
            resolutionNote: row.optionalString(12),
            modelProvenance: row.string(13),
            hasMemoryCandidates: payload.memoryCandidates.isEmpty == false
        )
    }
}

// MARK: - Write model

/// What the publisher hands the store. Separate from the wire summary because
/// `id` is optional here (assigned on insert) and the payload is still typed.
struct BurnBarAIInboxItemWrite: Sendable {
    let id: String?
    let fingerprint: String
    let kind: BurnBarInboxItemKind
    let priority: BurnBarInboxPriority
    let title: String
    let summaryMarkdown: String
    let payload: BurnBarInboxItemPayload
    let projectID: String?
    let projectName: String?
    let tickID: String
    let modelProvenance: String

    init(
        id: String? = nil,
        fingerprint: String,
        kind: BurnBarInboxItemKind,
        priority: BurnBarInboxPriority,
        title: String,
        summaryMarkdown: String,
        payload: BurnBarInboxItemPayload,
        projectID: String? = nil,
        projectName: String? = nil,
        tickID: String,
        modelProvenance: String = "local-rules"
    ) {
        self.id = id
        self.fingerprint = fingerprint
        self.kind = kind
        self.priority = priority
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.payload = payload
        self.projectID = projectID
        self.projectName = projectName
        self.tickID = tickID
        self.modelProvenance = modelProvenance
    }
}

struct BurnBarAIInboxUpsertOutcome: Sendable, Hashable {
    let id: String
    let wasCreated: Bool
    let contentChanged: Bool
    let occurrenceCount: Int
}

// MARK: - Row models

struct BurnBarAIInboxConversationRow: Sendable, Hashable {
    let id: String
    let provider: String
    let sessionID: String?
    let projectName: String?
    let startTime: Date?
    let endTime: Date?
    let messageCount: Int
    let inferredTaskTitle: String?
    let lastAssistantMessage: String?
    let summary: String?
    let workingDirectory: String?
    let indexedAt: Date?
    let keyFiles: [String]
    let keyCommands: [String]
    let fullTextByteCount: Int

    /// Evidence id used for LLM citation validation. Includes `messageCount` so a
    /// citation pins the exact transcript revision that was in the prompt.
    var evidenceID: String { "conv:\(id):\(messageCount)" }

    var displayTitle: String {
        let candidates = [inferredTaskTitle, summary, sessionID].compactMap { $0 }
        return candidates.first { $0.isEmpty == false } ?? "Untitled session"
    }
}

struct BurnBarAIInboxUsageAggregate: Sendable, Hashable {
    let projectName: String
    let model: String
    let provider: String
    let callCount: Int
    let totalTokens: Int
    let costUSD: Double
}

/// FNV-1a over UTF-8. Deterministic across processes and runs — unlike
/// `Hasher`, which is seeded per-process and would make the change gate fire on
/// every daemon restart.
struct BurnBarAIInboxStableHasher {
    private var hash: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ value: String) {
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        // Field separator so ("ab","c") and ("a","bc") differ.
        hash ^= 0x1F
        hash = hash &* 0x0000_0100_0000_01B3
    }

    mutating func combine(_ value: Int) { combine(String(value)) }

    func finalize() -> String { String(format: "%016llx", hash) }

    static func hash(_ values: [String]) -> String {
        var hasher = BurnBarAIInboxStableHasher()
        values.forEach { hasher.combine($0) }
        return hasher.finalize()
    }
}
