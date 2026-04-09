import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ArtifactStore

/// Source artifacts, shared-artifact sync state, permissions, and audit rows.
final class ArtifactStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Source Artifacts

    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) throws -> SourceArtifactWriteDisposition {
        guard artifact.sourceKind != .conversation else {
            throw NSError(
                domain: "DataStore.SourceArtifact",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "source_artifacts cannot store conversation sourceKind"]
            )
        }

        return try dbQueue.write { db in
            let existingRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM source_artifacts WHERE id = ?",
                arguments: [artifact.id]
            )
            let existing = existingRow.flatMap(Self.sourceArtifact(from:))

            if let existing {
                let isUnchanged =
                    existing.status == .active
                    && existing.sourceKind == artifact.sourceKind
                    && existing.canonicalPath == artifact.canonicalPath
                    && existing.rootPath == artifact.rootPath
                    && existing.relativePath == artifact.relativePath
                    && existing.provenance == artifact.provenance
                    && existing.title == artifact.title
                    && existing.body == artifact.body
                    && existing.contentHash == artifact.contentHash
                    && existing.fileSizeBytes == artifact.fileSizeBytes
                    && existing.fileModifiedAt == artifact.fileModifiedAt

                if isUnchanged {
                    try db.execute(
                        sql: """
                        UPDATE source_artifacts
                        SET discoveredAt = ?, updatedAt = ?
                        WHERE id = ?
                        """,
                        arguments: [artifact.discoveredAt, artifact.updatedAt, artifact.id]
                    )
                    return .unchanged
                }
                let disposition: SourceArtifactWriteDisposition = existing.status == .deleted ? .restored : .updated

                try db.execute(
                    sql: """
                    INSERT INTO source_artifacts (
                        id, sourceKind, canonicalPath, rootPath, relativePath, provenance,
                        title, body, contentHash, fileSizeBytes, fileModifiedAt, status,
                        discoveredAt, deletedAt, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        sourceKind = excluded.sourceKind,
                        canonicalPath = excluded.canonicalPath,
                        rootPath = excluded.rootPath,
                        relativePath = excluded.relativePath,
                        provenance = excluded.provenance,
                        title = excluded.title,
                        body = excluded.body,
                        contentHash = excluded.contentHash,
                        fileSizeBytes = excluded.fileSizeBytes,
                        fileModifiedAt = excluded.fileModifiedAt,
                        status = excluded.status,
                        discoveredAt = excluded.discoveredAt,
                        deletedAt = excluded.deletedAt,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        artifact.id,
                        artifact.sourceKind.rawValue,
                        artifact.canonicalPath,
                        artifact.rootPath,
                        artifact.relativePath,
                        artifact.provenance,
                        artifact.title,
                        artifact.body,
                        artifact.contentHash,
                        artifact.fileSizeBytes,
                        artifact.fileModifiedAt,
                        SourceArtifactStatus.active.rawValue,
                        artifact.discoveredAt,
                        nil,
                        artifact.createdAt,
                        artifact.updatedAt
                    ]
                )
                return disposition
            } else {
                try db.execute(
                    sql: """
                    INSERT INTO source_artifacts (
                        id, sourceKind, canonicalPath, rootPath, relativePath, provenance,
                        title, body, contentHash, fileSizeBytes, fileModifiedAt, status,
                        discoveredAt, deletedAt, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        sourceKind = excluded.sourceKind,
                        canonicalPath = excluded.canonicalPath,
                        rootPath = excluded.rootPath,
                        relativePath = excluded.relativePath,
                        provenance = excluded.provenance,
                        title = excluded.title,
                        body = excluded.body,
                        contentHash = excluded.contentHash,
                        fileSizeBytes = excluded.fileSizeBytes,
                        fileModifiedAt = excluded.fileModifiedAt,
                        status = excluded.status,
                        discoveredAt = excluded.discoveredAt,
                        deletedAt = excluded.deletedAt,
                        updatedAt = excluded.updatedAt
                    """,
                    arguments: [
                        artifact.id,
                        artifact.sourceKind.rawValue,
                        artifact.canonicalPath,
                        artifact.rootPath,
                        artifact.relativePath,
                        artifact.provenance,
                        artifact.title,
                        artifact.body,
                        artifact.contentHash,
                        artifact.fileSizeBytes,
                        artifact.fileModifiedAt,
                        SourceArtifactStatus.active.rawValue,
                        artifact.discoveredAt,
                        nil,
                        artifact.createdAt,
                        artifact.updatedAt
                    ]
                )
                return .inserted
            }
        }
    }

    func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) throws -> [SourceArtifactRecord] {
        guard sourceKinds.isEmpty == false else { return [] }
        let normalizedRoots = (rootPaths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kindValues = sourceKinds.map(\.rawValue)
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if includeDeleted == false {
            clauses.append("status != ?")
            args.append(SourceArtifactStatus.deleted.rawValue)
        }

        clauses.append("sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: kindValues.count)))")
        args.append(contentsOf: kindValues)

        if normalizedRoots.isEmpty == false {
            clauses.append("rootPath IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedRoots.count)))")
            args.append(contentsOf: normalizedRoots)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM source_artifacts
                \(whereSQL)
                ORDER BY rootPath ASC, relativePath ASC
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sourceArtifact(from:))
        }
    }

    /// Paginated artifact fetch using offset-based cursor.
    func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind],
        limit: Int,
        offset: Int
    ) throws -> [SourceArtifactRecord] {
        guard sourceKinds.isEmpty == false else { return [] }
        let normalizedRoots = (rootPaths ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let kindValues = sourceKinds.map(\.rawValue)
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if includeDeleted == false {
            clauses.append("status != ?")
            args.append(SourceArtifactStatus.deleted.rawValue)
        }

        clauses.append("sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: kindValues.count)))")
        args.append(contentsOf: kindValues)

        if normalizedRoots.isEmpty == false {
            clauses.append("rootPath IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedRoots.count)))")
            args.append(contentsOf: normalizedRoots)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        args.append(limit)
        args.append(offset)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM source_artifacts
                \(whereSQL)
                ORDER BY rootPath ASC, relativePath ASC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sourceArtifact(from:))
        }
    }

    func countSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind]
    ) throws -> Int {
        guard sourceKinds.isEmpty == false else { return 0 }
        let normalizedRoots = (rootPaths ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let kindValues = sourceKinds.map(\.rawValue)
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if includeDeleted == false {
            clauses.append("status != ?")
            args.append(SourceArtifactStatus.deleted.rawValue)
        }

        clauses.append("sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: kindValues.count)))")
        args.append(contentsOf: kindValues)

        if normalizedRoots.isEmpty == false {
            clauses.append("rootPath IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedRoots.count)))")
            args.append(contentsOf: normalizedRoots)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM source_artifacts
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func fetchSourceArtifact(id: String, includeDeleted: Bool) throws -> SourceArtifactRecord? {
        try dbQueue.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM source_artifacts WHERE id = ?",
                    arguments: [id]
                ),
                let artifact = Self.sourceArtifact(from: row)
            else {
                return nil
            }
            if includeDeleted == false, artifact.status == .deleted {
                return nil
            }
            return artifact
        }
    }

    @discardableResult
    func markSourceArtifactDeleted(id: String, deletedAt: Date) throws -> Bool {
        try dbQueue.write { db in
            guard
                let row = try Row.fetchOne(db, sql: "SELECT * FROM source_artifacts WHERE id = ?", arguments: [id]),
                let existing = Self.sourceArtifact(from: row),
                existing.status != .deleted
            else {
                return false
            }
            try db.execute(
                sql: """
                UPDATE source_artifacts
                SET status = ?, deletedAt = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [SourceArtifactStatus.deleted.rawValue, deletedAt, deletedAt, id]
            )
            return true
        }
    }

    // MARK: - Shared Artifact Sync State

    func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO shared_artifact_sync_state (
                    sourceArtifactID, remoteArtifactID, workspaceID, teamID, ownerUserID,
                    revisionID, remoteContentHash, localContentHashAtSync, remoteUpdatedAt,
                    lastPulledAt, lastSyncedAt, syncStatus, lastErrorCode, lastErrorMessage,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceArtifactID) DO UPDATE SET
                    remoteArtifactID = excluded.remoteArtifactID,
                    workspaceID = excluded.workspaceID,
                    teamID = excluded.teamID,
                    ownerUserID = excluded.ownerUserID,
                    revisionID = excluded.revisionID,
                    remoteContentHash = excluded.remoteContentHash,
                    localContentHashAtSync = excluded.localContentHashAtSync,
                    remoteUpdatedAt = excluded.remoteUpdatedAt,
                    lastPulledAt = excluded.lastPulledAt,
                    lastSyncedAt = excluded.lastSyncedAt,
                    syncStatus = excluded.syncStatus,
                    lastErrorCode = excluded.lastErrorCode,
                    lastErrorMessage = excluded.lastErrorMessage,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    state.sourceArtifactID,
                    state.remoteArtifactID,
                    state.workspaceID,
                    state.teamID,
                    state.ownerUserID,
                    state.revisionID,
                    state.remoteContentHash,
                    state.localContentHashAtSync,
                    state.remoteUpdatedAt,
                    state.lastPulledAt,
                    state.lastSyncedAt,
                    state.syncStatus.rawValue,
                    state.lastErrorCode,
                    state.lastErrorMessage,
                    state.createdAt,
                    state.updatedAt
                ]
            )
        }
    }

    func fetchSharedArtifactSyncState(sourceArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM shared_artifact_sync_state WHERE sourceArtifactID = ?",
                arguments: [sourceArtifactID]
            ) else { return nil }
            return Self.sharedArtifactSyncState(from: row)
        }
    }

    func fetchSharedArtifactSyncState(remoteArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM shared_artifact_sync_state WHERE remoteArtifactID = ?",
                arguments: [remoteArtifactID]
            ) else { return nil }
            return Self.sharedArtifactSyncState(from: row)
        }
    }

    func fetchSharedArtifactSyncStates(
        workspaceID: String?,
        teamID: String?,
        statuses: [SharedArtifactSyncStatus]?,
        limit: Int
    ) throws -> [SharedArtifactSyncStateRecord] {
        if let statuses, statuses.isEmpty { return [] }

        let normalizedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let normalizedWorkspaceID, normalizedWorkspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(normalizedWorkspaceID)
        }

        if let normalizedTeamID, normalizedTeamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(normalizedTeamID)
        }

        if let statuses, statuses.isEmpty == false {
            clauses.append("syncStatus IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: statuses.count)))")
            args.append(contentsOf: statuses.map(\.rawValue))
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM shared_artifact_sync_state
                \(whereSQL)
                ORDER BY updatedAt DESC, sourceArtifactID ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactSyncState(from:))
        }
    }

    func countSharedArtifactSyncStates(
        workspaceID: String?,
        teamID: String?,
        statuses: [SharedArtifactSyncStatus]?
    ) throws -> Int {
        if let statuses, statuses.isEmpty { return 0 }

        let normalizedWorkspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let normalizedWorkspaceID, normalizedWorkspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(normalizedWorkspaceID)
        }

        if let normalizedTeamID, normalizedTeamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(normalizedTeamID)
        }

        if let statuses, statuses.isEmpty == false {
            clauses.append("syncStatus IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: statuses.count)))")
            args.append(contentsOf: statuses.map(\.rawValue))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM shared_artifact_sync_state
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    // MARK: - Permissions

    func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) throws -> SharedArtifactPermissionWriteDisposition {
        try dbQueue.write { db in
            let existingRow = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM artifact_permissions
                WHERE sourceArtifactID = ? AND principalType = ? AND principalID = ?
                """,
                arguments: [permission.sourceArtifactID, permission.principalType.rawValue, permission.principalID]
            )
            let existing = existingRow.flatMap(Self.sharedArtifactPermission(from:))
            if let existing, Self.permissionSemanticsEqual(existing, permission) {
                return .unchanged
            }

            let createdAt = existing?.createdAt ?? permission.createdAt
            try db.execute(
                sql: """
                INSERT INTO artifact_permissions (
                    sourceArtifactID, workspaceID, teamID, principalType, principalID,
                    role, visibility, canRead, canWrite, canShare, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sourceArtifactID, principalType, principalID) DO UPDATE SET
                    workspaceID = excluded.workspaceID,
                    teamID = excluded.teamID,
                    role = excluded.role,
                    visibility = excluded.visibility,
                    canRead = excluded.canRead,
                    canWrite = excluded.canWrite,
                    canShare = excluded.canShare,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    permission.sourceArtifactID,
                    permission.workspaceID,
                    permission.teamID,
                    permission.principalType.rawValue,
                    permission.principalID,
                    permission.role.rawValue,
                    permission.visibility.rawValue,
                    permission.canRead,
                    permission.canWrite,
                    permission.canShare,
                    createdAt,
                    permission.updatedAt
                ]
            )
            return existing == nil ? .inserted : .updated
        }
    }

    func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM artifact_permissions WHERE sourceArtifactID = ?",
                arguments: [sourceArtifactID]
            )
            guard permissions.isEmpty == false else { return }

            for permission in permissions {
                guard permission.sourceArtifactID == sourceArtifactID else { continue }
                try db.execute(
                    sql: """
                    INSERT INTO artifact_permissions (
                        sourceArtifactID, workspaceID, teamID, principalType, principalID,
                        role, visibility, canRead, canWrite, canShare, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        permission.sourceArtifactID,
                        permission.workspaceID,
                        permission.teamID,
                        permission.principalType.rawValue,
                        permission.principalID,
                        permission.role.rawValue,
                        permission.visibility.rawValue,
                        permission.canRead,
                        permission.canWrite,
                        permission.canShare,
                        permission.createdAt,
                        permission.updatedAt
                    ]
                )
            }
        }
    }

    func fetchSharedArtifactPermissions(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        principalType: SharedArtifactPrincipalType?,
        principalID: String?,
        limit: Int
    ) throws -> [SharedArtifactPermissionRecord] {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let principalType {
            clauses.append("principalType = ?")
            args.append(principalType.rawValue)
        }
        if let principalID = principalID?.trimmingCharacters(in: .whitespacesAndNewlines), principalID.isEmpty == false {
            clauses.append("principalID = ?")
            args.append(principalID)
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM artifact_permissions
                \(whereSQL)
                ORDER BY updatedAt DESC, sourceArtifactID ASC, principalType ASC, principalID ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactPermission(from:))
        }
    }

    func countSharedArtifactPermissions(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        principalType: SharedArtifactPrincipalType?,
        principalID: String?
    ) throws -> Int {
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let principalType {
            clauses.append("principalType = ?")
            args.append(principalType.rawValue)
        }
        if let principalID = principalID?.trimmingCharacters(in: .whitespacesAndNewlines), principalID.isEmpty == false {
            clauses.append("principalID = ?")
            args.append(principalID)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM artifact_permissions
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int
    ) throws -> [String] {
        guard limit > 0 else { return [] }

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT DISTINCT s.id AS sourceArtifactID
                FROM source_artifacts AS s
                LEFT JOIN shared_artifact_sync_state AS sas
                    ON sas.sourceArtifactID = s.id
                WHERE s.sourceKind = ?
                  AND s.status = ?
                  AND (
                      EXISTS (
                          SELECT 1
                          FROM artifact_permissions AS ap
                          WHERE ap.sourceArtifactID = s.id
                            AND ap.canRead = 1
                            AND ap.workspaceID = ?
                            AND (
                                (ap.principalType = ? AND ap.principalID = ?)
                                OR (ap.principalType = ? AND ap.principalID = ? AND ap.teamID = ?)
                                OR (ap.principalType = ? AND ap.principalID = ?)
                            )
                      )
                      OR (
                          sas.workspaceID = ?
                          AND sas.teamID = ?
                          AND sas.ownerUserID = ?
                      )
                  )
                ORDER BY s.updatedAt DESC, s.id ASC
                LIMIT ?
                """,
                arguments: [
                    SearchSourceKind.sharedArtifact.rawValue,
                    SourceArtifactStatus.active.rawValue,
                    accessContext.workspaceID,
                    SharedArtifactPrincipalType.user.rawValue,
                    accessContext.userID,
                    SharedArtifactPrincipalType.team.rawValue,
                    accessContext.teamID,
                    accessContext.teamID,
                    SharedArtifactPrincipalType.workspace.rawValue,
                    accessContext.workspaceID,
                    accessContext.workspaceID,
                    accessContext.teamID,
                    accessContext.userID,
                    limit
                ]
            )
            return rows.compactMap { $0["sourceArtifactID"] as? String }
        }
    }

    // MARK: - Audit Events

    func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO audit_events (
                    id, sourceArtifactID, remoteArtifactID, workspaceID, teamID,
                    actorUserID, actorRole, action, detailsJSON, occurredAt, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
                arguments: [
                    event.id,
                    event.sourceArtifactID,
                    event.remoteArtifactID,
                    event.workspaceID,
                    event.teamID,
                    event.actorUserID,
                    event.actorRole?.rawValue,
                    event.action.rawValue,
                    event.detailsJSON,
                    event.occurredAt,
                    event.createdAt
                ]
            )
        }
    }

    func fetchSharedArtifactAuditEvents(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        actions: [SharedArtifactAuditAction]?,
        limit: Int
    ) throws -> [SharedArtifactAuditEventRecord] {
        if let actions, actions.isEmpty { return [] }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let actions, actions.isEmpty == false {
            clauses.append("action IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: actions.count)))")
            args.append(contentsOf: actions.map(\.rawValue))
        }

        args.append(max(1, limit))
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM audit_events
                \(whereSQL)
                ORDER BY occurredAt DESC, id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(args)
            )
            return rows.compactMap(Self.sharedArtifactAuditEvent(from:))
        }
    }

    func countSharedArtifactAuditEvents(
        sourceArtifactID: String?,
        workspaceID: String?,
        teamID: String?,
        actions: [SharedArtifactAuditAction]?
    ) throws -> Int {
        if let actions, actions.isEmpty { return 0 }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let sourceArtifactID = sourceArtifactID?.trimmingCharacters(in: .whitespacesAndNewlines), sourceArtifactID.isEmpty == false {
            clauses.append("sourceArtifactID = ?")
            args.append(sourceArtifactID)
        }
        if let workspaceID = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), workspaceID.isEmpty == false {
            clauses.append("workspaceID = ?")
            args.append(workspaceID)
        }
        if let teamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines), teamID.isEmpty == false {
            clauses.append("teamID = ?")
            args.append(teamID)
        }
        if let actions, actions.isEmpty == false {
            clauses.append("action IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: actions.count)))")
            args.append(contentsOf: actions.map(\.rawValue))
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM audit_events
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    // MARK: - Row Decoding

    static func sourceArtifact(from row: Row) -> SourceArtifactRecord? {
        guard
            let id = row["id"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let canonicalPath = row["canonicalPath"] as? String,
            let rootPath = row["rootPath"] as? String,
            let relativePath = row["relativePath"] as? String,
            let provenance = row["provenance"] as? String,
            let title = row["title"] as? String,
            let body = row["body"] as? String,
            let contentHash = row["contentHash"] as? String
        else {
            return nil
        }
        let fileSizeBytes = (row["fileSizeBytes"] as? Int) ?? Int(row["fileSizeBytes"] as? Int64 ?? 0)
        let discoveredAt = OpenBurnBarDatabase.parseDateValue(row["discoveredAt"]) ?? Date()
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? discoveredAt
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        let deletedAt = OpenBurnBarDatabase.parseDateValue(row["deletedAt"])
        let statusRaw = (row["status"] as? String) ?? SourceArtifactStatus.active.rawValue
        let status = SourceArtifactStatus(rawValue: statusRaw) ?? .active

        return SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: canonicalPath,
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: provenance,
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: fileSizeBytes,
            fileModifiedAt: OpenBurnBarDatabase.parseDateValue(row["fileModifiedAt"]),
            status: status,
            discoveredAt: discoveredAt,
            deletedAt: deletedAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func sharedArtifactSyncState(from row: Row) -> SharedArtifactSyncStateRecord? {
        guard
            let sourceArtifactID = row["sourceArtifactID"] as? String,
            let remoteArtifactID = row["remoteArtifactID"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let revisionID = row["revisionID"] as? String
        else {
            return nil
        }

        let statusRaw = (row["syncStatus"] as? String) ?? SharedArtifactSyncStatus.pendingPull.rawValue
        let syncStatus = SharedArtifactSyncStatus(rawValue: statusRaw) ?? .pendingPull
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt

        return SharedArtifactSyncStateRecord(
            sourceArtifactID: sourceArtifactID,
            remoteArtifactID: remoteArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            ownerUserID: row["ownerUserID"] as? String,
            revisionID: revisionID,
            remoteContentHash: row["remoteContentHash"] as? String,
            localContentHashAtSync: row["localContentHashAtSync"] as? String,
            remoteUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["remoteUpdatedAt"]),
            lastPulledAt: OpenBurnBarDatabase.parseDateValue(row["lastPulledAt"]),
            lastSyncedAt: OpenBurnBarDatabase.parseDateValue(row["lastSyncedAt"]),
            syncStatus: syncStatus,
            lastErrorCode: row["lastErrorCode"] as? String,
            lastErrorMessage: row["lastErrorMessage"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func sharedArtifactPermission(from row: Row) -> SharedArtifactPermissionRecord? {
        guard
            let sourceArtifactID = row["sourceArtifactID"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let principalTypeRaw = row["principalType"] as? String,
            let principalType = SharedArtifactPrincipalType(rawValue: principalTypeRaw),
            let principalID = row["principalID"] as? String,
            let roleRaw = row["role"] as? String,
            let role = SharedArtifactRole(rawValue: roleRaw),
            let visibilityRaw = row["visibility"] as? String,
            let visibility = SharedArtifactVisibility(rawValue: visibilityRaw)
        else {
            return nil
        }

        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date()
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt

        return SharedArtifactPermissionRecord(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID,
            role: role,
            visibility: visibility,
            canRead: OpenBurnBarDatabase.parseBoolValue(row["canRead"]) ?? true,
            canWrite: OpenBurnBarDatabase.parseBoolValue(row["canWrite"]) ?? false,
            canShare: OpenBurnBarDatabase.parseBoolValue(row["canShare"]) ?? false,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func sharedArtifactAuditEvent(from row: Row) -> SharedArtifactAuditEventRecord? {
        guard
            let id = row["id"] as? String,
            let workspaceID = row["workspaceID"] as? String,
            let teamID = row["teamID"] as? String,
            let actionRaw = row["action"] as? String,
            let action = SharedArtifactAuditAction(rawValue: actionRaw)
        else {
            return nil
        }
        let occurredAt = OpenBurnBarDatabase.parseDateValue(row["occurredAt"]) ?? Date()
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? occurredAt
        let actorRole = (row["actorRole"] as? String).flatMap(SharedArtifactRole.init(rawValue:))

        return SharedArtifactAuditEventRecord(
            id: id,
            sourceArtifactID: row["sourceArtifactID"] as? String,
            remoteArtifactID: row["remoteArtifactID"] as? String,
            workspaceID: workspaceID,
            teamID: teamID,
            actorUserID: row["actorUserID"] as? String,
            actorRole: actorRole,
            action: action,
            detailsJSON: row["detailsJSON"] as? String,
            occurredAt: occurredAt,
            createdAt: createdAt
        )
    }

    private static func permissionSemanticsEqual(
        _ lhs: SharedArtifactPermissionRecord,
        _ rhs: SharedArtifactPermissionRecord
    ) -> Bool {
        lhs.sourceArtifactID == rhs.sourceArtifactID
            && lhs.workspaceID == rhs.workspaceID
            && lhs.teamID == rhs.teamID
            && lhs.principalType == rhs.principalType
            && lhs.principalID == rhs.principalID
            && lhs.role == rhs.role
            && lhs.visibility == rhs.visibility
            && lhs.canRead == rhs.canRead
            && lhs.canWrite == rhs.canWrite
            && lhs.canShare == rhs.canShare
    }
}
