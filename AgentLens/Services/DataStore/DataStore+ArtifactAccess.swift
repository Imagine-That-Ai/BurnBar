import Foundation
import OpenBurnBarCore

extension DataStore {
    nonisolated func upsertSourceArtifact(_ artifact: SourceArtifactRecord) throws -> SourceArtifactWriteDisposition {
        try artifactStore.upsertSourceArtifact(artifact)
    }

    nonisolated func fetchSourceArtifacts(
        includeDeleted: Bool = false,
        rootPaths: [String]? = nil,
        sourceKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
    ) throws -> [SourceArtifactRecord] {
        try artifactStore.fetchSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    /// Paginated artifact fetch using offset-based cursor.
    nonisolated func fetchSourceArtifacts(
        includeDeleted: Bool,
        rootPaths: [String]?,
        sourceKinds: [SearchSourceKind],
        limit: Int,
        offset: Int
    ) throws -> [SourceArtifactRecord] {
        try artifactStore.fetchSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds,
            limit: limit,
            offset: offset
        )
    }

    nonisolated func countSourceArtifacts(
        includeDeleted: Bool = false,
        rootPaths: [String]? = nil,
        sourceKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
    ) throws -> Int {
        try artifactStore.countSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    nonisolated func fetchSourceArtifact(id: String, includeDeleted: Bool = false) throws -> SourceArtifactRecord? {
        try artifactStore.fetchSourceArtifact(id: id, includeDeleted: includeDeleted)
    }

    nonisolated func markSourceArtifactDeleted(id: String, deletedAt: Date = Date()) throws -> Bool {
        try artifactStore.markSourceArtifactDeleted(id: id, deletedAt: deletedAt)
    }

    nonisolated func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) throws {
        try artifactStore.upsertSharedArtifactSyncState(state)
    }

    nonisolated func fetchSharedArtifactSyncState(sourceArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try artifactStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID)
    }

    nonisolated func fetchSharedArtifactSyncState(remoteArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try artifactStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
    }

    nonisolated func fetchSharedArtifactSyncStates(
        workspaceID: String? = nil,
        teamID: String? = nil,
        statuses: [SharedArtifactSyncStatus]? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactSyncStateRecord] {
        try artifactStore.fetchSharedArtifactSyncStates(
            workspaceID: workspaceID,
            teamID: teamID,
            statuses: statuses,
            limit: limit
        )
    }

    nonisolated func countSharedArtifactSyncStates(
        workspaceID: String? = nil,
        teamID: String? = nil,
        statuses: [SharedArtifactSyncStatus]? = nil
    ) throws -> Int {
        try artifactStore.countSharedArtifactSyncStates(
            workspaceID: workspaceID,
            teamID: teamID,
            statuses: statuses
        )
    }

    nonisolated func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) throws -> SharedArtifactPermissionWriteDisposition {
        try artifactStore.upsertSharedArtifactPermission(permission)
    }

    nonisolated func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) throws {
        try artifactStore.replaceSharedArtifactPermissions(sourceArtifactID: sourceArtifactID, permissions: permissions)
    }

    nonisolated func fetchSharedArtifactPermissions(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        principalType: SharedArtifactPrincipalType? = nil,
        principalID: String? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactPermissionRecord] {
        try artifactStore.fetchSharedArtifactPermissions(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID,
            limit: limit
        )
    }

    nonisolated func countSharedArtifactPermissions(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        principalType: SharedArtifactPrincipalType? = nil,
        principalID: String? = nil
    ) throws -> Int {
        try artifactStore.countSharedArtifactPermissions(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            principalType: principalType,
            principalID: principalID
        )
    }

    nonisolated func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int = 2_000
    ) throws -> Set<String> {
        Set(try artifactStore.fetchReadableSharedArtifactSourceIDs(accessContext: accessContext, limit: limit))
    }

    nonisolated func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) throws {
        try artifactStore.appendSharedArtifactAuditEvent(event)
    }

    nonisolated func fetchSharedArtifactAuditEvents(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        actions: [SharedArtifactAuditAction]? = nil,
        limit: Int = 500
    ) throws -> [SharedArtifactAuditEventRecord] {
        try artifactStore.fetchSharedArtifactAuditEvents(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            actions: actions,
            limit: limit
        )
    }

    nonisolated func countSharedArtifactAuditEvents(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        actions: [SharedArtifactAuditAction]? = nil
    ) throws -> Int {
        try artifactStore.countSharedArtifactAuditEvents(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            actions: actions
        )
    }
}
