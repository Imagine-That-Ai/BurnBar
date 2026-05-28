import XCTest
import GRDB
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Hermetic CloudSync integration tests using `CloudSyncFirestoreFakeGateway`
/// instead of a live Firestore emulator.
@MainActor
final class CloudSyncEmulatorIntegrationTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var collaborationSync: CollaborationSyncService!
    private var coordinator: CloudSyncCoordinator!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settingsManager.conversationCloudBackupEnabled = true
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
        collaborationSync = CollaborationSyncService(context: context)
        coordinator = CloudSyncCoordinator(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            sessionLogEncryptedCloudClient: FakeSessionLogEncryptedCloudClient()
        )
    }

    // MARK: - Collaboration push

    func test_collaborationPush_writesSharedArtifactHeadToFakeFirestore() async throws {
        let base = Date(timeIntervalSince1970: 1_742_150_000)
        let artifact = SourceArtifactRecord(
            id: "shared-push-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-test-uid-1/team-default/runbook.md",
            rootPath: "shared://workspace-test-uid-1/team-default",
            relativePath: "runbook.md",
            provenance: "",
            title: "Runbook",
            body: "# Runbook v1",
            contentHash: "hash-runbook-v1",
            fileSizeBytes: 14,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try dataStore.upsertSourceArtifact(artifact)

        await collaborationSync.sync()

        let collectionPrefix = "workspaces/workspace-test-uid-1/teams/team-default/artifacts"
        let docs = fakeGateway.documents(under: collectionPrefix)
        XCTAssertEqual(docs.count, 1)

        let headPath = docs.keys.sorted().first!
        let head = try XCTUnwrap(fakeGateway.documentData(at: headPath))
        XCTAssertEqual(head["title"] as? String, "Runbook")
        XCTAssertEqual(head["contentHash"] as? String, "hash-runbook-v1")
        XCTAssertEqual(head["body"] as? String, "# Runbook v1")

        let syncState = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(syncState?.syncStatus, .synced)
        XCTAssertNil(syncState?.lastErrorCode)
    }

    // MARK: - Collaboration pull

    func test_collaborationPull_materializesRemoteArtifactLocally() async throws {
        let scope = SharedArtifactScope.defaultScope(for: "test-uid-1")
        let remoteArtifactID = "remote-shared-99"
        let headPath = "workspaces/\(scope.workspaceID)/teams/\(scope.teamID)/artifacts/\(remoteArtifactID)"
        let updatedAt = Date(timeIntervalSince1970: 1_742_160_000)

        fakeGateway.setDocumentData([
            "artifactID": remoteArtifactID,
            "workspaceID": scope.workspaceID,
            "teamID": scope.teamID,
            "ownerUserID": scope.ownerUserID as Any,
            "visibility": SharedArtifactVisibility.team.rawValue,
            "revisionID": "rev-remote-1",
            "title": "Remote Spec",
            "body": "# Remote body",
            "contentHash": "hash-remote-body",
            "relativePath": "remote-spec.md",
            "isDeleted": false,
            "updatedAt": Timestamp(date: updatedAt)
        ], at: headPath)

        await collaborationSync.sync()

        let localArtifacts = try dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.sharedArtifact]
        )
        XCTAssertEqual(localArtifacts.count, 1)
        XCTAssertEqual(localArtifacts.first?.title, "Remote Spec")
        XCTAssertEqual(localArtifacts.first?.body, "# Remote body")

        let syncState = try dataStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
        XCTAssertEqual(syncState?.syncStatus, .synced)
        XCTAssertEqual(syncState?.remoteContentHash, "hash-remote-body")
    }

    // MARK: - Coordinator routing

    func test_coordinatorRoutesCollaborationSyncWithoutLegacyCloudSyncService() async throws {
        let base = Date(timeIntervalSince1970: 1_742_170_000)
        let artifact = SourceArtifactRecord(
            id: "shared-coordinator-1",
            sourceKind: .sharedArtifact,
            canonicalPath: "shared://workspace-test-uid-1/team-default/coordinator.md",
            rootPath: "shared://workspace-test-uid-1/team-default",
            relativePath: "coordinator.md",
            provenance: "",
            title: "Coordinator Path",
            body: "via coordinator",
            contentHash: "hash-coordinator",
            fileSizeBytes: 15,
            fileModifiedAt: base,
            status: .active,
            discoveredAt: base,
            deletedAt: nil,
            createdAt: base,
            updatedAt: base
        )
        _ = try dataStore.upsertSourceArtifact(artifact)

        await coordinator.syncCollaborationArtifacts()

        XCTAssertNotNil(coordinator.lastSyncDate)
        XCTAssertNil(coordinator.lastSyncError)

        let collectionPrefix = "workspaces/workspace-test-uid-1/teams/team-default/artifacts"
        XCTAssertFalse(fakeGateway.documents(under: collectionPrefix).isEmpty)
    }

    // MARK: - Degraded paths

    func test_collaborationSync_degradedWhenCloudSyncDisabled() async {
        accountManager.isCloudSyncEnabled = false
        await collaborationSync.sync()
        XCTAssertNotNil(collaborationSync.lastSyncError)
        XCTAssertTrue(collaborationSync.lastSyncError?.contains("Cloud sync is disabled") == true)
    }

    // MARK: - Sync state revival (from quarantine)

    func test_syncStateStore_recordsConflictedState() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let artifactID = "artifact-conflict-1"
        _ = try dataStore.upsertSourceArtifact(
            SourceArtifactRecord(
                id: artifactID,
                sourceKind: .sharedArtifact,
                canonicalPath: "shared://workspace-1/team-1/conflict.md",
                rootPath: "shared://workspace-1/team-1",
                relativePath: "conflict.md",
                provenance: "",
                title: "Conflict",
                body: "local",
                contentHash: "local-hash",
                fileSizeBytes: 5,
                fileModifiedAt: base,
                status: .active,
                discoveredAt: base,
                deletedAt: nil,
                createdAt: base,
                updatedAt: base
            )
        )
        let state = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifactID,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "remote-hash",
            localContentHashAtSync: "local-hash",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPulledAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncStatus: .conflicted,
            lastErrorCode: "SHARED_ARTIFACT_STALE_WRITE",
            lastErrorMessage: "Concurrent edit race detected",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try dataStore.upsertSharedArtifactSyncState(state)

        let fetched = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifactID)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.syncStatus, .conflicted)
        XCTAssertEqual(fetched?.lastErrorCode, "SHARED_ARTIFACT_STALE_WRITE")
        XCTAssertEqual(fetched?.lastErrorMessage, "Concurrent edit race detected")
    }

    func test_syncStateStore_conflictToResolved() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let artifactID = "artifact-resolve-1"
        _ = try dataStore.upsertSourceArtifact(
            SourceArtifactRecord(
                id: artifactID,
                sourceKind: .sharedArtifact,
                canonicalPath: "shared://workspace-1/team-1/resolve.md",
                rootPath: "shared://workspace-1/team-1",
                relativePath: "resolve.md",
                provenance: "",
                title: "Resolve",
                body: "local",
                contentHash: "local-hash",
                fileSizeBytes: 5,
                fileModifiedAt: base,
                status: .active,
                discoveredAt: base,
                deletedAt: nil,
                createdAt: base,
                updatedAt: base
            )
        )
        let conflictedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifactID,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "remote-hash",
            localContentHashAtSync: "local-hash",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPulledAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncStatus: .conflicted,
            lastErrorCode: "SHARED_ARTIFACT_STALE_WRITE",
            lastErrorMessage: "Concurrent edit race detected",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSharedArtifactSyncState(conflictedState)

        let resolvedState = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifactID,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-2",
            remoteContentHash: "merged-hash",
            localContentHashAtSync: "merged-hash",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastPulledAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_100),
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.upsertSharedArtifactSyncState(resolvedState)

        let fetched = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifactID)
        XCTAssertEqual(fetched?.syncStatus, .synced)
        XCTAssertNil(fetched?.lastErrorCode)
        XCTAssertEqual(fetched?.revisionID, "rev-2")
    }
}
