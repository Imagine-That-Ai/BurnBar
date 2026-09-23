import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore
import OpenBurnBarData

// MARK: - ControlPlaneStore

/// Operating action history and controller runtime cache.
final class ControlPlaneStore: Sendable {
    static let chatMemoryAuthorityWritesEnabledByDefault = true

    let dbQueue: any DatabaseWriter
    /// Monotonic count of memory device-sync consent WITHDRAWALS on this store.
    /// Bumped inside the same database transaction as every withdrawal
    /// (`ControlPlaneStore+MemorySyncInbox.swift`) and read by
    /// `MemoryDeviceSyncInboxGuard` BEFORE it captures the scope it is about to
    /// enforce, so a publish whose scope predates a withdrawal is refused
    /// instead of republishing a departed member's consent. Process-local on
    /// purpose: the daemon never publishes, and no enforcement outlives the app.
    let memoryDeviceSyncGeneration = Locked<UInt64>(0)

    /// How an agent-lane review verdict reaches the daemon, which is the only
    /// process that may publish a quarantined body (I-56). Injected rather than
    /// called straight through, so a test can drive a reachable and an
    /// unreachable daemon; production takes the default, which is one socket
    /// RPC. See `ControlPlaneStore+MemoryPublication.swift`.
    let publishAgentMemoryReviewStatus: AgentMemoryReviewPublishing

    /// How an agent-lane forget reaches the daemon BEFORE the app's own row
    /// delete (review #2565): the daemon owns the quarantine body, the
    /// published section and the engine mirror, and a throwing call leaves the
    /// local row untouched. See `deleteMemoryAuthorityRecord`.
    let forgetAgentMemory: AgentMemoryForgetting

    /// How project-memory snapshot writes reach the daemon, which owns the
    /// table (Wave 2.1c, ADR-005). Injected like the chat writer so a test
    /// can drive a reachable and an unreachable daemon; production takes the
    /// default, which is one socket RPC per call.
    let snapshotWriter: any ProjectMemorySnapshotWriter

    /// How memory authority writes reach the daemon, which owns the tables
    /// (Wave 2.1c-iii, ADR-005). The app finalizes the write set locally and
    /// commits it through this seam; production takes the default, which is
    /// one socket RPC per mutation, failing closed when unreachable.
    let memoryAuthorityWriter: any MemoryAuthorityWriter

    init(
        dbQueue: any DatabaseWriter,
        publishAgentMemoryReviewStatus: @escaping AgentMemoryReviewPublishing =
            ControlPlaneStore.liveAgentMemoryReviewPublisher,
        forgetAgentMemory: @escaping AgentMemoryForgetting =
            ControlPlaneStore.liveAgentMemoryForgetter,
        snapshotWriter: any ProjectMemorySnapshotWriter = DaemonProjectMemorySnapshotWriter(),
        memoryAuthorityWriter: any MemoryAuthorityWriter = DaemonMemoryAuthorityWriter()
    ) {
        self.dbQueue = dbQueue
        self.publishAgentMemoryReviewStatus = publishAgentMemoryReviewStatus
        self.forgetAgentMemory = forgetAgentMemory
        self.snapshotWriter = snapshotWriter
        self.memoryAuthorityWriter = memoryAuthorityWriter
    }

    // MARK: - Operating Action History

    func appendOperatingActionRecord(_ record: OpenBurnBarOperatingActionRecord) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO operating_action_history (
                    id, projectName, missionFingerprint, actionKind, summary,
                    detail, overrideMode, forcedDirectionStatus, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    record.id,
                    record.projectName,
                    record.missionFingerprint,
                    record.actionKind.rawValue,
                    record.summary,
                    record.detail,
                    record.overrideMode?.rawValue,
                    record.forcedDirectionStatus?.rawValue,
                    record.createdAt
                ]
            )
        }
    }

    func fetchOperatingActionRecords(
        projectName: String? = nil,
        actionKinds: [OpenBurnBarActionKind]? = nil,
        limit: Int = 100
    ) async throws -> [OpenBurnBarOperatingActionRecord] {
        if let actionKinds, actionKinds.isEmpty { return [] }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty == false {
            clauses.append("projectName = ?")
            args.append(projectName)
        }
        if let actionKinds, actionKinds.isEmpty == false {
            clauses.append("actionKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: actionKinds.count)))")
            args.append(contentsOf: actionKinds.map(\.rawValue))
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let capturedArgs = args

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM operating_action_history
                \(whereSQL)
                ORDER BY createdAt DESC, id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(capturedArgs)
            )
            return rows.compactMap { row in
                guard
                    let id = row["id"] as? String,
                    let projectName = row["projectName"] as? String,
                    let actionKindRaw = row["actionKind"] as? String,
                    let actionKind = OpenBurnBarActionKind(rawValue: actionKindRaw),
                    let summary = row["summary"] as? String
                else {
                    return nil
                }
                return OpenBurnBarOperatingActionRecord(
                    id: id,
                    projectName: projectName,
                    missionFingerprint: row["missionFingerprint"] as? String,
                    actionKind: actionKind,
                    summary: summary,
                    detail: row["detail"] as? String,
                    overrideMode: (row["overrideMode"] as? String).flatMap(OpenBurnBarDirectionOverrideModeKind.init(rawValue:)),
                    forcedDirectionStatus: (row["forcedDirectionStatus"] as? String).flatMap(OpenBurnBarDirectionAssessment.init(rawValue:)),
                    createdAt: OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
                )
            }
        }
    }

    func countOperatingActionRecords(
        projectName: String? = nil,
        actionKinds: [OpenBurnBarActionKind]? = nil
    ) async throws -> Int {
        if let actionKinds, actionKinds.isEmpty { return 0 }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let projectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), projectName.isEmpty == false {
            clauses.append("projectName = ?")
            args.append(projectName)
        }
        if let actionKinds, actionKinds.isEmpty == false {
            clauses.append("actionKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: actionKinds.count)))")
            args.append(contentsOf: actionKinds.map(\.rawValue))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let capturedArgs = args
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM operating_action_history
                \(whereSQL)
                """,
                arguments: StatementArguments(capturedArgs)
            ) ?? 0
        }
    }

    // MARK: - Controller Runtime Cache

    func saveControllerRuntimeMirror(
        _ snapshot: OpenBurnBarControllerRuntimeSnapshot,
        cacheKey: String = "latest"
    ) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ControllerRuntime", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Controller runtime payload could not be encoded as UTF-8."
            ])
        }

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt)
                VALUES (?, ?, ?)
                ON CONFLICT(cacheKey) DO UPDATE SET
                    payloadJSON = excluded.payloadJSON,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [cacheKey, payloadJSON, snapshot.updatedAt]
            )
        }
    }

    func fetchControllerRuntimeMirror(
        cacheKey: String = "latest"
    ) async throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try await dbQueue.read { db in
            guard let payloadJSON = try String.fetchOne(
                db,
                sql: "SELECT payloadJSON FROM controller_runtime_cache WHERE cacheKey = ?",
                arguments: [cacheKey]
            ) else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = payloadJSON.data(using: .utf8) else { return nil }
            return try decoder.decode(OpenBurnBarControllerRuntimeSnapshot.self, from: data)
        }
    }

    func hasControllerRuntimeMirror(cacheKey: String = "latest") async throws -> Bool {
        try await dbQueue.read { db in
            let key = try String.fetchOne(
                db,
                sql: "SELECT cacheKey FROM controller_runtime_cache WHERE cacheKey = ? LIMIT 1",
                arguments: [cacheKey]
            )
            return key != nil
        }
    }

    func localAuthoritySnapshot() async throws -> OpenBurnBarLocalAuthoritySnapshot {
        try await dbQueue.read { db in
            let usageRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage") ?? 0
            let conversationRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE deletedAt IS NULL") ?? 0
            let sourceArtifactsTableExists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_artifacts'"
            ) ?? 0
            let sharedArtifacts = sourceArtifactsTableExists > 0
                ? ((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_artifacts")) ?? 0) // try?-ok(count defaults to zero)
                : 0
            let cachedMirror = (try String.fetchOne(
                db,
                sql: "SELECT cacheKey FROM controller_runtime_cache WHERE cacheKey = ? LIMIT 1",
                arguments: ["latest"]
            )) != nil

            return OpenBurnBarLocalAuthoritySnapshot(
                usageRowCount: usageRows,
                conversationRowCount: conversationRows,
                sharedArtifactCount: sharedArtifacts,
                controllerRuntimeCached: cachedMirror
            )
        }
    }

    // MARK: - Project Memory Snapshots

    func upsertProjectMemorySnapshot(_ snapshot: ProjectMemorySnapshot, updatedAt: Date = Date()) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard let snapshotJSON = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ProjectMemory", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Project memory snapshot could not be encoded as UTF-8."
            ])
        }

        // Wave 2.1c: the daemon owns the table. One RPC carries the finalized
        // bytes — the JSON and hash stay one atomic unit on the daemon side —
        // and there is deliberately no local-write fallback (single writer).
        try await snapshotWriter.upsertSnapshot(
            BurnBarProjectMemorySnapshotUpsertRequest(
                projectSlug: snapshot.projectSlug,
                projectDisplayName: snapshot.projectDisplayName,
                snapshotJSON: snapshotJSON,
                contentHash: snapshot.contentHash,
                sourceSessionCount: snapshot.sourceSessionIDs.count,
                sourceConversationCount: snapshot.sourceConversationIDs.count,
                generatedAt: Self.iso8601String(snapshot.generatedAt),
                schemaVersion: snapshot.schemaVersion,
                updatedAt: Self.iso8601String(updatedAt)
            )
        )
    }

    func fetchProjectMemorySnapshot(projectSlug: String) async throws -> ProjectMemorySnapshot? {
        let normalized = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }

        return try await dbQueue.read { db in
            guard let snapshotJSON = try String.fetchOne(
                db,
                sql: """
                SELECT snapshotJSON
                FROM project_memory_snapshots
                WHERE projectSlug = ?
                LIMIT 1
                """,
                arguments: [normalized]
            ) else {
                return nil
            }
            guard let data = snapshotJSON.data(using: .utf8) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ProjectMemorySnapshot.self, from: data)
        }
    }

    func fetchProjectMemorySnapshots(limit: Int = 80) async throws -> [ProjectMemorySnapshot] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT snapshotJSON
                FROM project_memory_snapshots
                ORDER BY generatedAt DESC, updatedAt DESC, projectSlug ASC
                LIMIT ?
                """,
                arguments: [max(1, limit)]
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var snapshots: [ProjectMemorySnapshot] = []
            snapshots.reserveCapacity(rows.count)
            for row in rows {
                guard let json: String = row["snapshotJSON"], let data = json.data(using: .utf8) else {
                    continue
                }
                if let snapshot = try? decoder.decode(ProjectMemorySnapshot.self, from: data) { // try?-ok(skip malformed snapshot row)
                    snapshots.append(snapshot)
                }
            }
            return snapshots
        }
    }

    func deleteProjectMemorySnapshot(projectSlug: String) async throws {
        let normalized = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }

        // Wave 2.1c: daemon-owned table — delete goes through the writer seam.
        try await snapshotWriter.deleteSnapshot(projectSlug: normalized)
    }

    func mutateControllerRuntimeMirror(
        cacheKey: String = "latest",
        _ mutate: (inout OpenBurnBarControllerRuntimeSnapshot) -> Void
    ) async throws {
        var snapshot = try await fetchControllerRuntimeMirror(cacheKey: cacheKey) ?? .empty
        mutate(&snapshot)
        try await saveControllerRuntimeMirror(snapshot, cacheKey: cacheKey)
    }

    static func auditLabelsJSON(_ labels: [String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: labels.sorted(), options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // Wave 2.1c-iii: the v2 audit hash payload moved to the daemon
    // (`memoryAuditPayloadData`); the app finalizes labels and the daemon
    // assigns the chain fields in-transaction.

    static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // Wave 2.1c-iii: audit appends commit through the writer seam
    // (`memoryAuthorityAuditEvent` + `commitMemoryAuthorityOperations`);
    // the daemon assigns the chain fields from the live head.

}
