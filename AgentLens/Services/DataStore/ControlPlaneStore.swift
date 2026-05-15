import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ControlPlaneStore

/// Operating action history and controller runtime cache.
final class ControlPlaneStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Operating Action History

    func appendOperatingActionRecord(_ record: OpenBurnBarOperatingActionRecord) throws {
        try dbQueue.write { db in
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
                    record.createdAt,
                ]
            )
        }
    }

    func fetchOperatingActionRecords(
        projectName: String? = nil,
        actionKinds: [OpenBurnBarActionKind]? = nil,
        limit: Int = 100
    ) throws -> [OpenBurnBarOperatingActionRecord] {
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

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM operating_action_history
                \(whereSQL)
                ORDER BY createdAt DESC, id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
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
    ) throws -> Int {
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
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM operating_action_history
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    // MARK: - Controller Runtime Cache

    func saveControllerRuntimeMirror(
        _ snapshot: OpenBurnBarControllerRuntimeSnapshot,
        cacheKey: String = "latest"
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard let payloadJSON = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ControllerRuntime", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Controller runtime payload could not be encoded as UTF-8."
            ])
        }

        try dbQueue.write { db in
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
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        try dbQueue.read { db in
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

    func hasControllerRuntimeMirror(cacheKey: String = "latest") throws -> Bool {
        try dbQueue.read { db in
            let key = try String.fetchOne(
                db,
                sql: "SELECT cacheKey FROM controller_runtime_cache WHERE cacheKey = ? LIMIT 1",
                arguments: [cacheKey]
            )
            return key != nil
        }
    }

    func localAuthoritySnapshot() throws -> OpenBurnBarLocalAuthoritySnapshot {
        try dbQueue.read { db in
            let usageRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM token_usage") ?? 0
            let conversationRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
            let sourceArtifactsTableExists = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'source_artifacts'"
            ) ?? 0
            let sharedArtifacts = sourceArtifactsTableExists > 0
                ? ((try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_artifacts")) ?? 0)
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

    func upsertProjectMemorySnapshot(_ snapshot: ProjectMemorySnapshot, updatedAt: Date = Date()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        guard let snapshotJSON = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ProjectMemory", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Project memory snapshot could not be encoded as UTF-8."
            ])
        }

        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO project_memory_snapshots (
                    projectSlug, projectDisplayName, snapshotJSON, contentHash,
                    sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(projectSlug) DO UPDATE SET
                    projectDisplayName = excluded.projectDisplayName,
                    snapshotJSON = excluded.snapshotJSON,
                    contentHash = excluded.contentHash,
                    sourceSessionCount = excluded.sourceSessionCount,
                    sourceConversationCount = excluded.sourceConversationCount,
                    generatedAt = excluded.generatedAt,
                    schemaVersion = excluded.schemaVersion,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    snapshot.projectSlug,
                    snapshot.projectDisplayName,
                    snapshotJSON,
                    snapshot.contentHash,
                    snapshot.sourceSessionIDs.count,
                    snapshot.sourceConversationIDs.count,
                    snapshot.generatedAt,
                    snapshot.schemaVersion,
                    updatedAt
                ]
            )
        }
    }

    func fetchProjectMemorySnapshot(projectSlug: String) throws -> ProjectMemorySnapshot? {
        let normalized = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }

        return try dbQueue.read { db in
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

    func fetchProjectMemorySnapshots(limit: Int = 80) throws -> [ProjectMemorySnapshot] {
        try dbQueue.read { db in
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
                if let snapshot = try? decoder.decode(ProjectMemorySnapshot.self, from: data) {
                    snapshots.append(snapshot)
                }
            }
            return snapshots
        }
    }

    func deleteProjectMemorySnapshot(projectSlug: String) throws {
        let normalized = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return }

        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM project_memory_snapshots WHERE projectSlug = ?",
                arguments: [normalized]
            )
        }
    }

    func mutateControllerRuntimeMirror(
        cacheKey: String = "latest",
        _ mutate: (inout OpenBurnBarControllerRuntimeSnapshot) -> Void
    ) throws {
        var snapshot = try fetchControllerRuntimeMirror(cacheKey: cacheKey) ?? .empty
        mutate(&snapshot)
        try saveControllerRuntimeMirror(snapshot, cacheKey: cacheKey)
    }
}
