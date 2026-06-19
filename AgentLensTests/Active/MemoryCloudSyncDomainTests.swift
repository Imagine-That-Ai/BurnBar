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

    private func makeSettings(optIn: Bool, fleetEnabled: Bool) -> SettingsManager {
        let settings = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        settings.memoryApprovedCloudBackupOptIn = optIn
        settings.memoryExtractionRemoteConfigEnabled = fleetEnabled
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
        // The wrapped service seals the body; the plaintext must never appear.
        let outer = String(describing: docs)
        XCTAssertFalse(outer.contains("Approved memory body"))
        XCTAssertNotNil(domain.lastSyncDate)
        XCTAssertNil(domain.lastSyncError)
    }
}
