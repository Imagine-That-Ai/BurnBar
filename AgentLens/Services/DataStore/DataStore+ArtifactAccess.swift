import Foundation
import OpenBurnBarCore

extension DataStore {
    func upsertSourceArtifact(_ artifact: SourceArtifactRecord) async throws -> SourceArtifactWriteDisposition {
        try await actor.artifactStore.upsertSourceArtifact(artifact)
    }

    func fetchSourceArtifacts(
        includeDeleted: Bool = false,
        rootPaths: [String]? = nil,
        sourceKinds: [SearchSourceKind] = [.skillDoc, .agentDoc, .sharedArtifact]
    ) async throws -> [SourceArtifactRecord] {
        try await actor.artifactStore.fetchSourceArtifacts(
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
    ) async throws -> [SourceArtifactRecord] {
        try await actor.artifactStore.fetchSourceArtifacts(
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
    ) async throws -> Int {
        try await actor.artifactStore.countSourceArtifacts(
            includeDeleted: includeDeleted,
            rootPaths: rootPaths,
            sourceKinds: sourceKinds
        )
    }

    func fetchSourceArtifact(id: String, includeDeleted: Bool = false) async throws -> SourceArtifactRecord? {
        try await actor.artifactStore.fetchSourceArtifact(id: id, includeDeleted: includeDeleted)
    }

    func markSourceArtifactDeleted(id: String, deletedAt: Date = Date()) async throws -> Bool {
        try await actor.artifactStore.markSourceArtifactDeleted(id: id, deletedAt: deletedAt)
    }

    func upsertSharedArtifactSyncState(_ state: SharedArtifactSyncStateRecord) async throws {
        try await actor.artifactStore.upsertSharedArtifactSyncState(state)
    }

    func fetchSharedArtifactSyncState(sourceArtifactID: String) async throws -> SharedArtifactSyncStateRecord? {
        try await actor.artifactStore.fetchSharedArtifactSyncState(sourceArtifactID: sourceArtifactID)
    }

    func fetchSharedArtifactSyncState(remoteArtifactID: String) async throws -> SharedArtifactSyncStateRecord? {
        try await actor.artifactStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
    }

    func fetchSharedArtifactSyncStates(
        workspaceID: String? = nil,
        teamID: String? = nil,
        statuses: [SharedArtifactSyncStatus]? = nil,
        limit: Int = 500
    ) async throws -> [SharedArtifactSyncStateRecord] {
        try await actor.artifactStore.fetchSharedArtifactSyncStates(
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
    ) async throws -> Int {
        try await actor.artifactStore.countSharedArtifactSyncStates(
            workspaceID: workspaceID,
            teamID: teamID,
            statuses: statuses
        )
    }

    func countSharedArtifactSyncStatesByStatus(
        workspaceID: String? = nil,
        teamID: String? = nil
    ) async throws -> [SharedArtifactSyncStatus: Int] {
        try await actor.artifactStore.countSharedArtifactSyncStatesByStatus(
            workspaceID: workspaceID,
            teamID: teamID
        )
    }

    func upsertSharedArtifactPermission(_ permission: SharedArtifactPermissionRecord) async throws -> SharedArtifactPermissionWriteDisposition {
        try await actor.artifactStore.upsertSharedArtifactPermission(permission)
    }

    func replaceSharedArtifactPermissions(
        sourceArtifactID: String,
        permissions: [SharedArtifactPermissionRecord]
    ) async throws {
        try await actor.artifactStore.replaceSharedArtifactPermissions(sourceArtifactID: sourceArtifactID, permissions: permissions)
    }

    func fetchSharedArtifactPermissions(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        principalType: SharedArtifactPrincipalType? = nil,
        principalID: String? = nil,
        limit: Int = 500
    ) async throws -> [SharedArtifactPermissionRecord] {
        try await actor.artifactStore.fetchSharedArtifactPermissions(
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
    ) async throws -> Int {
        try await actor.artifactStore.countSharedArtifactPermissions(
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
    ) async throws -> Set<String> {
        Set(try await actor.artifactStore.fetchReadableSharedArtifactSourceIDs(accessContext: accessContext, limit: limit))
    }

    func appendSharedArtifactAuditEvent(_ event: SharedArtifactAuditEventRecord) async throws {
        try await actor.artifactStore.appendSharedArtifactAuditEvent(event)
    }

    func fetchSharedArtifactAuditEvents(
        sourceArtifactID: String? = nil,
        workspaceID: String? = nil,
        teamID: String? = nil,
        actions: [SharedArtifactAuditAction]? = nil,
        limit: Int = 500
    ) async throws -> [SharedArtifactAuditEventRecord] {
        try await actor.artifactStore.fetchSharedArtifactAuditEvents(
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
    ) async throws -> Int {
        try await actor.artifactStore.countSharedArtifactAuditEvents(
            sourceArtifactID: sourceArtifactID,
            workspaceID: workspaceID,
            teamID: teamID,
            actions: actions
        )
    }
}
