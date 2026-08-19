import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    /// App scope for memories harvested out of the indexed agent corpus. It is
    /// deliberately the SAME app id the chat recall path queries — harvested
    /// facts are only worth extracting if the assistant can later recall them.
    static let agentCorpusMemoryAppID = "openburnbar"

    func enqueueMemoryExtraction(_ intent: ExtractionIntent, now: Date = Date()) async throws -> String {
        try await dbQueue.write { db in
            try self.enqueueMemoryExtraction(intent, in: db, now: now)
        }
    }

    /// Transaction-scoped enqueue (shared INSERT) so the outbox row commits atomically with the chat write (G3/P1b).
    func enqueueMemoryExtraction(_ intent: ExtractionIntent, in db: Database, now: Date = Date()) throws -> String {
        let id = "memory-extraction-\(Self.sha256Hex(intent.idempotencyKey))"
        let scopeData = try JSONEncoder().encode(intent.scope)
        guard let scopeJSON = String(data: scopeData, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.MemoryExtraction", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Extraction scope could not be encoded as UTF-8."
            ])
        }
        try db.execute(
            sql: """
            INSERT INTO memory_extraction_jobs (
                id, idempotency_key, thread_id, thread_logical_id, message_id,
                prompt_version, scope_json, status, attempts, last_error,
                not_before, lease_expires_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, NULL, ?, ?)
            ON CONFLICT(idempotency_key) DO UPDATE SET
                thread_id = excluded.thread_id,
                thread_logical_id = excluded.thread_logical_id,
                message_id = excluded.message_id,
                prompt_version = excluded.prompt_version,
                scope_json = excluded.scope_json,
                status = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN 'pending'
                    ELSE memory_extraction_jobs.status
                END,
                attempts = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN 0
                    ELSE memory_extraction_jobs.attempts
                END,
                last_error = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.last_error
                END,
                not_before = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.not_before
                END,
                lease_expires_at = CASE
                    WHEN memory_extraction_jobs.status = 'failed' THEN NULL
                    ELSE memory_extraction_jobs.lease_expires_at
                END,
                updated_at = excluded.updated_at
            """,
            arguments: [
                id,
                intent.idempotencyKey,
                intent.threadID,
                intent.threadLogicalID,
                intent.messageID,
                intent.promptVersion,
                scopeJSON,
                now,
                now
            ]
        )
        return id
    }

    /// Sweep the indexed agent corpus for QUIET conversations and enqueue one
    /// extraction job per content state. This is the wire the product thesis
    /// runs on: memory learns from all 28 providers' sessions, not only from
    /// BurnBar's own chat panel.
    ///
    /// Debounce is structural, not stateful:
    ///  - Only conversations whose file has been untouched for `quietInterval`
    ///    qualify — a session still being written re-queues on a later sweep.
    ///  - The idempotency key hashes the conversation's content state
    ///    (`fileModifiedAt` + `messageCount`), so an unchanged conversation
    ///    collapses onto its existing (possibly completed) job via the enqueue's
    ///    ON CONFLICT, and a grown one becomes exactly one new job.
    ///  - `limit` bounds enqueue work per sweep. Candidates whose content state
    ///    ALREADY has a job are skipped BEFORE the limit is applied, so the
    ///    sweep walks backwards through the corpus instead of re-selecting the
    ///    same newest rows forever (their inserts would collapse onto the
    ///    existing idempotency key and the older tail would never be reached).
    @discardableResult
    func harvestAgentConversationExtractions(
        now: Date = Date(),
        quietInterval: TimeInterval = 30 * 60,
        limit: Int = 8
    ) async throws -> Int {
        let cutoff = now.addingTimeInterval(-quietInterval)
        struct HarvestRow {
            let id: String
            let projectName: String
            let stateMarker: String
            let idempotencyKey: String
        }
        let wanted = max(1, limit)
        // Page backwards through the quiet corpus, dropping states that already
        // have a job, until `wanted` genuinely-new ones are found. `maxScan`
        // bounds the walk so one sweep can never turn into a full-table crawl.
        let pageSize = max(wanted * 4, 32)
        let maxScan = 2_000
        let rows: [HarvestRow] = try await dbQueue.read { db in
            var collected: [HarvestRow] = []
            var offset = 0
            while collected.count < wanted, offset < maxScan {
                let page: [HarvestRow] = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, projectName, messageCount, fileModifiedAt
                    FROM conversations
                    WHERE deletedAt IS NULL
                      AND fullText != ''
                      AND fileModifiedAt IS NOT NULL
                      AND fileModifiedAt < ?
                    ORDER BY fileModifiedAt DESC
                    LIMIT ? OFFSET ?
                    """,
                    arguments: [cutoff, pageSize, offset]
                ).compactMap { row in
                    guard let id = row["id"] as? String, id.isEmpty == false else { return nil }
                    let modifiedEpoch = OpenBurnBarDatabase.parseDateValue(row["fileModifiedAt"])
                        .map { String(Int($0.timeIntervalSince1970)) } ?? "0"
                    let messageCountValue: Int64? = row["messageCount"]
                    let messageCount = messageCountValue.map(String.init) ?? "0"
                    let stateMarker = "state-\(modifiedEpoch)-\(messageCount)"
                    let threadID = AgentConversationExtractionSource.threadID(forConversationID: id)
                    return HarvestRow(
                        id: id,
                        projectName: (row["projectName"] as? String) ?? "",
                        stateMarker: stateMarker,
                        idempotencyKey: MemoryExtraction.idempotencyKey(
                            threadLogicalID: threadID,
                            messageID: stateMarker,
                            promptVersion: AgentConversationExtractionSource.promptVersion
                        )
                    )
                }
                if page.isEmpty { break }
                offset += pageSize

                // One round trip per page: which of these states are already known?
                let placeholders = Array(repeating: "?", count: page.count).joined(separator: ", ")
                let known = try String.fetchSet(
                    db,
                    sql: """
                    SELECT idempotency_key FROM memory_extraction_jobs
                    WHERE idempotency_key IN (\(placeholders))
                    """,
                    arguments: StatementArguments(page.map(\.idempotencyKey))
                )
                for candidate in page where known.contains(candidate.idempotencyKey) == false {
                    collected.append(candidate)
                    if collected.count == wanted { break }
                }
            }
            return collected
        }
        guard rows.isEmpty == false else { return 0 }

        var enqueued = 0
        for row in rows {
            let threadID = AgentConversationExtractionSource.threadID(forConversationID: row.id)
            let promptVersion = AgentConversationExtractionSource.promptVersion
            // The app scope the normal recall path queries. `memoryStorageProjectID`
            // buckets a project-less chat scope to `chat:<appID>`, which is exactly
            // what `MemoryScope(appID: "openburnbar")` recall reads; setting
            // `projectID` here instead would file these rows under the bare project
            // name where no reader ever looks, so the harvest would extract
            // memories that could never be recalled.
            var scope = MemoryScope(appID: Self.agentCorpusMemoryAppID)
            let intent = ExtractionIntent(
                threadID: threadID,
                threadLogicalID: threadID,
                messageID: row.stateMarker,
                scope: scope,
                promptVersion: promptVersion,
                idempotencyKey: row.idempotencyKey
            )
            _ = try await enqueueMemoryExtraction(intent, now: now)
            enqueued += 1
        }
        return enqueued
    }

    func claimNextMemoryExtractionJob(
        now: Date = Date(),
        maxAttempts: Int = 3,
        leaseDuration: TimeInterval = MemoryExtractionJob.defaultLeaseDuration
    ) async throws -> MemoryExtractionJob? {
        try await dbQueue.write { db in
            let boundedMaxAttempts = max(1, maxAttempts)
            // Self-healing dead-letter sweep (runs on every claim): rescue jobs wedged
            // `.running` by a worker process that died mid-drain. See `reapExhaustedRunningJobs`.
            try Self.reapExhaustedRunningJobs(db, now: now, boundedMaxAttempts: boundedMaxAttempts)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM memory_extraction_jobs
                WHERE (
                    status = 'pending'
                    AND (not_before IS NULL OR not_before <= ?)
                ) OR (
                    status = 'failed'
                    AND attempts < ?
                    AND not_before IS NOT NULL
                    AND not_before <= ?
                ) OR (
                    status = 'running'
                    AND attempts < ?
                    AND lease_expires_at IS NOT NULL
                    AND lease_expires_at <= ?
                )
                ORDER BY created_at ASC, id ASC
                LIMIT 1
                """,
                arguments: [now, boundedMaxAttempts, now, boundedMaxAttempts, now]
            ),
                  var job = Self.memoryExtractionJob(from: row) else {
                return nil
            }
            let leaseExpiresAt = now.addingTimeInterval(max(1, leaseDuration))
            try db.execute(
                sql: """
                UPDATE memory_extraction_jobs
                SET status = 'running', attempts = attempts + 1, lease_expires_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [leaseExpiresAt, now, job.id]
            )
            job = MemoryExtractionJob(
                id: job.id,
                idempotencyKey: job.idempotencyKey,
                threadID: job.threadID,
                threadLogicalID: job.threadLogicalID,
                messageID: job.messageID,
                promptVersion: job.promptVersion,
                scope: job.scope,
                status: .running,
                attempts: job.attempts + 1,
                lastError: job.lastError,
                notBefore: job.notBefore,
                leaseExpiresAt: leaseExpiresAt,
                createdAt: job.createdAt,
                updatedAt: now
            )
            return job
        }
    }

    func markMemoryExtractionJobSucceeded(_ id: String, now: Date = Date()) async throws {
        try await updateMemoryExtractionJob(
            id,
            status: .succeeded,
            lastError: nil,
            notBefore: nil,
            now: now
        )
    }

    func markMemoryExtractionJobFailed(
        _ id: String,
        error: String,
        retryAfter: TimeInterval,
        now: Date = Date()
    ) async throws {
        try await updateMemoryExtractionJob(
            id,
            status: .failed,
            lastError: error,
            notBefore: now.addingTimeInterval(retryAfter),
            now: now
        )
    }

    /// Diagnostic `last_error` stamped on jobs dead-lettered by the reaper.
    static let memoryExtractionLeaseExhaustedError = "lease_exhausted"

    /// Dead-letter zombie jobs. A row left `.running` after a worker process died
    /// mid-drain keeps its bumped attempt count but is never marked terminal. Once
    /// `attempts` reaches the cap, the running-reclaim branch in
    /// `claimNextMemoryExtractionJob` (which requires `attempts < max`) can no longer
    /// pick it, so without this it would wedge `.running` forever (no janitor, and the
    /// `ON CONFLICT failed -> pending` enqueue reset only revives `.failed` rows).
    /// Transition such lease-expired, attempt-exhausted rows to a terminal `.failed`
    /// with a diagnostic so they are observable AND revivable by a fresh enqueue.
    /// Returns the number of rows dead-lettered. Idempotent and cheap (single UPDATE).
    @discardableResult
    static func reapExhaustedRunningJobs(_ db: Database, now: Date, boundedMaxAttempts: Int) throws -> Int {
        try db.execute(
            sql: """
            UPDATE memory_extraction_jobs
            SET status = 'failed',
                last_error = ?,
                not_before = NULL,
                lease_expires_at = NULL,
                updated_at = ?
            WHERE status = 'running'
              AND attempts >= ?
              AND lease_expires_at IS NOT NULL
              AND lease_expires_at <= ?
            """,
            arguments: [memoryExtractionLeaseExhaustedError, now, boundedMaxAttempts, now]
        )
        return db.changesCount
    }

    /// Standalone reaper entry point for a periodic janitor or tests. Wraps
    /// `reapExhaustedRunningJobs` in its own write transaction. Returns the number of
    /// zombie jobs dead-lettered.
    @discardableResult
    func reapStaleRunningMemoryExtractionJobs(now: Date = Date(), maxAttempts: Int = 3) async throws -> Int {
        try await dbQueue.write { db in
            try Self.reapExhaustedRunningJobs(db, now: now, boundedMaxAttempts: max(1, maxAttempts))
        }
    }

    func memoryExtractionJobStatus(id: String) async throws -> MemoryEventStatus? {
        try await dbQueue.read { db in
            guard let raw = try String.fetchOne(
                db,
                sql: "SELECT status FROM memory_extraction_jobs WHERE id = ?",
                arguments: [id]
            ) else {
                return nil
            }
            return MemoryEventStatus(rawValue: raw)
        }
    }

    /// The most-recently-updated job currently in `failed` status, or nil if none.
    /// The `MemoryExtractionEngine` reads this after a `claimedButFailed` drain tick to
    /// surface `lastError` (PR-D2 must-fix #3): extraction errors are swallowed by the
    /// worker — they never propagate through `drainNext()` — so the terminal status is
    /// the only place a failure is observable. A best-effort diagnostic read; not a gate.
    func mostRecentFailedMemoryExtractionJob() async throws -> MemoryExtractionJob? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM memory_extraction_jobs
                WHERE status = 'failed'
                ORDER BY updated_at DESC, id DESC
                LIMIT 1
                """
            ) else {
                return nil
            }
            return Self.memoryExtractionJob(from: row)
        }
    }

    private func updateMemoryExtractionJob(
        _ id: String,
        status: MemoryEventStatus,
        lastError: String?,
        notBefore: Date?,
        now: Date
    ) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_extraction_jobs
                SET status = ?, last_error = ?, not_before = ?, lease_expires_at = NULL, updated_at = ?
                WHERE id = ?
                """,
                arguments: [status.rawValue, lastError, notBefore, now, id]
            )
        }
    }

    private static func memoryExtractionJob(from row: Row) -> MemoryExtractionJob? {
        guard let id: String = row["id"],
              let idempotencyKey: String = row["idempotency_key"],
              let threadID: String = row["thread_id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let messageID: String = row["message_id"],
              let promptVersion: String = row["prompt_version"],
              let scopeJSON: String = row["scope_json"],
              let scopeData = scopeJSON.data(using: .utf8),
              let statusRaw: String = row["status"],
              let status = MemoryEventStatus(rawValue: statusRaw),
              let attempts: Int = row["attempts"],
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updated_at"])
        else {
            return nil
        }
        let decoder = JSONDecoder()
        let scope: MemoryScope
        do {
            scope = try decoder.decode(MemoryScope.self, from: scopeData)
        } catch {
            return nil
        }
        return MemoryExtractionJob(
            id: id,
            idempotencyKey: idempotencyKey,
            threadID: threadID,
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            promptVersion: promptVersion,
            scope: scope,
            status: status,
            attempts: attempts,
            lastError: row["last_error"],
            notBefore: OpenBurnBarDatabase.parseDateValue(row["not_before"]),
            leaseExpiresAt: OpenBurnBarDatabase.parseDateValue(row["lease_expires_at"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

}
