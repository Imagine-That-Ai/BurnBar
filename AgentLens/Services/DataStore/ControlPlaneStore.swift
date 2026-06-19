import Foundation
import CryptoKit
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - ControlPlaneStore

/// Operating action history and controller runtime cache.
final class ControlPlaneStore: Sendable {
    static let chatMemoryAuthorityWritesEnabledByDefault = false

    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
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

        try await dbQueue.write { db in
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

        try await dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM project_memory_snapshots WHERE projectSlug = ?",
                arguments: [normalized]
            )
        }
    }

    // MARK: - Chat Memory Authority (flagged off)

    enum ChatMemoryAuthorityError: Error, LocalizedError, Equatable {
        case disabled
        case emptyBody

        var errorDescription: String? {
            switch self {
            case .disabled:
                "Chat memory authority writes are disabled."
            case .emptyBody:
                "Chat memory body is empty."
            }
        }
    }

    func addChatMemoryAuthorityRecord(
        _ request: MemoryAddRequest,
        id: MemoryID = UUID().uuidString,
        now: Date = Date(),
        enabled: Bool = ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault
    ) async throws -> Memory {
        guard enabled else { throw ChatMemoryAuthorityError.disabled }
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw ChatMemoryAuthorityError.emptyBody }

        let bodyHash = Self.sha256Hex(body)
        let snapshotSlug = Self.memorySnapshotSlug(id)
        let bodyRef = Self.memorySnapshotRef(snapshotSlug)
        let storageProjectID = Self.memoryStorageProjectID(for: request.scope)
        let nowString = Self.iso8601String(now)
        let citations = request.citations
        let snapshotJSON = try Self.memoryBodySnapshotJSON(
            memoryID: id,
            body: body,
            bodyHash: bodyHash,
            citations: citations,
            createdAt: now
        )
        let labelsJSON = try Self.auditLabelsJSON([
            "memory_id": id,
            "source_kind": MemorySourceKind.chat.rawValue,
            "review_status": request.reviewStatus.rawValue,
            "body_ref": bodyRef
        ])

        try await dbQueue.write { db in
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
                    snapshotSlug,
                    "Chat memory \(id)",
                    snapshotJSON,
                    bodyHash,
                    citations.map(\.threadLogicalID).uniqued().count,
                    citations.map { $0.messageID ?? $0.crossDeviceHMAC }.uniqued().count,
                    now,
                    1,
                    now
                ]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by, created_at, updated_at,
                    source_kind, review_status, user_id, agent_id, run_id, app_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id,
                    storageProjectID,
                    request.kind.rawValue,
                    "chat",
                    request.confidence,
                    bodyRef,
                    bodyRef,
                    "[]",
                    nil,
                    now,
                    now,
                    now,
                    MemorySourceKind.chat.rawValue,
                    request.reviewStatus.rawValue,
                    request.scope.userID,
                    request.scope.agentID,
                    request.scope.runID,
                    request.scope.appID
                ]
            )
            for citation in citations {
                try db.execute(
                    sql: """
                    INSERT INTO memory_provenance (
                        id, memory_id, source_kind, thread_logical_id, message_id, role,
                        authored_at, content_hash, occurrence, xdevice_hmac, citation_state, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """,
                    arguments: [
                        citation.id,
                        id,
                        "chat_message",
                        citation.threadLogicalID,
                        citation.messageID,
                        citation.role,
                        citation.authoredAt,
                        citation.contentHash,
                        citation.occurrence,
                        citation.crossDeviceHMAC,
                        citation.citationState.rawValue,
                        now
                    ]
                )
            }
            let prevHash = try String.fetchOne(
                db,
                sql: "SELECT hash FROM memory_audit ORDER BY seq DESC LIMIT 1"
            )
            let auditHash = Self.sha256Hex(
                [
                    prevHash ?? "",
                    nowString,
                    "app",
                    "memory.add",
                    "memory",
                    storageProjectID,
                    id,
                    labelsJSON
                ].joined(separator: "|")
            )
            try db.execute(
                sql: """
                INSERT INTO memory_audit (
                    ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    now,
                    "app",
                    "memory.add",
                    "memory",
                    storageProjectID,
                    id,
                    labelsJSON,
                    prevHash,
                    auditHash
                ]
            )
        }

        return Memory(
            id: id,
            sourceKind: .chat,
            kind: request.kind,
            scope: request.scope,
            confidence: request.confidence,
            bodyRedacted: bodyRef,
            reviewStatus: request.reviewStatus,
            citations: citations,
            validFrom: now,
            createdAt: now,
            updatedAt: now
        )
    }

    func fetchChatMemoryAuthorityRecord(id: MemoryID) async throws -> Memory? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT *
                FROM agent_memories
                WHERE id = ? AND source_kind = ?
                LIMIT 1
                """,
                arguments: [id, MemorySourceKind.chat.rawValue]
            ) else {
                return nil
            }

            let citationRows = try Row.fetchAll(
                db,
                sql: """
                SELECT *
                FROM memory_provenance
                WHERE memory_id = ?
                ORDER BY authored_at ASC, occurrence ASC, id ASC
                """,
                arguments: [id]
            )
            let citations = citationRows.compactMap(Self.memoryCitation(from:))
            return Self.memory(from: row, citations: citations)
        }
    }

    func openChatMemoryBody(id: MemoryID) async throws -> String? {
        let snapshotSlug = Self.memorySnapshotSlug(id)
        return try await dbQueue.read { db in
            guard let snapshotJSON = try String.fetchOne(
                db,
                sql: "SELECT snapshotJSON FROM project_memory_snapshots WHERE projectSlug = ?",
                arguments: [snapshotSlug]
            ),
                  let data = snapshotJSON.data(using: .utf8)
            else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MemoryBodySnapshot.self, from: data).body
        }
    }

    func mutateControllerRuntimeMirror(
        cacheKey: String = "latest",
        _ mutate: (inout OpenBurnBarControllerRuntimeSnapshot) -> Void
    ) async throws {
        var snapshot = try await fetchControllerRuntimeMirror(cacheKey: cacheKey) ?? .empty
        mutate(&snapshot)
        try await saveControllerRuntimeMirror(snapshot, cacheKey: cacheKey)
    }

    private struct MemoryBodySnapshot: Codable {
        let schemaVersion: Int
        let memoryID: MemoryID
        let sourceKind: MemorySourceKind
        let bodyHash: String
        let body: String
        let citations: [MemoryCitation]
        let createdAt: Date
    }

    private static func memorySnapshotSlug(_ id: MemoryID) -> String {
        "memory-\(id)"
    }

    private static func memorySnapshotRef(_ slug: String) -> String {
        "project_memory_snapshots:\(slug)"
    }

    private static func memoryStorageProjectID(for scope: MemoryScope) -> String {
        scope.projectID ?? "chat:\(scope.userID ?? scope.appID ?? "unscoped")"
    }

    private static func memoryBodySnapshotJSON(
        memoryID: MemoryID,
        body: String,
        bodyHash: String,
        citations: [MemoryCitation],
        createdAt: Date
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = MemoryBodySnapshot(
            schemaVersion: 1,
            memoryID: memoryID,
            sourceKind: .chat,
            bodyHash: bodyHash,
            body: body,
            citations: citations,
            createdAt: createdAt
        )
        let data = try encoder.encode(payload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "OpenBurnBar.ChatMemory", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Chat memory body snapshot could not be encoded as UTF-8."
            ])
        }
        return json
    }

    private static func auditLabelsJSON(_ labels: [String: String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: labels.sorted { $0.key < $1.key }.reduce(into: [String: String]()) { acc, pair in
                acc[pair.key] = pair.value
            },
            options: [.sortedKeys]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func memory(from row: Row, citations: [MemoryCitation]) -> Memory? {
        guard let id: String = row["id"],
              let sourceKindRaw: String = row["source_kind"],
              let sourceKind = MemorySourceKind(rawValue: sourceKindRaw),
              let kindRaw: String = row["kind"],
              let kind = MemoryKind(rawValue: kindRaw),
              let confidence: Double = row["confidence"],
              let bodyRedacted: String = row["body_redacted"],
              let reviewStatusRaw: String = row["review_status"],
              let reviewStatus = MemoryReviewStatus(rawValue: reviewStatusRaw),
              let validFrom = OpenBurnBarDatabase.parseDateValue(row["valid_from"]),
              let createdAt = OpenBurnBarDatabase.parseDateValue(row["created_at"]),
              let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updated_at"])
        else {
            return nil
        }
        let scope = MemoryScope(
            userID: row["user_id"],
            agentID: row["agent_id"],
            runID: row["run_id"],
            appID: row["app_id"],
            projectID: row["project_id"]
        )
        return Memory(
            id: id,
            sourceKind: sourceKind,
            kind: kind,
            scope: scope,
            confidence: confidence,
            bodyRedacted: bodyRedacted,
            reviewStatus: reviewStatus,
            citations: citations,
            validFrom: validFrom,
            validTo: OpenBurnBarDatabase.parseDateValue(row["valid_to"]),
            supersededBy: row["superseded_by"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func memoryCitation(from row: Row) -> MemoryCitation? {
        guard let id: String = row["id"],
              let threadLogicalID: String = row["thread_logical_id"],
              let role: String = row["role"],
              let authoredAt = OpenBurnBarDatabase.parseDateValue(row["authored_at"]),
              let contentHash: String = row["content_hash"],
              let occurrence: Int = row["occurrence"],
              let crossDeviceHMAC: String = row["xdevice_hmac"],
              let citationStateRaw: String = row["citation_state"],
              let citationState = MemoryCitationState(rawValue: citationStateRaw)
        else {
            return nil
        }
        return MemoryCitation(
            id: id,
            threadLogicalID: threadLogicalID,
            messageID: row["message_id"],
            role: role,
            authoredAt: authoredAt,
            contentHash: contentHash,
            occurrence: occurrence,
            crossDeviceHMAC: crossDeviceHMAC,
            citationState: citationState
        )
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
