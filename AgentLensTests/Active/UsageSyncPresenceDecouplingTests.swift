import XCTest
import FirebaseFirestore
@testable import OpenBurnBarCore
@testable import OpenBurnBar

/// The "Mac last seen: never" regression class: the devices-registry presence
/// doc (the ONLY signal iOS renders as "Mac last seen") used to be written at
/// the very end of a fully-successful usage sync — behind the Cloud Vault key
/// resolve, the batch upload, and the heartbeat. Any failure in that chain
/// (most commonly `CloudVaultAccessError.vaultKeyUnavailable` on a device that
/// can't unwrap the vault) silently starved presence forever, so the phone
/// reported a Mac that was running all day as never having existed.
///
/// These tests pin the decoupling contract:
///   1. Presence publishes FIRST, before the vault key is even resolved.
///   2. A failed sync lands a bounded `lastErrorCode` in `sync_status` so the
///      phone can say WHY, without ever touching `lastSyncAt` (data freshness
///      stays honest).
///   3. A successful sync stamps `lastSyncAt` and explicitly clears the error.
@MainActor
final class UsageSyncPresenceDecouplingTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!

    private let devicesPath = "users/test-uid-1/devices/test-device-1"
    private let syncStatusPath = "users/test-uid-1/sync_status/test-device-1"

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

    private func insertOneUnsyncedUsage() async throws {
        let usage = TokenUsage(
            provider: .claudeCode,
            sessionId: "session-presence",
            projectName: "Presence Project",
            model: "claude-3-5-sonnet",
            inputTokens: 10,
            outputTokens: 5,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try await dataStore.insert(usage)
    }

    // MARK: - 1. Vault-key failure must not starve presence

    func test_vaultKeyFailure_stillPublishesDevicePresence_andRecordsBlockedCode() async throws {
        try await insertOneUnsyncedUsage()
        let service = UsageSyncService(
            context: context,
            vaultKeyProvider: ThrowingVaultKeyProvider(error: CloudVaultAccessError.vaultKeyUnavailable)
        )

        await service.sync()

        // Presence landed even though the sync pass failed at the key resolve.
        let device = try XCTUnwrap(fakeGateway.documentData(at: devicesPath))
        XCTAssertEqual(device["platform"] as? String, "macOS")
        XCTAssertEqual(device["deviceId"] as? String, "test-device-1")
        XCTAssertNotNil(device["lastSeenAt"], "presence heartbeat must carry lastSeenAt")

        // The failure reason landed where the phone reads it, in the bounded
        // vocabulary — and data freshness (lastSyncAt) was NOT forged.
        let status = try XCTUnwrap(fakeGateway.documentData(at: syncStatusPath))
        XCTAssertEqual(status["lastErrorCode"] as? String, "vault_key_unavailable")
        XCTAssertNotNil(status["lastAttemptAt"])
        XCTAssertNil(status["lastSyncAt"], "a blocked sync must never stamp lastSyncAt")

        XCTAssertNotNil(service.lastSyncError)
        // The usage row stays unsynced for retry.
        let unsynced = try await dataStore.fetchUnsynced()
        XCTAssertEqual(unsynced.count, 1)
    }

    // MARK: - 2. Success stamps freshness and clears the error

    func test_successfulSync_writesHeartbeat_andClearsErrorCode() async throws {
        try await insertOneUnsyncedUsage()
        let failing = UsageSyncService(
            context: context,
            vaultKeyProvider: ThrowingVaultKeyProvider(error: CloudVaultAccessError.vaultKeyUnavailable)
        )
        await failing.sync()
        XCTAssertEqual(
            fakeGateway.documentData(at: syncStatusPath)?["lastErrorCode"] as? String,
            "vault_key_unavailable"
        )

        let recovering = UsageSyncService(context: context, vaultKeyProvider: TestConversationVaultKeyProvider())
        await recovering.sync()

        let status = try XCTUnwrap(fakeGateway.documentData(at: syncStatusPath))
        XCTAssertNotNil(status["lastSyncAt"])
        XCTAssertEqual(status["collectionsInSync"] as? [String], ["usage"])
        XCTAssertTrue(
            status["lastErrorCode"] == nil || status["lastErrorCode"] is NSNull,
            "recovery must clear the blocked-reason so the phone stops showing it"
        )
        XCTAssertNil(recovering.lastSyncError)

        let device = try XCTUnwrap(fakeGateway.documentData(at: devicesPath))
        XCTAssertNotNil(device["lastSeenAt"])
    }

    // MARK: - 3. Bounded error vocabulary

    func test_syncBlockedCode_boundedVocabulary() {
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(for: CloudVaultAccessError.vaultKeyUnavailable),
            "vault_key_unavailable"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(for: CloudVaultAccessError.vaultKeyMismatch(expected: "a", actual: "b")),
            "vault_key_mismatch"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(for: CloudVaultAccessError.invalidWrappedKey),
            "vault_key_invalid"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(
                for: NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
            ),
            "permission_denied"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(
                for: NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unauthenticated.rawValue)
            ),
            "unauthenticated"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)),
            "network_unavailable"
        )
        XCTAssertEqual(
            UsageSyncService.syncBlockedCode(for: NSError(domain: "Whatever", code: 1)),
            "other"
        )
    }
}

/// Vault-key provider that always fails, standing in for a Mac that cannot
/// unwrap the account's cloud vault (bootstrapped by another device).
private struct ThrowingVaultKeyProvider: ConversationCloudVaultKeyProviding {
    let error: Error

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        throw error
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        throw error
    }
}
