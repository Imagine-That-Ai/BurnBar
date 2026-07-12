#if canImport(Security)
import Foundation
import OpenBurnBarComputerUseCore
import Security
@testable import OpenBurnBarDaemon
import XCTest

final class DaemonPhoneKeyKeychainPinBackingTests: XCTestCase {
    private let aliasStoreAccount = "phone-control-alias-store-v1"

    func testUnreadableAliasStoreFailsClosedWithoutConsultingLegacyRecord() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.seed(service: service, account: aliasStoreAccount, data: Data("not-json".utf8))
        dataStore.seed(service: service, account: "phone", data: try encodedRecord(deviceID: "phone"))
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.load(deviceId: "phone"), .unreadable(errSecDecode))
        XCTAssertEqual(dataStore.loadedAccounts(), [aliasStoreAccount])
    }

    func testUnsupportedAliasStoreVersionFailsClosed() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "records": ["phone": recordObject(deviceID: "phone")]
        ])
        dataStore.seed(service: service, account: aliasStoreAccount, data: data)
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.load(deviceId: "phone"), .unreadable(errSecDecode))
    }

    func testAliasStoreReadFailurePropagatesFromLoad() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.forceLoad(status: errSecInteractionNotAllowed, service: service, account: aliasStoreAccount)
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.load(deviceId: "phone"), .unreadable(errSecInteractionNotAllowed))
        XCTAssertEqual(dataStore.loadedAccounts(), [aliasStoreAccount])
    }

    func testAbsentAliasStoreLoadsValidLegacyRecord() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let record = record(deviceID: "legacy")
        dataStore.seed(service: service, account: "legacy", data: try encodedRecord(record))
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.load(deviceId: "legacy"), .found(record))
        XCTAssertEqual(dataStore.loadedAccounts(), [aliasStoreAccount, "legacy"])
    }

    func testMalformedAndFailedLegacyLoadsRemainDistinguishable() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.seed(service: service, account: "malformed", data: Data("bad".utf8))
        dataStore.forceLoad(status: errSecAuthFailed, service: service, account: "failed")
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.load(deviceId: "malformed"), .unreadable(errSecDecode))
        XCTAssertEqual(backing.load(deviceId: "failed"), .unreadable(errSecAuthFailed))
    }

    func testAtomicSaveRejectsEmptyAndRepeatedAliasesWithoutWriting() {
        let dataStore = FakeKeychainDataStore()
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: testService(), dataStore: dataStore)
        let duplicate = record(deviceID: "same")

        XCTAssertEqual(backing.saveAliasesAtomically([]), errSecParam)
        XCTAssertEqual(backing.saveAliasesAtomically([duplicate, duplicate]), errSecParam)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 0, updates: 0, deletes: 0))
    }

    func testAtomicSaveRejectsLegacyConflictBeforeCreatingAliasStore() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.seed(service: service, account: "legacy", data: try encodedRecord(deviceID: "legacy"))
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.save(record(deviceID: "legacy")), errSecDuplicateItem)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 0, updates: 0, deletes: 0))
    }

    func testAtomicSavePropagatesLegacyReadFailureBeforeMutation() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.forceLoad(status: errSecInteractionNotAllowed, service: service, account: "locked")
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.save(record(deviceID: "locked")), errSecInteractionNotAllowed)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 0, updates: 0, deletes: 0))
    }

    func testAtomicSavePropagatesAliasStoreReadFailureBeforeMutation() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        dataStore.forceLoad(status: errSecInteractionNotAllowed, service: service, account: aliasStoreAccount)
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)

        XCTAssertEqual(backing.save(record(deviceID: "new")), errSecInteractionNotAllowed)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 0, updates: 0, deletes: 0))
    }

    func testSecondAtomicSaveUpdatesOneVersionedItemAndPreservesPriorAliases() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)
        let first = record(deviceID: "first")
        let second = record(deviceID: "second")

        XCTAssertEqual(backing.save(first), errSecSuccess)
        XCTAssertEqual(backing.save(second), errSecSuccess)
        XCTAssertEqual(backing.load(deviceId: "first"), .found(first))
        XCTAssertEqual(backing.load(deviceId: "second"), .found(second))
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 1, updates: 1, deletes: 0))
        XCTAssertEqual(dataStore.itemCount(), 1)
    }

    func testAtomicSaveRejectsAliasAlreadyPresentInVersionedStore() {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)
        let existing = record(deviceID: "existing")

        XCTAssertEqual(backing.save(existing), errSecSuccess)
        XCTAssertEqual(backing.save(existing), errSecDuplicateItem)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 1, updates: 0, deletes: 0))
    }

    func testDeleteRemovesAliasFromVersionedStoreAndLegacyItem() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)
        let removed = record(deviceID: "removed")
        let retained = record(deviceID: "retained")
        XCTAssertEqual(backing.saveAliasesAtomically([removed, retained]), errSecSuccess)
        dataStore.seed(service: service, account: "removed", data: try encodedRecord(removed))

        backing.delete(deviceId: "removed")

        XCTAssertEqual(backing.load(deviceId: "removed"), .absent)
        XCTAssertEqual(backing.load(deviceId: "retained"), .found(retained))
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 1, updates: 1, deletes: 1))
        XCTAssertFalse(dataStore.contains(service: service, account: "removed"))
    }

    func testDeleteWithoutAliasStillAttemptsLegacyCleanup() throws {
        let dataStore = FakeKeychainDataStore()
        let service = testService()
        let backing = DaemonPhoneKeyKeychainPinBacking(serviceName: service, dataStore: dataStore)
        dataStore.seed(service: service, account: "legacy", data: try encodedRecord(deviceID: "legacy"))

        backing.delete(deviceId: "legacy")

        XCTAssertEqual(backing.load(deviceId: "legacy"), .absent)
        XCTAssertEqual(dataStore.mutationCounts(), .init(adds: 0, updates: 0, deletes: 1))
    }

    func testDefaultBackingRemainsKeychainBackedOnApplePlatforms() {
        XCTAssertTrue(DaemonPhoneKeyPinStore.defaultBacking() is DaemonPhoneKeyKeychainPinBacking)
    }

    private func testService() -> String {
        "com.openburnbar.tests.phone-key-backing.\(UUID().uuidString)"
    }

    private func record(deviceID: String) -> DaemonPhoneKeyPinRecord {
        DaemonPhoneKeyPinRecord(
            deviceId: deviceID,
            publicKeyBase64: Data(deviceID.utf8).base64EncodedString(),
            keyKind: .ed25519,
            pinnedAtEpoch: 1_700_000_000
        )
    }

    private func encodedRecord(deviceID: String) throws -> Data {
        try encodedRecord(record(deviceID: deviceID))
    }

    private func encodedRecord(_ record: DaemonPhoneKeyPinRecord) throws -> Data {
        try JSONEncoder().encode(record)
    }

    private func recordObject(deviceID: String) -> [String: Any] {
        [
            "deviceId": deviceID,
            "publicKeyBase64": Data(deviceID.utf8).base64EncodedString(),
            "keyKind": "ed25519",
            "pinnedAtEpoch": 1_700_000_000
        ]
    }
}

private final class FakeKeychainDataStore: DaemonPhoneKeyKeychainDataStore, @unchecked Sendable {
    struct MutationCounts: Equatable {
        let adds: Int
        let updates: Int
        let deletes: Int
    }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var forcedLoads: [String: Int32] = [:]
    private var loadAccounts: [String] = []
    private var adds = 0
    private var updates = 0
    private var deletes = 0

    func load(service: String, account: String) -> (status: Int32, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        loadAccounts.append(account)
        let itemKey = key(service: service, account: account)
        if let status = forcedLoads[itemKey] { return (status, nil) }
        guard let data = items[itemKey] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func add(service: String, account: String, data: Data) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        adds += 1
        let itemKey = key(service: service, account: account)
        guard items[itemKey] == nil else { return errSecDuplicateItem }
        items[itemKey] = data
        return errSecSuccess
    }

    func update(service: String, account: String, data: Data) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        updates += 1
        let itemKey = key(service: service, account: account)
        guard items[itemKey] != nil else { return errSecItemNotFound }
        items[itemKey] = data
        return errSecSuccess
    }

    func delete(service: String, account: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        deletes += 1
        let removed = items.removeValue(forKey: key(service: service, account: account))
        return removed == nil ? errSecItemNotFound : errSecSuccess
    }

    func seed(service: String, account: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        items[key(service: service, account: account)] = data
    }

    func forceLoad(status: Int32, service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        forcedLoads[key(service: service, account: account)] = status
    }

    func loadedAccounts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return loadAccounts
    }

    func mutationCounts() -> MutationCounts {
        lock.lock()
        defer { lock.unlock() }
        return MutationCounts(adds: adds, updates: updates, deletes: deletes)
    }

    func itemCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    func contains(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return items[key(service: service, account: account)] != nil
    }

    private func key(service: String, account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}
#endif
