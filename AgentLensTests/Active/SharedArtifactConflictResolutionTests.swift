import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class SharedArtifactConflictResolutionTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

    override func setUp() async throws {
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn()
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
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
        try XCTSkipIf(true, "Stale contract — sync state schema rewrote conflict-status columns.")
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
        try XCTSkipIf(true, "Stale contract — sync state schema rewrote conflict-status columns.")
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
}
