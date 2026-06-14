import XCTest
@testable import OpenBurnBarMobile

/// T-CRY-01 — anti-downgrade version FLOOR for the Hermes gateway envelope.
/// Drives the pure floor decision over an in-memory backing so every branch is
/// verifiable on a CI runner with no Keychain entitlement (the shipping app
/// always uses `HermesGatewayVersionFloorKeychainBacking`).
final class HermesGatewayVersionFloorStoreTests: XCTestCase {

    /// In-memory `HermesGatewayPinBacking` mirroring `InMemoryControllerKeyPinBacking`:
    /// thread-safe, with injectable forced read/write failures so the fail-closed
    /// Keychain-error branches are testable.
    private final class InMemoryFloorBacking: HermesGatewayPinBacking, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: String] = [:]
        private var forcedReadError: OSStatus?
        private var forcedWriteError: OSStatus?

        func failReads(with status: OSStatus) { lock.lock(); forcedReadError = status; lock.unlock() }
        func failWrites(with status: OSStatus) { lock.lock(); forcedWriteError = status; lock.unlock() }

        func load(account: String) -> HermesGatewayPinLoad {
            lock.lock(); defer { lock.unlock() }
            if let forcedReadError { return .unreadable(forcedReadError) }
            if let value = store[account] { return .found(value) }
            return .absent
        }

        @discardableResult
        func save(_ value: String, account: String) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            if let forcedWriteError { return forcedWriteError }
            store[account] = value
            return errSecSuccess
        }

        func delete(account: String) {
            lock.lock(); defer { lock.unlock() }
            store[account] = nil
        }
    }

    private let uid = "uid-1"
    private let clientId = "client-1"

    func testFirstUsePinsFloorAndAdmits() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        let result = store.verifyAndPin(candidateVersion: 2, uid: uid, clientId: clientId)
        XCTAssertEqual(result, .pinnedFirstUse(floor: 2))
        XCTAssertTrue(result.allows)
        XCTAssertEqual(store.pinnedFloor(uid: uid, clientId: clientId), 2)
    }

    func testCandidateAtFloorAdmitsWithoutRatchet() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.verifyAndPin(candidateVersion: 3, uid: uid, clientId: clientId)
        let again = store.verifyAndPin(candidateVersion: 3, uid: uid, clientId: clientId)
        XCTAssertEqual(again, .atOrAboveFloor(floor: 3))
        XCTAssertTrue(again.allows)
    }

    func testHigherCandidateRatchetsFloorUp() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.verifyAndPin(candidateVersion: 2, uid: uid, clientId: clientId)
        let raised = store.verifyAndPin(candidateVersion: 3, uid: uid, clientId: clientId)
        XCTAssertEqual(raised, .atOrAboveFloor(floor: 3))
        XCTAssertEqual(store.pinnedFloor(uid: uid, clientId: clientId), 3)
    }

    func testV2AfterV3IsRefusedAsDowngrade() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.raiseFloorIfObserved(3, uid: uid, clientId: clientId)
        let downgrade = store.verifyAndPin(candidateVersion: 2, uid: uid, clientId: clientId)
        XCTAssertEqual(downgrade, .belowFloor(floor: 3, candidate: 2))
        XCTAssertFalse(downgrade.allows, "A v2 seal after v3 was observed must be refused fail-closed.")
        // The floor is unchanged by a refused downgrade.
        XCTAssertEqual(store.pinnedFloor(uid: uid, clientId: clientId), 3)
    }

    func testRaiseFloorOnlyRatchetsUp() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.raiseFloorIfObserved(3, uid: uid, clientId: clientId)
        // A later, lower observation must NOT lower the floor.
        let after = store.raiseFloorIfObserved(2, uid: uid, clientId: clientId)
        XCTAssertEqual(after, 3)
        XCTAssertEqual(store.pinnedFloor(uid: uid, clientId: clientId), 3)
    }

    func testKeychainReadErrorFailsClosed() {
        let backing = InMemoryFloorBacking()
        backing.failReads(with: errSecMissingEntitlement)
        let store = HermesGatewayVersionFloorStore(backing: backing)
        let result = store.verifyAndPin(candidateVersion: 3, uid: uid, clientId: clientId)
        XCTAssertFalse(result.allows, "An unreadable floor must fail closed (refuse) rather than admit.")
        if case .unknownKeychainError = result {} else {
            XCTFail("Expected unknownKeychainError, got \(result)")
        }
    }

    func testKeychainWriteErrorOnFirstUseFailsClosed() {
        let backing = InMemoryFloorBacking()
        backing.failWrites(with: errSecIO)
        let store = HermesGatewayVersionFloorStore(backing: backing)
        let result = store.verifyAndPin(candidateVersion: 3, uid: uid, clientId: clientId)
        XCTAssertFalse(result.allows, "A floor that could not be persisted must fail closed.")
    }

    func testClearFloorResetsForRepair() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.raiseFloorIfObserved(3, uid: uid, clientId: clientId)
        store.clearFloor(uid: uid, clientId: clientId)
        XCTAssertNil(store.pinnedFloor(uid: uid, clientId: clientId))
        // After a deliberate re-pair, a fresh v2 first-use is trusted again.
        let result = store.verifyAndPin(candidateVersion: 2, uid: uid, clientId: clientId)
        XCTAssertEqual(result, .pinnedFirstUse(floor: 2))
    }

    func testFloorScopedPerClient() {
        let store = HermesGatewayVersionFloorStore(backing: InMemoryFloorBacking())
        _ = store.raiseFloorIfObserved(3, uid: uid, clientId: "client-a")
        // A different client starts with no floor.
        XCTAssertNil(store.pinnedFloor(uid: uid, clientId: "client-b"))
        let other = store.verifyAndPin(candidateVersion: 2, uid: uid, clientId: "client-b")
        XCTAssertTrue(other.allows)
    }
}
