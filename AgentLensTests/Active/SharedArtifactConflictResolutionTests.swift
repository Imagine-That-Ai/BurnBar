import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SharedArtifactConflictResolutionTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: FakeSettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = FakeSettingsManager()
        fakeGateway = CloudSyncFirestoreFakeGateway()
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
    }

    // MARK: - Merge Decision Matrix

    func test_mergeDecision_bothUnchanged_returnsNoChange() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "abc123",
            syncedContentHash: "abc123",
            remoteContentHash: "abc123"
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_onlyLocalChanged_returnsPushLocal() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "local456",
            syncedContentHash: "abc123",
            remoteContentHash: "abc123"
        )
        XCTAssertEqual(decision, .pushLocal)
    }

    func test_mergeDecision_onlyRemoteChanged_returnsPullRemote() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "abc123",
            syncedContentHash: "abc123",
            remoteContentHash: "remote789"
        )
        XCTAssertEqual(decision, .pullRemote)
    }

    func test_mergeDecision_bothChanged_returnsConflict() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "local456",
            syncedContentHash: "abc123",
            remoteContentHash: "remote789"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func test_mergeDecision_noBaseline_returnsConflict() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "local456",
            syncedContentHash: nil,
            remoteContentHash: "remote789"
        )
        XCTAssertEqual(decision, .conflict)
    }

    func test_mergeDecision_nilLocal_nilRemote_returnsNoChange() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: nil,
            syncedContentHash: nil,
            remoteContentHash: nil
        )
        XCTAssertEqual(decision, .noChange)
    }

    func test_mergeDecision_localOnly_nonEmpty_returnsPushLocal() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: "local456",
            syncedContentHash: nil,
            remoteContentHash: nil
        )
        XCTAssertEqual(decision, .pushLocal)
    }

    func test_mergeDecision_remoteOnly_nonEmpty_returnsPullRemote() {
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: nil,
            syncedContentHash: nil,
            remoteContentHash: "remote789"
        )
        XCTAssertEqual(decision, .pullRemote)
    }

    // MARK: - Sync State Store Conflict Recording

    func test_syncStateStore_recordsConflictedState() async throws {
        let artifactID = "artifact-1"
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
        let artifactID = "artifact-1"
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

        // Resolve conflict
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
        XCTAssertEqual(fetched?.remoteContentHash, "merged-hash")
    }

    func test_syncStateStore_conflictWithAuditEvent() async throws {
        let artifactID = "artifact-1"
        let now = Date()

        let event = SharedArtifactAuditEventRecord(
            id: UUID().uuidString,
            sourceArtifactID: artifactID,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            action: .conflictDetected,
            actorUserID: "actor-1",
            message: "Concurrent edit race detected; stale write was rejected.",
            metadata: ["errorCode": "SHARED_ARTIFACT_STALE_WRITE"],
            occurredAt: now,
            syncedAt: nil,
            syncStatus: .pending
        )
        try dataStore.insertSharedArtifactAuditEvent(event)

        let events = try dataStore.fetchSharedArtifactAuditEvents(sourceArtifactID: artifactID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, .conflictDetected)
        XCTAssertEqual(events.first?.syncStatus, .pending)
    }

    // MARK: - Source Artifact + Sync State Integration

    func test_sourceArtifact_withSyncStateConflicted() async throws {
        let artifact = SourceArtifact(
            id: "artifact-1",
            title: "Test Artifact",
            body: "Test body content",
            relativePath: "test.md",
            sourceKind: .sharedArtifact,
            contentHash: "local-hash-456",
            projectName: "TestProject",
            projectIcon: "folder",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSourceArtifact(artifact)

        let state = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "remote-hash-789",
            localContentHashAtSync: "synced-hash-123",
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

        let fetchedState = try dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertNotNil(fetchedState)
        XCTAssertEqual(fetchedState?.syncStatus, .conflicted)

        // Verify the merge decision from stored state
        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: artifact.contentHash,
            syncedContentHash: fetchedState?.localContentHashAtSync,
            remoteContentHash: fetchedState?.remoteContentHash
        )
        XCTAssertEqual(decision, .conflict)
    }

    func test_sourceArtifact_pushLocal_afterEdit() async throws {
        let artifact = SourceArtifact(
            id: "artifact-1",
            title: "Test Artifact",
            body: "Edited body content",
            relativePath: "test.md",
            sourceKind: .sharedArtifact,
            contentHash: "edited-hash-789",
            projectName: "TestProject",
            projectIcon: "folder",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.upsertSourceArtifact(artifact)

        let state = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "synced-hash-123",
            localContentHashAtSync: "synced-hash-123",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPulledAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSharedArtifactSyncState(state)

        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: artifact.contentHash,
            syncedContentHash: state.localContentHashAtSync,
            remoteContentHash: state.remoteContentHash
        )
        XCTAssertEqual(decision, .pushLocal)
    }

    func test_sourceArtifact_pullRemote_afterRemoteEdit() async throws {
        let artifact = SourceArtifact(
            id: "artifact-1",
            title: "Test Artifact",
            body: "Original body",
            relativePath: "test.md",
            sourceKind: .sharedArtifact,
            contentHash: "synced-hash-123",
            projectName: "TestProject",
            projectIcon: "folder",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSourceArtifact(artifact)

        let state = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "remote-edited-456",
            localContentHashAtSync: "synced-hash-123",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            lastPulledAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try dataStore.upsertSharedArtifactSyncState(state)

        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: artifact.contentHash,
            syncedContentHash: state.localContentHashAtSync,
            remoteContentHash: state.remoteContentHash
        )
        XCTAssertEqual(decision, .pullRemote)
    }

    func test_sourceArtifact_noChange_whenHashesMatch() async throws {
        let artifact = SourceArtifact(
            id: "artifact-1",
            title: "Test Artifact",
            body: "Body content",
            relativePath: "test.md",
            sourceKind: .sharedArtifact,
            contentHash: "same-hash",
            projectName: "TestProject",
            projectIcon: "folder",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSourceArtifact(artifact)

        let state = SharedArtifactSyncStateRecord(
            sourceArtifactID: artifact.id,
            remoteArtifactID: "remote-1",
            workspaceID: "workspace-1",
            teamID: "team-1",
            ownerUserID: "owner-1",
            revisionID: "rev-1",
            remoteContentHash: "same-hash",
            localContentHashAtSync: "same-hash",
            remoteUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastPulledAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncStatus: .synced,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try dataStore.upsertSharedArtifactSyncState(state)

        let decision = SharedArtifactSyncResolver.mergeDecision(
            localContentHash: artifact.contentHash,
            syncedContentHash: state.localContentHashAtSync,
            remoteContentHash: state.remoteContentHash
        )
        XCTAssertEqual(decision, .noChange)
    }
}
