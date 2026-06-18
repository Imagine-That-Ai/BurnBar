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
    private var vaultKeyProvider: TestConversationVaultKeyProvider!
    private var collaborationSync: CollaborationSyncService!
    private var coordinator: CloudSyncCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
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
        vaultKeyProvider = TestConversationVaultKeyProvider()
        collaborationSync = CollaborationSyncService(
            context: context,
            sharedArtifactVaultKeyProvider: vaultKeyProvider
        )
        coordinator = CloudSyncCoordinator(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway,
            conversationVaultKeyProvider: vaultKeyProvider,
            sessionLogEncryptedCloudClient: FakeSessionLogEncryptedCloudClient(),
            sessionLogVaultKeyStore: StaticSessionLogVaultKeyStore(),
            sessionLogVaultKeyPublisher: NoopSessionLogVaultKeyPublisher()
        )
    }

    override func tearDownWithError() throws {
        coordinator = nil
        collaborationSync = nil
        context = nil
        fakeGateway = nil
        settingsManager = nil
        accountManager = nil
        dataStore = nil
        vaultKeyProvider = nil

        try super.tearDownWithError()
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
        _ = try await dataStore.upsertSourceArtifact(artifact)

        await collaborationSync.sync()

        let collectionPrefix = "workspaces/workspace-test-uid-1/teams/team-default/artifacts"
        let docs = fakeGateway.documents(under: collectionPrefix)
        XCTAssertEqual(docs.count, 1)

        let headPath = docs.keys.min()!
        let head = try XCTUnwrap(fakeGateway.documentData(at: headPath))
        XCTAssertNil(head["title"], "Shared artifact head must not store plaintext title")
        XCTAssertNil(head["contentHash"], "Shared artifact head must not store plaintext content hash")
        XCTAssertNil(head["body"], "Shared artifact head must not store plaintext body")
        XCTAssertNil(head["relativePath"], "Shared artifact head must not store plaintext relative path")
        XCTAssertEqual(head["contentSealed"] as? Bool, true)
        XCTAssertEqual(head["vaultKeyID"] as? String, try vaultKeyProvider.resolvedKey().vaultKeyID)

        let headEnvelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: head["sealedPayload"]))
        let headAAD = try CloudVaultAADContext(
            uid: "test-uid-1",
            collection: SharedArtifactCloudCodec.artifactAADCollection,
            docID: artifact.id,
            field: SharedArtifactCloudCodec.sealedPayloadField
        )
        let headPlaintext = try CloudVaultCrypto.openPayload(
            headEnvelope,
            keyData: vaultKeyProvider.keyData,
            aadContext: headAAD
        )
        let headPrivatePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: headPlaintext) as? [String: Any]
        )
        XCTAssertEqual(headPrivatePayload["title"] as? String, "Runbook")
        XCTAssertEqual(headPrivatePayload["contentHash"] as? String, "hash-runbook-v1")
        XCTAssertEqual(headPrivatePayload["body"] as? String, "# Runbook v1")

        let revisionID = try XCTUnwrap(head["revisionID"] as? String)
        let versionPath = "\(headPath)/versions/\(revisionID)"
        let version = try XCTUnwrap(fakeGateway.documentData(at: versionPath))
        XCTAssertNil(version["title"], "Shared artifact versions must not store plaintext title")
        let versionEnvelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: version["sealedPayload"]))
        let versionAAD = try CloudVaultAADContext(
            uid: "test-uid-1",
            collection: SharedArtifactCloudCodec.artifactVersionAADCollection,
            docID: revisionID,
            field: SharedArtifactCloudCodec.sealedPayloadField
        )
        XCTAssertNoThrow(
            try CloudVaultCrypto.openPayload(
                versionEnvelope,
                keyData: vaultKeyProvider.keyData,
                aadContext: versionAAD
            )
        )

        let syncState = try await dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifact.id)
        XCTAssertEqual(syncState?.syncStatus, .synced)
        XCTAssertNil(syncState?.lastErrorCode)
    }

    func test_collaborationPush_withNoLocalArtifactsDoesNotCreateVaultKey() async throws {
        let countingProvider = CountingConversationVaultKeyProvider()
        let sync = CollaborationSyncService(
            context: context,
            sharedArtifactVaultKeyProvider: countingProvider
        )
        var report = SharedArtifactSyncReport(scope: .defaultScope(for: "test-uid-1"))

        try await sync.pushLocalSharedArtifacts(
            scope: .defaultScope(for: "test-uid-1"),
            deviceId: "test-device-1",
            report: &report
        )

        XCTAssertEqual(report.localArtifactsEvaluated, 0)
        XCTAssertEqual(countingProvider.keyForWritingCallCount, 0)
        XCTAssertEqual(countingProvider.keyForReadingCallCount, 0)
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

        let localArtifacts = try await dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.sharedArtifact]
        )
        XCTAssertEqual(localArtifacts.count, 1)
        XCTAssertEqual(localArtifacts.first?.title, "Remote Spec")
        XCTAssertEqual(localArtifacts.first?.body, "# Remote body")

        let syncState = try await dataStore.fetchSharedArtifactSyncState(remoteArtifactID: remoteArtifactID)
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
        _ = try await dataStore.upsertSourceArtifact(artifact)

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
        XCTAssertEqual(collaborationSync.lastSyncError?.contains("Cloud sync is disabled"), true)
    }

    // MARK: - Sync state revival (from quarantine)

    func test_syncStateStore_recordsConflictedState() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let artifactID = "artifact-conflict-1"
        _ = try await dataStore.upsertSourceArtifact(
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

        try await dataStore.upsertSharedArtifactSyncState(state)

        let fetched = try await dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifactID)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.syncStatus, .conflicted)
        XCTAssertEqual(fetched?.lastErrorCode, "SHARED_ARTIFACT_STALE_WRITE")
        XCTAssertEqual(fetched?.lastErrorMessage, "Concurrent edit race detected")
    }

    func test_syncStateStore_conflictToResolved() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let artifactID = "artifact-resolve-1"
        _ = try await dataStore.upsertSourceArtifact(
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
        try await dataStore.upsertSharedArtifactSyncState(conflictedState)

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
        try await dataStore.upsertSharedArtifactSyncState(resolvedState)

        let fetched = try await dataStore.fetchSharedArtifactSyncState(sourceArtifactID: artifactID)
        XCTAssertEqual(fetched?.syncStatus, .synced)
        XCTAssertNil(fetched?.lastErrorCode)
        XCTAssertEqual(fetched?.revisionID, "rev-2")
    }

    func test_collaborationPull_healsLegacyPlaintextArtifact() async throws {
        let scope = SharedArtifactScope.defaultScope(for: "test-uid-1")
        let artifactID = "legacy-art-1"
        let revisionID = "legacy-rev-1"
        let plaintextPath = "workspaces/workspace-test-uid-1/teams/team-default/artifacts/\(artifactID)"
        let plaintextDoc: [String: Any] = [
            "artifactID": artifactID,
            "workspaceID": "workspace-test-uid-1",
            "teamID": "team-default",
            "ownerUserID": "test-uid-1",
            "visibility": "team",
            "revisionID": revisionID,
            "isDeleted": false,
            "title": "Legacy Plaintext Title",
            "body": "Legacy plaintext body that must be sealed",
            "contentHash": "legacy-hash-123"
        ]
        fakeGateway.setDocumentData(plaintextDoc, at: plaintextPath)

        let preData = try XCTUnwrap(fakeGateway.documentData(at: plaintextPath))
        XCTAssertTrue(SharedArtifactCloudCodec.isLegacyPlaintext(data: preData))

        var report = SharedArtifactSyncReport(scope: scope)
        try await collaborationSync.pullRemoteSharedArtifacts(
            scope: scope,
            deviceId: "test-device-1",
            maxRemoteArtifacts: 10,
            report: &report
        )

        let healedData = try XCTUnwrap(fakeGateway.documentData(at: plaintextPath))
        XCTAssertNil(healedData["title"], "Legacy title must be deleted after heal")
        XCTAssertNil(healedData["body"], "Legacy body must be deleted after heal")
        XCTAssertNil(healedData["contentHash"], "Legacy contentHash must be deleted after heal")
        XCTAssertEqual(healedData["contentSealed"] as? Bool, true)
        XCTAssertNotNil(healedData[SharedArtifactCloudCodec.sealedPayloadField])
        XCTAssertFalse(SharedArtifactCloudCodec.isLegacyPlaintext(data: healedData))

        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: healedData[SharedArtifactCloudCodec.sealedPayloadField]))
        let aad = try CloudVaultAADContext(
            uid: "test-uid-1",
            collection: SharedArtifactCloudCodec.artifactAADCollection,
            docID: artifactID,
            field: SharedArtifactCloudCodec.sealedPayloadField
        )
        let plaintext = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKeyProvider.keyData, aadContext: aad)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(decoded["title"] as? String, "Legacy Plaintext Title")
        XCTAssertEqual(decoded["body"] as? String, "Legacy plaintext body that must be sealed")
        XCTAssertEqual(decoded["contentHash"] as? String, "legacy-hash-123")

        let versionPath = "\(plaintextPath)/versions/\(revisionID)"
        let versionData = try XCTUnwrap(fakeGateway.documentData(at: versionPath))
        XCTAssertNil(versionData["title"], "Legacy version title must be deleted in the same heal")
        XCTAssertNil(versionData["body"], "Legacy version body must be deleted in the same heal")
        XCTAssertNil(versionData["contentHash"], "Legacy version contentHash must be deleted in the same heal")
        XCTAssertEqual(versionData["contentSealed"] as? Bool, true)
        XCTAssertNotNil(versionData[SharedArtifactCloudCodec.sealedPayloadField])
    }

    func test_collaborationPull_healsMixedSealedPlaintextArtifact() async throws {
        let scope = SharedArtifactScope.defaultScope(for: "test-uid-1")
        let artifactID = "mixed-art-1"
        let revisionID = "mixed-rev-1"
        let artifactPath = "workspaces/workspace-test-uid-1/teams/team-default/artifacts/\(artifactID)"
        let record = SharedArtifactCloudRecord(
            artifactID: artifactID,
            workspaceID: scope.workspaceID,
            teamID: scope.teamID,
            ownerUserID: scope.ownerUserID,
            revisionID: revisionID,
            title: "Encrypted Source Title",
            body: "Encrypted source body",
            contentHash: "encrypted-hash",
            relativePath: "mixed.md",
            isDeleted: false,
            updatedAt: Date(timeIntervalSince1970: 1_742_180_000)
        )
        let sealed = try SharedArtifactCloudCodec.encodeSealed(
            record,
            useServerTimestamp: false,
            vaultKey: vaultKeyProvider.resolvedKey(),
            ownerUserID: "test-uid-1",
            aadCollection: SharedArtifactCloudCodec.artifactAADCollection,
            aadDocumentID: artifactID
        )
        var mixed = sealed.filter { key, _ in
            !["title", "body", "contentHash", "relativePath"].contains(key)
        }
        mixed["title"] = "Leaked old title"
        mixed["body"] = "Leaked old body"
        mixed["contentHash"] = "leaked-old-hash"
        fakeGateway.setDocumentData(mixed, at: artifactPath)

        XCTAssertTrue(SharedArtifactCloudCodec.isLegacyPlaintext(data: try XCTUnwrap(fakeGateway.documentData(at: artifactPath))))

        var report = SharedArtifactSyncReport(scope: scope)
        try await collaborationSync.pullRemoteSharedArtifacts(
            scope: scope,
            deviceId: "test-device-1",
            maxRemoteArtifacts: 10,
            report: &report
        )

        let healedData = try XCTUnwrap(fakeGateway.documentData(at: artifactPath))
        XCTAssertNil(healedData["title"])
        XCTAssertNil(healedData["body"])
        XCTAssertNil(healedData["contentHash"])
        XCTAssertFalse(SharedArtifactCloudCodec.isLegacyPlaintext(data: healedData))

        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: healedData[SharedArtifactCloudCodec.sealedPayloadField]))
        let aad = try CloudVaultAADContext(
            uid: "test-uid-1",
            collection: SharedArtifactCloudCodec.artifactAADCollection,
            docID: artifactID,
            field: SharedArtifactCloudCodec.sealedPayloadField
        )
        let plaintext = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKeyProvider.keyData, aadContext: aad)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: plaintext) as? [String: Any])
        XCTAssertEqual(decoded["title"] as? String, "Encrypted Source Title")
        XCTAssertEqual(decoded["body"] as? String, "Encrypted source body")
        XCTAssertEqual(decoded["contentHash"] as? String, "encrypted-hash")
    }

    func test_collaborationPull_skipsLegacyHealWhenRemoteRevisionChanged() async throws {
        let scope = SharedArtifactScope.defaultScope(for: "test-uid-1")
        let artifactID = "legacy-race-art-1"
        let artifactPath = "workspaces/workspace-test-uid-1/teams/team-default/artifacts/\(artifactID)"
        fakeGateway.setDocumentData([
            "artifactID": artifactID,
            "workspaceID": scope.workspaceID,
            "teamID": scope.teamID,
            "ownerUserID": "test-uid-1",
            "visibility": "team",
            "revisionID": "rev-old",
            "isDeleted": false,
            "title": "Old title",
            "body": "Old body",
            "contentHash": "old-hash"
        ], at: artifactPath)
        fakeGateway.beforeNextTransaction = { [fakeGateway] in
            fakeGateway?.setDocumentData([
                "artifactID": artifactID,
                "workspaceID": "workspace-test-uid-1",
                "teamID": "team-default",
                "ownerUserID": "test-uid-1",
                "visibility": "team",
                "revisionID": "rev-newer",
                "isDeleted": false,
                "title": "Newer title",
                "body": "Newer body",
                "contentHash": "newer-hash"
            ], at: artifactPath)
        }

        var report = SharedArtifactSyncReport(scope: scope)
        try await collaborationSync.pullRemoteSharedArtifacts(
            scope: scope,
            deviceId: "test-device-1",
            maxRemoteArtifacts: 10,
            report: &report
        )

        let remoteData = try XCTUnwrap(fakeGateway.documentData(at: artifactPath))
        XCTAssertEqual(remoteData["revisionID"] as? String, "rev-newer")
        XCTAssertEqual(remoteData["title"] as? String, "Newer title")
        XCTAssertEqual(remoteData["body"] as? String, "Newer body")
        XCTAssertEqual(remoteData["contentHash"] as? String, "newer-hash")
        XCTAssertNil(remoteData[SharedArtifactCloudCodec.sealedPayloadField])
    }
}

private final class CountingConversationVaultKeyProvider: ConversationCloudVaultKeyProviding, @unchecked Sendable {
    private let keyData: Data
    private let lock = NSLock()
    private var writeCalls = 0
    private var readCalls = 0

    init(keyData: Data = Data(repeating: 0x42, count: 32)) {
        self.keyData = keyData
    }

    var keyForWritingCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCalls
    }

    var keyForReadingCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCalls
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        lock.lock()
        writeCalls += 1
        lock.unlock()
        return try resolvedKey()
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        lock.lock()
        readCalls += 1
        lock.unlock()
        return try resolvedKey()
    }

    private func resolvedKey() throws -> CloudVaultResolvedKey {
        try CloudVaultResolvedKey(
            keyData: keyData,
            vaultKeyID: CloudVaultCrypto.vaultKeyID(for: keyData)
        )
    }
}
