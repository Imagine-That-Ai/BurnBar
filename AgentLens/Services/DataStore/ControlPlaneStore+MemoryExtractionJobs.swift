import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

extension ControlPlaneStore {
    func enqueueMemoryExtraction(_ intent: ExtractionIntent, now: Date = Date()) async throws -> String {
        try await dbQueue.write { db in
            try self.enqueueMemoryExtraction(intent, in: db, now: now)
        }
    }

    /// Transaction-scoped enqueue (shared INSERT) so the outbox row commits atomically with the chat write (G3/P1b).
    /// `sourceKind` defaults `.chat` (matching the v61 column default), keeping every chat call site byte-identical;
    /// usage batch jobs route through `enqueueUsageExtractionJob`, which passes their usage kind.
    func enqueueMemoryExtraction(
        _ intent: ExtractionIntent,
        in db: Database,
        sourceKind: MemorySourceKind = .chat,
        now: Date = Date()
    ) throws -> String {
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
                prompt_version, scope_json, source_kind, status, attempts, last_error,
                not_before, lease_expires_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, NULL, NULL, NULL, ?, ?)
            ON CONFLICT(idempotency_key) DO UPDATE SET
                thread_id = excluded.thread_id,
                thread_logical_id = excluded.thread_logical_id,
                message_id = excluded.message_id,
                prompt_version = excluded.prompt_version,
                scope_json = excluded.scope_json,
                source_kind = excluded.source_kind,
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
                sourceKind.rawValue,
                now,
                now
            ]
        )
        return id
    }

    // MARK: - Usage batch jobs (PR6 Stage 1)

    /// Deterministic content id for a usage batch: sha256 over the SORTED
    /// candidate ids joined by `|`, so the same candidate set always hashes to
    /// the same batch regardless of assembly order.
    static func usageExtractionBatchHash(candidateIDs: [String]) -> String {
        sha256Hex(candidateIDs.sorted().joined(separator: "|"))
    }

    /// Transaction-scoped enqueue of one usage-extraction batch job PLUS the
    /// `{status: batched, batch_job_id}` stamp on its candidates — one write
    /// txn, so a crash can never orphan stamped candidates without a job (or
    /// vice versa). Synthetic identity per the Stage-1 plan:
    ///   thread_id / thread_logical_id = "usage:<kind raw>"
    ///   message_id      = "usage-batch-<sha256(sorted candidate ids | -joined)>"
    ///   idempotency_key = "usage|<kind raw>|<batch hash>|<promptVersion>"
    /// `scope_json` reuses the exact `ExtractionIntent`/`JSONEncoder` path the
    /// chat enqueue uses, carrying the same user-scope shape chat jobs carry
    /// (production chat scope is `MemoryScope(appID: "openburnbar")`).
    func enqueueUsageExtractionJob(
        candidateIDs: [String],
        sourceKind: MemorySourceKind,
        promptVersion: String,
        scope: MemoryScope,
        in db: Database,
        now: Date = Date()
    ) throws -> String {
        let batchHash = Self.usageExtractionBatchHash(candidateIDs: candidateIDs)
        let syntheticThreadID = "usage:\(sourceKind.rawValue)"
        let intent = ExtractionIntent(
            threadID: syntheticThreadID,
            threadLogicalID: syntheticThreadID,
            messageID: "usage-batch-\(batchHash)",
            scope: scope,
            promptVersion: promptVersion,
            idempotencyKey: "usage|\(sourceKind.rawValue)|\(batchHash)|\(promptVersion)"
        )
        let jobID = try enqueueMemoryExtraction(intent, in: db, sourceKind: sourceKind, now: now)
        for candidateID in candidateIDs {
            try db.execute(
                sql: """
                UPDATE memory_usage_candidates
                SET status = 'batched', batch_job_id = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [jobID, now, candidateID]
            )
        }
        return jobID
    }

    /// Claim the next runnable job. `allowedSourceKinds` (PR6) restricts the
    /// claim to jobs whose gate lattice currently allows processing — e.g. a
    /// closed chat gate with an open usage gate claims usage jobs only, and a
    /// closed usage gate never claims (or burns an attempt on) a usage batch.
    /// `nil` preserves the pre-PR6 unfiltered behavior.
    func claimNextMemoryExtractionJob(
        now: Date = Date(),
        maxAttempts: Int = 3,
        leaseDuration: TimeInterval = MemoryExtractionJob.defaultLeaseDuration,
        allowedSourceKinds: Set<MemorySourceKind>? = nil
    ) async throws -> MemoryExtractionJob? {
        if let allowedSourceKinds, allowedSourceKinds.isEmpty { return nil }
        return try await dbQueue.write { db in
            let boundedMaxAttempts = max(1, maxAttempts)
            // Self-healing dead-letter sweep (runs on every claim): rescue jobs wedged
            // `.running` by a worker process that died mid-drain. See `reapExhaustedRunningJobs`.
            try Self.reapExhaustedRunningJobs(db, now: now, boundedMaxAttempts: boundedMaxAttempts)
            var kindPredicate = ""
            var kindArguments: [any DatabaseValueConvertible] = []
            if let allowedSourceKinds {
                let clause = Self.memorySourceKindInClause(column: "source_kind", kinds: allowedSourceKinds)
                kindPredicate = "AND \(clause.sql)"
                kindArguments = clause.arguments
            }
            var arguments: [any DatabaseValueConvertible] = [now, boundedMaxAttempts, now, boundedMaxAttempts, now]
            arguments.append(contentsOf: kindArguments)
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM memory_extraction_jobs
                WHERE ((
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
                )) \(kindPredicate)
                ORDER BY created_at ASC, id ASC
                LIMIT 1
                """,
                arguments: StatementArguments(arguments)
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
                sourceKind: job.sourceKind,
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
        // Pre-v61 rows have no value beyond the column default; an unknown raw
        // value (a future kind this build does not know) maps to `.chat` so the
        // row remains claimable by the chat lane rather than wedging unclaimed.
        let sourceKind = (row["source_kind"] as String?).flatMap(MemorySourceKind.init(rawValue:)) ?? .chat
        return MemoryExtractionJob(
            id: id,
            idempotencyKey: idempotencyKey,
            threadID: threadID,
            threadLogicalID: threadLogicalID,
            messageID: messageID,
            promptVersion: promptVersion,
            scope: scope,
            sourceKind: sourceKind,
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
