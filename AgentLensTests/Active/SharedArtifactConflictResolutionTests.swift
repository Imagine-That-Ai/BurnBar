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

}
