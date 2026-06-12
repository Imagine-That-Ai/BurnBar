import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class SharedArtifactSyncStateStoreTests: XCTestCase {
    func test_sharedArtifactSyncStateStore_roundTripLookupAndFiltering() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_112_000)

        let artifact = SourceArtifactRecord(
            id: "shared-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace/team/shared-artifact-1.md",
            rootPath: "shared://workspace/team",
            relativePath: "shared-artifact-1.md",
            provenance: SharedArtifactCloudCodec.encodeProvenance(
                workspaceID: "workspace-a",
                teamID: "team-a",
                remoteArtifactID: "remote-1",
                ownerUserID: "user-1"
            ),
            title: "Shared Artifact",
            body: "# Shared\nv1",
            contentHash: "hash-shared-v1",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        let syncedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            revisionID: "rev-1",
            remoteContentHash: "hash-shared-v1",
            localContentHashAtSync: "hash-shared-v1",
            remoteUpdatedAt: base,
            lastPulledAt: base,
            lastSyncedAt: base,
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: base,
            updatedAt: base
        )
        try store.upsertSharedArtifactSyncState(syncedState)

        let fetchedBySource = try store.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(fetchedBySource?.remoteArtifactID, "remote-1")
        XCTAssertEqual(fetchedBySource?.syncStatus, .synced)

        let fetchedByRemote = try store.fetchSharedArtifactSyncState(remoteArtifactID: "remote-1")
        XCTAssertEqual(fetchedByRemote?.sourceArtifactID, artifact.id)

        let conflictedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            revisionID: "rev-2",
            remoteContentHash: "hash-remote-v2",
            localContentHashAtSync: "hash-shared-v1",
            remoteUpdatedAt: base.addingTimeInterval(30),
            lastPulledAt: base.addingTimeInterval(30),
            lastSyncedAt: base,
            syncStatus: .conflicted,
            lastErrorCode: "SHARED_ARTIFACT_DIVERGED",
            lastErrorMessage: "Local and remote content diverged.",
            createdAt: base,
            updatedAt: base.addingTimeInterval(30)
        )
        try store.upsertSharedArtifactSyncState(conflictedState)

        let conflicted = try store.fetchSharedArtifactSyncStates(
            workspaceID: "workspace-a",
            teamID: "team-a",
            statuses: [.conflicted],
            limit: 20
        )
        XCTAssertEqual(conflicted.count, 1)
        XCTAssertEqual(conflicted.first?.lastErrorCode, "SHARED_ARTIFACT_DIVERGED")
    }

    func test_sharedArtifactPermissionStore_roundTripFilteringAndReadableLookup() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_125_000)

        let artifact = SourceArtifactRecord(
            id: "shared-permission-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/shared-permission-artifact-1.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "shared-permission-artifact-1.md",
            provenance: "shared-sync:workspace-a|team-a|remote-perm-1|user-1",
            title: "Shared Permission Artifact",
            body: "# Shared\npermissions",
            contentHash: "hash-perm-v1",
            fileSizeBytes: 24,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)

        let ownerPermission = SharedArtifactPermissionRecord(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            role: .owner,
            visibility: .team,
            canRead: true,
            canWrite: true,
            canShare: true,
            createdAt: base,
            updatedAt: base
        )
        XCTAssertEqual(try store.upsertSharedArtifactPermission(ownerPermission), .inserted)
        XCTAssertEqual(try store.upsertSharedArtifactPermission(ownerPermission), .unchanged)

        let updatedOwnerPermission = SharedArtifactPermissionRecord(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            role: .editor,
            visibility: .team,
            canRead: true,
            canWrite: true,
            canShare: false,
            createdAt: base,
            updatedAt: base.addingTimeInterval(15)
        )
        XCTAssertEqual(try store.upsertSharedArtifactPermission(updatedOwnerPermission), .updated)

        let fetchedPermissions = try store.fetchSharedArtifactPermissions(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            principalType: .user,
            principalID: "user-1",
            limit: 10
        )
        XCTAssertEqual(fetchedPermissions.count, 1)
        XCTAssertEqual(fetchedPermissions.first?.role, .editor)
        XCTAssertEqual(fetchedPermissions.first?.canShare, false)

        let readableForOwner = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-1",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertEqual(readableForOwner, Set([artifact.id]))

        let readableForOther = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-2",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertTrue(readableForOther.isEmpty)
    }

    func test_sharedArtifactReadableLookup_includesSyncOwnerFallback() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_127_500)

        let artifact = SourceArtifactRecord(
            id: "shared-owner-fallback-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/shared-owner-fallback-1.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "shared-owner-fallback-1.md",
            provenance: "shared-sync:workspace-a|team-a|remote-owner-1|user-owner",
            title: "Shared Owner Fallback",
            body: "owner fallback",
            contentHash: "hash-owner-fallback",
            fileSizeBytes: 14,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-owner-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-owner",
                revisionID: "rev-owner-1",
                remoteContentHash: "hash-owner-fallback",
                localContentHashAtSync: "hash-owner-fallback",
                remoteUpdatedAt: base,
                lastPulledAt: base,
                lastSyncedAt: base,
                syncStatus: .synced,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: base,
                updatedAt: base
            )
        )

        let ownerReadable = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-owner",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertEqual(ownerReadable, Set([artifact.id]))

        let otherReadable = try store.fetchReadableSharedArtifactSourceIDs(
            accessContext: SharedArtifactAccessContext(
                userID: "user-other",
                workspaceID: "workspace-a",
                teamID: "team-a"
            )
        )
        XCTAssertTrue(otherReadable.isEmpty)
    }

    func test_sharedArtifactCloudCodec_roundTripSerialization() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_742_130_000)
        let record = SharedArtifactCloudRecord(
            artifactID: "remote-42",
            workspaceID: "workspace-a",
            teamID: "team-a",
            ownerUserID: "user-1",
            visibility: .workspace,
            revisionID: "rev-42",
            baseRevisionID: "rev-41",
            title: "Shared Runbook",
            body: "Body content",
            contentHash: "hash-42",
            relativePath: "docs/runbook.md",
            isDeleted: false,
            updatedByUserID: "user-2",
            updatedByDeviceID: "device-7",
            resolvedConflictRevisionID: "rev-40",
            updatedAt: updatedAt
        )

        let encoded = SharedArtifactCloudCodec.encode(record, useServerTimestamp: false)
        let decoded = try SharedArtifactCloudCodec.decode(documentID: "remote-42", data: encoded)

        XCTAssertEqual(decoded.artifactID, record.artifactID)
        XCTAssertEqual(decoded.workspaceID, record.workspaceID)
        XCTAssertEqual(decoded.teamID, record.teamID)
        XCTAssertEqual(decoded.ownerUserID, record.ownerUserID)
        XCTAssertEqual(decoded.visibility, record.visibility)
        XCTAssertEqual(decoded.revisionID, record.revisionID)
        XCTAssertEqual(decoded.baseRevisionID, record.baseRevisionID)
        XCTAssertEqual(decoded.title, record.title)
        XCTAssertEqual(decoded.body, record.body)
        XCTAssertEqual(decoded.contentHash, record.contentHash)
        XCTAssertEqual(decoded.relativePath, record.relativePath)
        XCTAssertEqual(decoded.isDeleted, record.isDeleted)
        XCTAssertEqual(decoded.updatedByUserID, record.updatedByUserID)
        XCTAssertEqual(decoded.updatedByDeviceID, record.updatedByDeviceID)
        XCTAssertEqual(decoded.resolvedConflictRevisionID, record.resolvedConflictRevisionID)
        guard let decodedUpdatedAt = decoded.updatedAt else {
            XCTFail("Expected decoded updatedAt timestamp.")
            return
        }
        XCTAssertEqual(decodedUpdatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func test_sharedArtifactOptimisticWriteGate_detectsStaleWriteRace() {
        XCTAssertThrowsError(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-remote"
            )
        ) { error in
            let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
            XCTAssertEqual(conflict?.expectedRevisionID, "rev-base")
            XCTAssertEqual(conflict?.observedRevisionID, "rev-remote")
        }
    }

    func test_sharedArtifactOptimisticWriteGate_allowsCreateAndMatchingHead() throws {
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: nil,
                observedRevisionID: nil
            )
        )
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-9",
                observedRevisionID: "rev-9"
            )
        )
    }

    func test_sharedArtifactConcurrentEdits_detectRaceAndAvoidSilentOverwrite() {
        XCTAssertNoThrow(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-base"
            )
        )

        XCTAssertThrowsError(
            try SharedArtifactOptimisticWriteGate.validate(
                expectedRevisionID: "rev-base",
                observedRevisionID: "rev-peer"
            )
        ) { error in
            let conflict = SharedArtifactOptimisticWriteGate.conflict(from: error)
            XCTAssertEqual(conflict?.expectedRevisionID, "rev-base")
            XCTAssertEqual(conflict?.observedRevisionID, "rev-peer")
        }

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local-writer-b",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-local-writer-a"
            ),
            .conflict
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-merged",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-merged"
            ),
            .noChange
        )
    }

    func test_sharedArtifactAuditEvents_captureConflictAndRecoveryOutcomes() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_140_000)

        let artifact = SourceArtifactRecord(
            id: "shared-audit-artifact-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-a/team-a/incident-runbook.md",
            rootPath: "shared://workspace-a/team-a",
            relativePath: "incident-runbook.md",
            provenance: "shared-sync:workspace-a|team-a|remote-audit-1|user-1",
            title: "Incident Runbook",
            body: "v1",
            contentHash: "hash-a",
            fileSizeBytes: 2,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try store.upsertSourceArtifact(artifact)
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-1",
                revisionID: "rev-base",
                remoteContentHash: "hash-a",
                localContentHashAtSync: "hash-a",
                remoteUpdatedAt: base,
                lastPulledAt: base,
                lastSyncedAt: base,
                syncStatus: .conflicted,
                lastErrorCode: "SHARED_ARTIFACT_STALE_WRITE",
                lastErrorMessage: "Stale write detected.",
                createdAt: base,
                updatedAt: base
            )
        )

        try store.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                actorUserID: "user-1",
                actorRole: .editor,
                action: .conflictDetected,
                detailsJSON: #"{"message":"conflict","revisionID":"rev-peer","baseRevisionID":"rev-base","conflictRevisionID":"rev-peer"}"#,
                occurredAt: base.addingTimeInterval(5),
                createdAt: base.addingTimeInterval(5)
            )
        )
        try store.upsertSharedArtifactSyncState(
            SharedArtifactSyncStateRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                ownerUserID: "user-1",
                revisionID: "rev-peer",
                remoteContentHash: "hash-peer",
                localContentHashAtSync: "hash-peer",
                remoteUpdatedAt: base.addingTimeInterval(10),
                lastPulledAt: base.addingTimeInterval(10),
                lastSyncedAt: base.addingTimeInterval(10),
                syncStatus: .synced,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: base,
                updatedAt: base.addingTimeInterval(10)
            )
        )
        try store.appendSharedArtifactAuditEvent(
            SharedArtifactAuditEventRecord(
                sourceArtifactID: artifact.id,
                remoteArtifactID: "remote-audit-1",
                workspaceID: "workspace-a",
                teamID: "team-a",
                actorUserID: "user-1",
                actorRole: .editor,
                action: .conflictResolved,
                detailsJSON: #"{"message":"resolved","resolution":"remote_pull","revisionID":"rev-peer","baseRevisionID":"rev-base","conflictRevisionID":"rev-peer"}"#,
                occurredAt: base.addingTimeInterval(10),
                createdAt: base.addingTimeInterval(10)
            )
        )

        let syncState = try store.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(syncState?.syncStatus, .synced)
        XCTAssertEqual(syncState?.remoteArtifactID, "remote-audit-1")
        XCTAssertEqual(syncState?.revisionID, "rev-peer")

        let events = try store.fetchSharedArtifactAuditEvents(
            sourceArtifactID: artifact.id,
            workspaceID: "workspace-a",
            teamID: "team-a",
            actions: [.conflictDetected, .conflictResolved],
            limit: 10
        )
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.action), [.conflictResolved, .conflictDetected])
        XCTAssertTrue(events.allSatisfy { $0.sourceArtifactID == artifact.id })
        XCTAssertTrue(events.allSatisfy { $0.remoteArtifactID == "remote-audit-1" })

        var detailsByAction: [SharedArtifactAuditAction: [String: String]] = [:]
        for event in events {
            detailsByAction[event.action] = try decodeAuditDetails(event.detailsJSON)
        }
        XCTAssertEqual(detailsByAction[.conflictDetected]?["baseRevisionID"], "rev-base")
        XCTAssertEqual(detailsByAction[.conflictResolved]?["resolution"], "remote_pull")
    }

    private func decodeAuditDetails(_ raw: String?) throws -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func test_sharedArtifactSyncResolver_handlesDivergenceCases() {
        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-base"
            ),
            .pushLocal
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-base",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-remote"
            ),
            .pullRemote
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-local",
                syncedContentHash: "hash-base",
                remoteContentHash: "hash-remote"
            ),
            .conflict
        )

        XCTAssertEqual(
            SharedArtifactSyncResolver.mergeDecision(
                localContentHash: "hash-a",
                syncedContentHash: nil,
                remoteContentHash: "hash-b"
            ),
            .conflict
        )
    }
}
