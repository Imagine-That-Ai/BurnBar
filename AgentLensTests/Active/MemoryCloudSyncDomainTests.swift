import FirebaseFirestore
import Foundation
import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// PR-E2 — proves the cloud-sync scheduling lane ships DORMANT and only egresses
/// when BOTH the explicit user opt-in AND the Remote Config fleet ceiling allow.
///
/// `MemoryCloudSyncService.syncApprovedMemories` (the wrapped uploader) is covered
/// by `OpenBurnBarDatabaseMigrationTests`; this suite covers the *gate* the domain
/// wraps it in — the safety property that the activation must never regress.
@MainActor
final class MemoryCloudSyncDomainTests: XCTestCase {

    private func makeStoreWithApprovedMemory(uid: String) async throws -> (ControlPlaneStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue)
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        let scope = MemoryScope(userID: uid, appID: "cloud-app")
        _ = try await store.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "Approved memory body that must only leave the device when opted in.",
                kind: .preference,
                scope: scope,
                confidence: 0.9,
                citations: [
                    MemoryCitation(
                        id: "cite-e2",
                        threadLogicalID: "thread-e2",
                        messageID: "message-e2",
                        role: "user",
                        authoredAt: now,
                        contentHash: "content-e2",
                        crossDeviceHMAC: "hmac-e2"
                    )
                ],
                reviewStatus: .approved
            ),
            id: "mem-e2-approved",
            now: now,
            enabled: true
        )
        return (store, queue)
    }

    private func makeSettings(optIn: Bool, fleetEnabled: Bool, deviceSync: Bool = false) -> SettingsManager {
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.memoryApprovedCloudBackupOptIn = optIn
        settings.memoryExtractionRemoteConfigEnabled = fleetEnabled
        settings.memoryDeviceSyncOptIn = deviceSync
        return settings
    }

    private func makeDomain(
        store: ControlPlaneStore,
        accountManager: FakeAccountManager,
        settings: SettingsManager,
        gateway: CloudSyncFirestoreFakeGateway
    ) -> MemoryCloudSyncDomain {
        MemoryCloudSyncDomain(
            store: store,
            accountManager: accountManager,
            settingsManager: settings,
            firestoreGateway: gateway,
            vaultKeyProvider: TestConversationVaultKeyProvider()
        )
    }

    // MARK: - Dormant by default (the headline guarantee)

    func test_sync_isNoOp_whenCloudBackupOptInIsOff_evenWithApprovedMemory() async throws {
        let uid = "e2-user-default-off"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: false, fleetEnabled: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        // The opt-in defaults OFF: the domain must replicate NOTHING.
        XCTAssertFalse(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
        XCTAssertNil(domain.lastSyncDate)
        XCTAssertNil(domain.lastSyncError)
    }

    // MARK: - Fleet ceiling clamps even an opted-in user

    func test_sync_isNoOp_whenFleetCeilingIsOff_despiteOptIn() async throws {
        let uid = "e2-user-fleet-off"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        // Opt-in is ON, but the Remote Config fleet kill switch clamps egress shut.
        XCTAssertTrue(settings.memoryApprovedCloudBackupOptIn)
        XCTAssertFalse(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
    }

    // MARK: - Account gate

    func test_sync_isNoOp_whenNotSignedIn() async throws {
        let uid = "e2-user-signed-out"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true)
        let account = FakeAccountManager() // not signed in
        let domain = makeDomain(store: store, accountManager: account, settings: settings, gateway: gateway)

        await domain.sync()

        XCTAssertTrue(gateway.documents(under: "users/\(uid)/memory_facts").isEmpty)
    }

    // MARK: - Enabled path actually reaches the uploader

    func test_sync_replicatesApprovedMemory_whenBothLeversAllow() async throws {
        let uid = "e2-user-enabled"
        let (store, _) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        await domain.sync()

        let docs = gateway.documents(under: "users/\(uid)/memory_facts")
        XCTAssertEqual(docs.count, 1)
        // Structural seal invariant (m5): the uploaded document must carry the sealed
        // ciphertext envelope and NO cleartext body/text/vector field — asserting the seal
        // exists, not merely that one known plaintext substring is absent.
        let fields = try XCTUnwrap(docs.values.first)
        XCTAssertNotNil(fields["sealedMemory"], "Uploaded memory fact must carry a sealedMemory envelope.")
        XCTAssertNil(fields["text"], "Plaintext `text` must never be a cleartext Firestore field.")
        XCTAssertNil(fields["body"], "Plaintext `body` must never be a cleartext Firestore field.")
        XCTAssertNil(fields["vector"], "Raw embedding `vector` must never be a cleartext Firestore field.")
        XCTAssertEqual(fields["reviewStatus"] as? String, MemoryReviewStatus.approved.rawValue)
        // Belt-and-suspenders: the known plaintext body must not appear anywhere in the doc.
        XCTAssertFalse(String(describing: docs).contains("Approved memory body"))
        XCTAssertNotNil(domain.lastSyncDate)
        XCTAssertNil(domain.lastSyncError)
    }

    // MARK: - The PULL sub-toggle (Memory Blind Sync PR-2)

    /// Backing memory up is not the same consent as syncing it across devices. A
    /// member who opted into backup and nothing else must see the upload run and
    /// the download not happen — no `memory_facts` read, no inbox row.
    func test_sync_doesNotPull_whenTheDeviceSyncSubToggleIsOff() async throws {
        let uid = "e2-user-pull-off"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: false)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryApprovedCloudBackupEnabled)
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "the pull sub-toggle defaults OFF")
        await domain.sync()

        // The push still ran: the sub-toggle gates only the read-back.
        XCTAssertEqual(gateway.documents(under: "users/\(uid)/memory_facts").count, 1)
        let inboxRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox") ?? -1
        }
        XCTAssertEqual(inboxRows, 0, "no pull runs while the sub-toggle is off")
        XCTAssertNil(domain.lastSyncError)
    }

    /// Turning cloud backup off must stop the download too: a member who revokes
    /// memory egress does not keep an active memory sync channel open inbound.
    func test_theDeviceSyncGateIsClampedByTheCloudBackupGate() {
        let settings = makeSettings(optIn: false, fleetEnabled: true, deviceSync: true)
        XCTAssertTrue(settings.memoryDeviceSyncOptIn)
        XCTAssertFalse(settings.memoryDeviceSyncEnabled, "the sub-toggle alone can never start a download")

        settings.memoryApprovedCloudBackupOptIn = true
        XCTAssertTrue(settings.memoryDeviceSyncEnabled)

        // And the fleet ceiling clamps both halves with one flip.
        settings.memoryExtractionRemoteConfigEnabled = false
        XCTAssertFalse(settings.memoryDeviceSyncEnabled)
    }

    /// With both levers on, the same cycle uploads and then reads back. The order
    /// matters: the pull runs AFTER the push, so a device that just learned a fact
    /// publishes it before it looks for other devices' facts.
    func test_sync_pullsRemoteFacts_whenBothTheBackupGateAndTheSubToggleAllow() async throws {
        let uid = "e2-user-pull-on"
        let (store, queue) = try await makeStoreWithApprovedMemory(uid: uid)
        let gateway = CloudSyncFirestoreFakeGateway()
        let settings = makeSettings(optIn: true, fleetEnabled: true, deviceSync: true)
        let domain = makeDomain(
            store: store,
            accountManager: .makeSignedIn(uid: uid),
            settings: settings,
            gateway: gateway
        )

        XCTAssertTrue(settings.memoryDeviceSyncEnabled)
        await domain.sync()

        // This device's own upload is read straight back — the same-member,
        // same-vault-key round trip a second device would see.
        let inboxRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memory_inbox") ?? -1
        }
        XCTAssertEqual(inboxRows, 1)
        XCTAssertNil(domain.lastSyncError)
        XCTAssertNotNil(domain.lastSyncDate)
    }
}
