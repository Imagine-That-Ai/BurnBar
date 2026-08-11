import FirebaseFirestore
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

@MainActor
final class RoamingProfileSyncServiceTests: XCTestCase {
    private var dataStore: DataStore!
    private var accountManager: FakeAccountManager!
    private var settingsManager: SettingsManager!
    private var fakeGateway: CloudSyncFirestoreFakeGateway!
    private var context: CloudSyncContext!
    private var vaultKeyStore: StaticSessionLogVaultKeyStore!

    override func setUp() async throws {
        try await super.setUp()
        dataStore = try makeDiscoveryInMemoryStore()
        accountManager = FakeAccountManager.makeSignedIn(uid: "roaming-uid-1")
        settingsManager = SettingsManager(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!)
        fakeGateway = CloudSyncFirestoreFakeGateway()
        vaultKeyStore = StaticSessionLogVaultKeyStore(keyData: Data(repeating: 0x52, count: 32))
        context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager,
            firestoreGateway: fakeGateway
        )
    }

    override func tearDown() async throws {
        dataStore = nil
        accountManager = nil
        settingsManager = nil
        fakeGateway = nil
        context = nil
        vaultKeyStore = nil
        try await super.tearDown()
    }

    func testSyncUploadsSealedRoamingProfileOnly() async throws {
        let local = FakeRoamingProfileLocalStore(payload: Self.payload(updatedAt: 200, sourceDeviceID: "mac-local"))
        let service = RoamingProfileSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: NoopSessionLogVaultKeyPublisher(),
            localStore: local
        )

        await service.sync()

        XCTAssertNil(service.lastSyncError)
        XCTAssertNotNil(service.lastSyncDate)
        let doc = try XCTUnwrap(fakeGateway.documentData(at: "users/roaming-uid-1/roaming_profile/current"))
        XCTAssertEqual(doc["uid"] as? String, "roaming-uid-1")
        XCTAssertEqual(doc["sourceDeviceID"] as? String, "mac-local")
        XCTAssertNotNil(doc["sealedPayload"])
        XCTAssertNil(doc["providerAccounts"])
        XCTAssertNil(doc["routerMode"])
        XCTAssertNil(doc["accountOrder"])

        let envelope = try Self.sealedPayload(from: try XCTUnwrap(doc["sealedPayload"] as? [String: Any]))
        XCTAssertEqual(envelope.aad, try CloudVaultCrypto.roamingProfileAADContext(uid: "roaming-uid-1").stringValue)
        let opened = try CloudVaultCrypto.openRoamingProfile(envelope, keyData: vaultKeyStore.keyData, uid: "roaming-uid-1")
        XCTAssertEqual(opened.sourceDeviceID, "mac-local")
        XCTAssertEqual(opened.accountOrder, ["anthropic-primary"])
    }

    func testSyncDownloadsRemoteNewerProfileAndDoesNotUploadOverIt() async throws {
        let localPayload = Self.payload(updatedAt: 100, sourceDeviceID: "mac-local")
        let remotePayload = Self.payload(updatedAt: 300, sourceDeviceID: "mac-remote", label: "Remote Claude")
        fakeGateway.setDocumentData(
            try Self.cloudDocument(payload: remotePayload, key: vaultKeyStore.keyData, uid: "roaming-uid-1"),
            at: "users/roaming-uid-1/roaming_profile/current"
        )
        let local = FakeRoamingProfileLocalStore(payload: localPayload)
        let service = RoamingProfileSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: NoopSessionLogVaultKeyPublisher(),
            localStore: local
        )

        await service.sync()

        XCTAssertNil(service.lastSyncError)
        let appliedPayloads = await local.appliedPayloads()
        XCTAssertEqual(appliedPayloads, [remotePayload])
        let stored = try XCTUnwrap(fakeGateway.documentData(at: "users/roaming-uid-1/roaming_profile/current"))
        XCTAssertEqual(stored["sourceDeviceID"] as? String, "mac-remote")
    }

    func testSyncFailsClosedOnWrongUidAADAndLeavesLocalStateUntouched() async throws {
        let remotePayload = Self.payload(updatedAt: 300, sourceDeviceID: "mac-remote", label: "Remote Claude")
        fakeGateway.setDocumentData(
            try Self.cloudDocument(payload: remotePayload, key: vaultKeyStore.keyData, uid: "other-uid"),
            at: "users/roaming-uid-1/roaming_profile/current"
        )
        let local = FakeRoamingProfileLocalStore(payload: Self.payload(updatedAt: 100, sourceDeviceID: "mac-local"))
        let service = RoamingProfileSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: NoopSessionLogVaultKeyPublisher(),
            localStore: local
        )

        await service.sync()

        XCTAssertNotNil(service.lastSyncError)
        let appliedPayloads = await local.appliedPayloads()
        XCTAssertEqual(appliedPayloads, [])
        let stored = try XCTUnwrap(fakeGateway.documentData(at: "users/roaming-uid-1/roaming_profile/current"))
        XCTAssertEqual(stored["sourceDeviceID"] as? String, "mac-remote")
    }

    func testPermissionDeniedSuppressesFurtherSync() async throws {
        fakeGateway.nextError = NSError(
            domain: FirestoreErrorDomain,
            code: FirestoreErrorCode.Code.permissionDenied.rawValue
        )
        let local = FakeRoamingProfileLocalStore(payload: Self.payload(updatedAt: 200, sourceDeviceID: "mac-local"))
        let service = RoamingProfileSyncService(
            context: context,
            vaultKeyStore: vaultKeyStore,
            vaultKeyPublisher: NoopSessionLogVaultKeyPublisher(),
            localStore: local
        )

        await service.sync()

        XCTAssertNotNil(service.lastSyncError)
        let isSuppressed = context.syncIsSuppressed()
        XCTAssertTrue(isSuppressed)
    }

    func testRoamingProfilePreservesOllamaEndpointSlots() throws {
        let endpoints = [
            BurnBarOllamaEndpointConfig(id: "edge-b", baseURL: "http://127.0.0.1:21435", label: "Edge B", priority: 10),
            BurnBarOllamaEndpointConfig(id: "edge-a", baseURL: "http://127.0.0.1:21434", label: "Edge A", priority: 0)
        ]
        let configurations = [
            OpenBurnBarDaemonProviderConfiguration(
                providerID: "ollama-local",
                provider: nil,
                displayName: "Ollama",
                isEnabled: true,
                baseURL: "http://127.0.0.1:21434",
                preferredModelIDs: [],
                preferredCredentialSlotID: nil,
                credentialSlots: [],
                ollamaEndpoints: endpoints
            )
        ]

        let roamingEndpoints = DefaultRoamingProfileLocalStore.roamingOllamaEndpoints(from: configurations)
        XCTAssertEqual(roamingEndpoints.map(\.id), ["edge-a", "edge-b"])
        XCTAssertEqual(roamingEndpoints.map(\.baseURL), ["http://127.0.0.1:21434", "http://127.0.0.1:21435"])
        XCTAssertEqual(roamingEndpoints.map(\.label), ["Edge A", "Edge B"])

        let restored = try DefaultRoamingProfileLocalStore.providerOllamaEndpoints(from: roamingEndpoints)
        XCTAssertEqual(restored.map(\.id), ["edge-a", "edge-b"])
        XCTAssertEqual(restored.map(\.baseURL), ["http://127.0.0.1:21434", "http://127.0.0.1:21435"])
        XCTAssertTrue(restored.allSatisfy { $0.enabled })
    }

    private static func payload(
        updatedAt seconds: TimeInterval,
        sourceDeviceID: String,
        label: String = "Claude Code"
    ) -> RoamingProfilePayload {
        let updatedAt = Date(timeIntervalSince1970: seconds)
        return RoamingProfilePayload(
            routerMode: .providerFamilyFailover,
            crossProviderFailoverEnabled: true,
            accountOrder: ["anthropic-primary"],
            providerAccounts: [
                RoamingProfileProviderAccount(
                    id: "anthropic-primary",
                    providerID: ProviderID(rawValue: "anthropic"),
                    label: label,
                    status: .connected,
                    credentialKind: .bearer,
                    storageScope: .deviceKeychain,
                    redactedLabel: "Stored in Mac Keychain",
                    sourceDeviceID: sourceDeviceID,
                    isDefault: true,
                    sortKey: 0,
                    createdAt: updatedAt.addingTimeInterval(-60),
                    updatedAt: updatedAt
                )
            ],
            quotaDisplayPreferences: RoamingQuotaDisplayPreferences(
                providerOrder: ["anthropic", "openai"],
                visibleProviders: ["anthropic"],
                hiddenBuckets: ["anthropic:daily"],
                bucketOrders: ["anthropic": ["5h"]],
                percentageDisplayMode: "remainingPercent",
                cumulativeAcrossAccounts: false
            ),
            updatedAt: updatedAt,
            sourceDeviceID: sourceDeviceID
        )
    }

    private static func cloudDocument(
        payload: RoamingProfilePayload,
        key: Data,
        uid: String
    ) throws -> [String: Any] {
        let sealed = try CloudVaultCrypto.sealRoamingProfile(payload, keyData: key, uid: uid)
        return [
            "uid": uid,
            "schemaVersion": 1,
            "payloadSchemaVersion": payload.schemaVersion,
            "sourceDeviceID": payload.sourceDeviceID,
            "updatedAt": payload.updatedAt,
            "sealedPayload": CloudVaultCrypto.sealedPayloadDictionary(sealed)
        ]
    }

    private static func sealedPayload(from dictionary: [String: Any]) throws -> CloudVaultSealedPayload {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(CloudVaultSealedPayload.self, from: data)
    }
}

private actor FakeRoamingProfileLocalStore: RoamingProfileLocalStoring {
    private let payload: RoamingProfilePayload
    private var applied: [RoamingProfilePayload] = []

    init(payload: RoamingProfilePayload) {
        self.payload = payload
    }

    func currentPayload(uid: String, deviceID: String, context: CloudSyncContext) async throws -> RoamingProfilePayload {
        payload
    }

    func apply(_ payload: RoamingProfilePayload, context: CloudSyncContext) async throws {
        applied.append(payload)
    }

    func appliedPayloads() -> [RoamingProfilePayload] {
        applied
    }
}
