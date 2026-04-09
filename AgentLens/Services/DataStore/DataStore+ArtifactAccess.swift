import Foundation
import OpenBurnBarCore

extension DataStore {
    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) throws -> SourceArtifactWriteDisposition {
        try artifactStore.upsertSourceArtifact(artifact)
    }

    func fetchSourceArtifacts(
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
    func fetchSourceArtifacts(
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

    func countSourceArtifacts(
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

    func fetchSourceArtifact(id: String, includeDeleted: Bool = false) throws -> SourceArtifactRecord? {
        try artifactStore.fetchSourceArtifact(id: id, includeDeleted: includeDeleted)
    }

    func markSourceArtifactDeleted(id: String, deletedAt: Date = Date()) throws -> Bool {
        try artifactStore.markSourceArtifactDeleted(id: id, deletedAt: deletedAt)
    }

    func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) throws {
        try artifactStore.upsertSharedArtifactSyncState(state)
    }

    func fetchSharedArtifactSyncState(sourceArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try artifactStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID)
    }

    func fetchSharedArtifactSyncState(remoteArtifactID: String) throws -> SharedArtifactSyncStateRecord? {
        try artifactStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
    }

    func fetchSharedArtifactSyncStates(
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

    func countSharedArtifactSyncStates(
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

    func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) throws -> SharedArtifactPermissionWriteDisposition {
        try artifactStore.upsertSharedArtifactPermission(permission)
    }

    func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) throws {
        try artifactStore.replaceSharedArtifactPermissions(sourceArtifactID: sourceArtifactID, permissions: permissions)
    }

    func fetchSharedArtifactPermissions(
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

    func countSharedArtifactPermissions(
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

    func fetchReadableSharedArtifactSourceIDs(
        accessContext: SharedArtifactAccessContext,
        limit: Int = 2_000
    ) throws -> Set<String> {
        Set(try artifactStore.fetchReadableSharedArtifactSourceIDs(accessContext: accessContext, limit: limit))
    }

    func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) throws {
        try artifactStore.appendSharedArtifactAuditEvent(event)
    }

    func fetchSharedArtifactAuditEvents(
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

    func countSharedArtifactAuditEvents(
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
